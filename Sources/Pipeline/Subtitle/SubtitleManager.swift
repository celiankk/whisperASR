import Foundation

// MARK: - 实时识别状态（StreamingState）
//
// 显式状态快照：调试日志 / UI 状态展示 / 状态监控用。
// 不用于并发控制——实时循环严格串行（ASRManager 每 pass await 转录返回），
// 状态推进只发生在 appendTail / rollbackTail / seal 系列 / clear 中。

enum StreamingState: Equatable {
    /// 会话未开始或已清空。
    case idle
    /// 已有 sealed 文本、当前无未封口 tail（说话人停顿中）。
    case recognizing
    /// 有未封口 tail（partial 增量累积 / 全量替换中）。
    case partial
    /// 封口进行中（seal 系列调用内）。
    case finalizing
    /// 会话结束（stop 后；缓存由上层清显示快照）。
    case completed
}

// MARK: - 字幕管理器（SubtitleManager）
//
// 实时字幕数据管理（AppState 拆分的一部分，UI 绑定不变）：
// - partial 字幕：尾部重转录结果（interim）与 final 段合并为显示快照；
// - final 字幕：封口（sealed）段缓存——静音封口后不再变化、不再重转录；
// - 字幕缓存：固定容量环形窗口（显示 100 条 / sealed 200 条），
//   长时间运行内存恒定；
// - 字幕生命周期：SubtitleEngine 启停（健康度监控 / 日志 / 异常信号）。
//
// 音频采集、静音检测、封口判定仍在 ASRManager（操作 AudioRecorder）；
// 本类只管理字幕数据与生命周期，不触碰显示层（FloatingLetter 等）。
//
// 并发模型：本类为 `@unchecked Sendable`，全部状态由 `lock` 保护。
// 原因是两类线程都会触碰它——实时识别循环（非隔离 Task，跑在协作线程池）
// 调用 appendTail / seal / sealSilence，而 start / stop / clear 由
// MainActor 上的录制流程调用（stopLive 只 cancel 不 await，旧循环可能
// 仍在临界区内）。此前无同步，属未同步的并发容器变更。
// 对外属性保持同名（存储属性 → 加锁只读计算属性），调用点零改动。

final class SubtitleManager: @unchecked Sendable {
    /// 实时显示分段上限：超过丢弃最旧（环形窗口），防止数小时录制内存无限增长。
    static let maxLiveSegments = 100
    /// sealed 分段上限：只保留近期（用于 overlap/显示），旧段不再需要。
    static let maxSealedSegments = 200

    /// 保护全部状态字段。所有公开方法整体持锁；内部实现只读写 `_` 前缀
    /// 的裸字段（NSLock 不可重入，公开计算属性不得在持锁路径中被调用）。
    private let lock = NSLock()

    private var _sealedSegments: [TranscriptionSegment] = []
    private var _pendingTailSegments: [TranscriptionSegment] = []
    private var _sealedSampleCount = 0
    private var _sealedClean = true
    private var _streamingState: StreamingState = .idle

    /// Final 字幕：封口后不再变化的段。
    var sealedSegments: [TranscriptionSegment] { lock.withLock { _sealedSegments } }
    /// 未封口 tail 的累积文本（单一合并段 = 当前正在说的句子）。
    /// Apple 增量引擎每轮只返回新增的几个字，必须跨 pass 累积，否则当前句
    /// 的前半部分在下一轮重建显示时丢失（只剩最新碎片，无法读成一句话）；
    /// whisper 全量引擎每轮重转录整个 tail，整段替换即可。
    var pendingTailSegments: [TranscriptionSegment] { lock.withLock { _pendingTailSegments } }
    /// 封口边界（16kHz 采样计数）。
    var sealedSampleCount: Int { lock.withLock { _sealedSampleCount } }
    /// 封口是否落在静音停顿内（干净封口无需 overlap；强制封口需要 1s 左上下文）。
    var sealedClean: Bool { lock.withLock { _sealedClean } }
    /// 实时识别状态（显式快照：日志/UI 展示用，不做并发控制）。
    var streamingState: StreamingState { lock.withLock { _streamingState } }

