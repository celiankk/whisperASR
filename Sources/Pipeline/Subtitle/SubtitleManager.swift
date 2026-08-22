import Foundation

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

final class SubtitleManager: @unchecked Sendable {
    /// 实时显示分段上限：超过丢弃最旧（环形窗口），防止数小时录制内存无限增长。
    static let maxLiveSegments = 100
    /// sealed 分段上限：只保留近期（用于 overlap/显示），旧段不再需要。
    static let maxSealedSegments = 200

    /// Final 字幕：封口后不再变化的段。
    private(set) var sealedSegments: [TranscriptionSegment] = []
    /// 未封口 tail 的累积文本（单一合并段 = 当前正在说的句子）。
    /// Apple 增量引擎每轮只返回新增的几个字，必须跨 pass 累积，否则当前句
    /// 的前半部分在下一轮重建显示时丢失（只剩最新碎片，无法读成一句话）；
    /// whisper 全量引擎每轮重转录整个 tail，整段替换即可。
    private(set) var pendingTailSegments: [TranscriptionSegment] = []
    /// 封口边界（16kHz 采样计数）。
    private(set) var sealedSampleCount = 0
    /// 封口是否落在静音停顿内（干净封口无需 overlap；强制封口需要 1s 左上下文）。
    private(set) var sealedClean = true

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
    }

    /// 清空字幕缓存（新会话 / 异常恢复 / 停止时）。
    func clear() {
        sealedSegments.removeAll()
        pendingTailSegments.removeAll()
        sealedSampleCount = 0
        sealedClean = true
    }

    // MARK: - 数据管理

    /// 追加一轮尾部转录结果（partial），与封口段合并为显示快照：
    /// - 保留封口边界前的 final 段；
    /// - `incremental`（Apple 流式）：本轮增量并入 pendingTail（合并为
    ///   单一「当前句」段，跨 pass 累积不丢前半句）；
    /// - 全量引擎（whisper）：本轮结果整段替换 pendingTail；
    /// - whisper 强制封口后的 overlap 场景用 trimOverlap 去重；
    /// - 空文本段丢弃。
    /// - Returns: 合并后的显示快照（调用方再按 maxLiveSegments 裁剪输出）。
    func appendTail(
        tailSegments: [TranscriptionSegment],
        tailStartTime: Double,
        useOverlap: Bool,
        incremental: Bool = false
    ) -> [TranscriptionSegment] {
        let kept = sealedSegments.filter { $0.start < tailStartTime }

        if incremental {
            let incoming = tailSegments
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !incoming.isEmpty else {
                return kept + pendingTailSegments
            }
            var incomingText = ""
            for piece in incoming {
                incomingText = Self.appendText(incomingText, piece)
            }
            if var head = pendingTailSegments.first {
                head = TranscriptionSegment(
                    start: head.start,
                    end: tailSegments.last?.end ?? head.end,
                    text: Self.appendText(head.text, incomingText))
                pendingTailSegments = [head]
            } else if let first = tailSegments.first {
                pendingTailSegments = [TranscriptionSegment(
                    start: first.start,
                    end: tailSegments.last?.end,
                    text: incomingText)]
            }
        } else {
            pendingTailSegments = tailSegments
        }

        var combined = kept
        for seg in pendingTailSegments {
            var text = seg.text
            if useOverlap, !incremental, let lastText = combined.last?.text {
                text = Self.trimOverlap(previous: lastText, current: text)
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                combined.append(TranscriptionSegment(start: seg.start, end: seg.end, text: text))
            }
        }
        return combined
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
        let sealTime = Double(upToSampleCount) / 16000.0
        sealedSegments = combined.filter { $0.start < sealTime }
        pendingTailSegments = combined.filter { $0.start >= sealTime }
        sealedSampleCount = upToSampleCount
        sealedClean = clean
        // 环形窗口：只保留近期段，防止数小时运行内存无限增长。
        if sealedSegments.count > Self.maxSealedSegments {
            sealedSegments.removeFirst(sealedSegments.count - Self.maxSealedSegments)
        }
    }

    /// 整段静音封口：边界推进到当前采样数（干净封口）。
    /// 未提交的 pendingTail 文本一并固化——静音路径不经过常规 seal，
    /// 不提交的话最后一句的前半部分会随边界推进丢失。
    func sealSilence(upToSampleCount: Int) {
        let sealTime = Double(upToSampleCount) / 16000.0
        let committing = pendingTailSegments.filter { $0.start < sealTime }
        if !committing.isEmpty {
            sealedSegments.append(contentsOf: committing)
            if sealedSegments.count > Self.maxSealedSegments {
                sealedSegments.removeFirst(sealedSegments.count - Self.maxSealedSegments)
            }
        }
        pendingTailSegments = pendingTailSegments.filter { $0.start >= sealTime }
        sealedSampleCount = upToSampleCount
        sealedClean = true
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
    static func trimOverlap(previous: String, current: String) -> String {
        var source = previous.trimmingCharacters(in: .whitespaces)
        while let last = source.unicodeScalars.last, overlapTrimChars.contains(last) {
            source.unicodeScalars.removeLast()
        }
        var target = Substring(current.trimmingCharacters(in: .whitespaces))
        while let first = target.unicodeScalars.first, overlapTrimChars.contains(first) {
            target = target.dropFirst()
        }
        let maxCheck = min(source.count, target.count)
        guard maxCheck >= 1 else { return current }
        for len in stride(from: maxCheck, through: 1, by: -1) {
            if target.hasPrefix(String(source.suffix(len))) {
                return String(target.dropFirst(len))
            }
        }
        return current
    }
}