    /// 生命周期门面（SubtitleEngine.shared）：统一生命周期 / 刷新节流 /
    /// 性能监控 / 日志 / 异常恢复。
    let engine = SubtitleEngine.shared

    // MARK: - 生命周期

    /// 新会话开始：启动引擎、清空全部缓存。
    func start() {
        engine.start()
        clear()
    }

    /// 会话结束：停止引擎（缓存由上层清空显示快照）。
    func stop() {
        engine.stop()
        lock.withLock { _streamingState = .completed }
    }

    /// 清空字幕缓存（新会话 / 异常恢复 / 停止时）。
    func clear() {
        lock.withLock {
            _sealedSegments.removeAll()
            _pendingTailSegments.removeAll()
            _sealedSampleCount = 0
            _sealedClean = true
            _streamingState = .idle
        }
    }

    // MARK: - 数据管理

    /// 追加一轮尾部转录结果（partial），与封口段合并为显示快照：
    /// - 保留封口边界前的 final 段；
    /// - `mergePolicy == .appendIncrement`（增量引擎元数据）：本轮增量并入
    ///   pendingTail（合并为单一「当前句」段，跨 pass 累积不丢前半句）；
    /// - `.replaceTail`（整段替换引擎）：本轮结果整段替换 pendingTail；
    /// - 强制封口后的 overlap 场景用 trimOverlap 去重；
    /// - 空文本段丢弃。
    ///
    /// 统一识别结果层：本方法只按归一结果携带的 ASRMergePolicy 行为，
    /// 不出现 if whisper / if funasr / if apple 引擎分支。
    ///
    /// - Returns: 合并后的显示快照（调用方再按 maxLiveSegments 裁剪输出）。
    func appendTail(
        tailSegments: [TranscriptionSegment],
        tailStartTime: Double,
        useOverlap: Bool,
        mergePolicy: ASRMergePolicy
    ) -> [TranscriptionSegment] {
        lock.withLock {
            let kept = _sealedSegments.filter { $0.start < tailStartTime }

            if mergePolicy == .appendIncrement {
                let incoming = tailSegments
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !incoming.isEmpty else {
                    // 空增量：状态不变（此前无条件置 .partial，与实际不符）。
                    return kept + _pendingTailSegments
                }
                _streamingState = .partial
                var incomingText = ""
                for piece in incoming {
                    incomingText = Self.appendText(incomingText, piece)
                }
                if var head = _pendingTailSegments.first {
                    head = TranscriptionSegment(
                        start: head.start,
                        end: tailSegments.last?.end ?? head.end,
                        text: Self.appendText(head.text, incomingText))
                    _pendingTailSegments = [head]
                } else if let first = tailSegments.first {
                    _pendingTailSegments = [TranscriptionSegment(
                        start: first.start,
                        end: tailSegments.last?.end,
                        text: incomingText)]
                }
            } else {
                _streamingState = .partial
                _pendingTailSegments = tailSegments
            }

            var combined = kept
            for seg in _pendingTailSegments {
                var text = seg.text
                if useOverlap, mergePolicy == .replaceTail, let lastText = combined.last?.text {
                    text = Self.trimOverlap(previous: lastText, current: text)
                }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    combined.append(TranscriptionSegment(start: seg.start, end: seg.end, text: text))
                }
            }
            return combined
        }
    }

    /// 拼接两段文本：两侧均为西文（非 CJK）时补空格，中文直接相连。
    private static func appendText(_ a: String, _ b: String) -> String {
        guard !a.isEmpty, !b.isEmpty,
              let aLast = a.unicodeScalars.last,
              let bFirst = b.unicodeScalars.first,
              !SubtitleLanguage.isCJK(aLast), !SubtitleLanguage.isCJK(bFirst)
        else { return a + b }
        return a + " " + b
    }

    /// 推进封口：把 `combined` 中在 sealTime 之前的段固化为 final；
    /// sealTime 之后的段留作 pendingTail（下一句起点，不丢失）。
    /// 调用方（ASRManager）负责 recorder.trimSamples。
    func seal(upToSampleCount: Int, clean: Bool, combined: [TranscriptionSegment]) {
        lock.withLock {
            _streamingState = .finalizing
            let sealTime = Double(upToSampleCount) / 16000.0
            _sealedSegments = combined.filter { $0.start < sealTime }
            _pendingTailSegments = combined.filter { $0.start >= sealTime }
            _sealedSampleCount = upToSampleCount
            _sealedClean = clean
            _streamingState = _pendingTailSegments.isEmpty ? .recognizing : .partial
            // 环形窗口：只保留近期段，防止数小时运行内存无限增长。
            if _sealedSegments.count > Self.maxSealedSegments {
                _sealedSegments.removeFirst(_sealedSegments.count - Self.maxSealedSegments)
            }
        }
    }

    /// 整段静音封口：边界推进到当前采样数（干净封口）。
    /// 未提交的 pendingTail 文本一并固化——静音路径不经过常规 seal，
    /// 不提交的话最后一句的前半部分会随边界推进丢失。
    func sealSilence(upToSampleCount: Int) {
        lock.withLock {
            _streamingState = .finalizing
            let sealTime = Double(upToSampleCount) / 16000.0
            let committing = _pendingTailSegments.filter { $0.start < sealTime }
            if !committing.isEmpty {
                _sealedSegments.append(contentsOf: committing)
                if _sealedSegments.count > Self.maxSealedSegments {
                    _sealedSegments.removeFirst(_sealedSegments.count - Self.maxSealedSegments)
                }
            }
            _pendingTailSegments = _pendingTailSegments.filter { $0.start >= sealTime }
            _sealedSampleCount = upToSampleCount
            _sealedClean = true
            _streamingState = .recognizing
        }
    }

    /// 回滚当前未封口 tail 并以 final 结果替换。
    ///
    /// 缺口场景：增量引擎的 final 可能修正/缩短已显示的 partial
    ///（Apple："ta pop" → final "pop"）。appendIncrement 只加不减，
    /// 直接追加会产生「ta pop pop」脏文本；本方法删除错误 pendingTail、
    /// 用 final 段重建，sealedSegments 不受影响。
    ///
    /// - Parameter segment: final 归一段（start/end 为录制时间轴绝对秒）；
    ///   文本为空时仅清空 tail（引擎撤回全部已显示文本）。
    /// - Returns: 合并后的显示快照（sealed + 新 pendingTail）。
    @discardableResult
    func rollbackTail(to segment: NormalizedSegment) -> [TranscriptionSegment] {
        lock.withLock {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // 清掉与 final 时间区间重叠的旧 tail（final 修正只对它覆盖的
            // 区间负责，更晚的段不误删）。
            if let end = segment.endTime {
                _pendingTailSegments.removeAll { $0.start < end }
            } else {
                _pendingTailSegments.removeAll()
            }
            guard !text.isEmpty else {
                _streamingState = _pendingTailSegments.isEmpty ? .recognizing : .partial
                return _sealedSegments + _pendingTailSegments
            }
            _pendingTailSegments.append(
                TranscriptionSegment(start: segment.startTime, end: segment.endTime, text: text))
            _streamingState = .partial
            return _sealedSegments + _pendingTailSegments
        }
    }

    /// 输出快照（环形窗口裁剪：只保留最近 maxLiveSegments 条）。
    func snapshot(_ combined: [TranscriptionSegment]) -> [TranscriptionSegment] {
        Array(combined.suffix(Self.maxLiveSegments))
    }

    /// 收紧显示窗口（异常恢复兜底）。
    func trimDisplayCache(_ segments: [TranscriptionSegment]) -> [TranscriptionSegment] {
        segments.count > Self.maxLiveSegments
            ? Array(segments.suffix(Self.maxLiveSegments))
            : segments
    }

    // MARK: - 去重

    /// Punctuation/whitespace whisper sprinkles at chunk edges; ignored when matching an overlap.
    private static let overlapTrimChars = CharacterSet(
        charactersIn: "，。、！？；：「」『』（）()【】［］…—~,.!?;:'\" \t\n")

    /// Trim the leading portion of `current` that duplicates the trailing portion of `previous`.
    /// Produced when a forced chunk re-transcribes the 1s context overlap. The match floor is a
    /// single character (Mandarin is dense — the previous 4-char floor missed most overlaps) and
    /// boundary punctuation/whitespace is stripped so a comma/period whisper added at the cut can't
    /// block the match.
    ///
    /// P0 重写（Rabin-Karp 滚动哈希）：
    /// 旧实现 `target.hasPrefix(String(source.suffix(len)))` 自长至短逐档
    /// 构造 String 临时对象——O(n²) 次分配。现一次性物化 [Character]
    ///（字素语义与旧版一致），预计算 target 前缀哈希表 + source 后缀哈希表，
    /// 每个候选长度 O(1) 查表比对；哈希命中才做一次切片实比校验（防碰撞），
    /// 全程零 String 临时对象。
    static func trimOverlap(previous: String, current: String) -> String {
        var source = previous.trimmingCharacters(in: .whitespaces)
        while let last = source.unicodeScalars.last, overlapTrimChars.contains(last) {
            source.unicodeScalars.removeLast()
        }
        var target = Substring(current.trimmingCharacters(in: .whitespaces))
        while let first = target.unicodeScalars.first, overlapTrimChars.contains(first) {
            target = target.dropFirst()
        }
        let src = Array(source)   // [Character]，字素级（与旧 hasPrefix 语义一致）
        let tgt = Array(target)
        let maxCheck = min(src.count, tgt.count)
        guard maxCheck >= 1 else { return current }

        // 哈希：窗口 w 的多项式哈希 h(w) = Σ w[i]·B^(L-1-i)，
        // 用 UInt64 自然溢出算术（&*/&+）代替取模——哈希仅作快速
        // 预筛，命中后仍做实比校验，碰撞只损失少量比较，不影响正确性。
        // 前缀表：prefixHash[i] = hash(tgt[0..<i])；
        // 后缀表：suffixHash[i] = hash(src[i..<src.count])。
        let n = src.count
        // 幂表 31^k 一次算好（O(n)），后缀表反推时 O(1) 查幂。
        var pow31 = [UInt64](repeating: 1, count: n + 1)
        for i in 0..<n {
            pow31[i + 1] = pow31[i] &* 31
        }
        var prefixHash = [UInt64](repeating: 0, count: tgt.count + 1)
        for i in 0..<tgt.count {
            prefixHash[i + 1] = prefixHash[i] &* 31 &+ UInt64(tgt[i].unicodeScalars.first?.value ?? 0)
        }
        var suffixHash = [UInt64](repeating: 0, count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            suffixHash[i] = suffixHash[i + 1] &+ UInt64(src[i].unicodeScalars.first?.value ?? 0) &* pow31[n - 1 - i]
        }

        // 自长至短找最长重叠：src.suffix(len) vs tgt.prefix(len)。
        for len in stride(from: maxCheck, through: 1, by: -1) {
            let suffixH = suffixHash[n - len]
            let prefixH = prefixHash[len]
            guard suffixH == prefixH else { continue }
            // 哈希命中：切片实比校验（零分配）。
            if src[(n - len)...].elementsEqual(tgt[0..<len]) {
                return String(tgt[len...])
            }
        }
        return current
    }
}