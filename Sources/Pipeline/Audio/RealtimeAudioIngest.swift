import Accelerate

// MARK: - 实时采集音频前端（RealtimeAudioIngest）
//
// SCStream/CoreAudio 采集 → ASR 环形缓冲之间的生产端信号链：
//
//   SCStream 回调线程（生产者）
//     → 声道下混（stereo/mono → mono，vDSP_vsma 单次跨步乘加）
//     → 抗混叠降采样（48kHz → 16kHz，自管理历史的 Kaiser FIR + vDSP_desamp）
//     → SPSCFloatRingBuffer.write（.overwriteOldest 背压，绝不阻塞）
//
// 设计决策（与需求的两个关键检查点对应）：
//
// 1. **重采样放在环形缓冲写入之前**：48k→16k 使写入吞吐缩为 1/3，
//    环形容量按 16kHz 计——同样的内存可缓存 3 倍时长的音频，背压丢弃
//    粒度也更粗（一次丢弃更少的独立样本）。若改在消费端降采样，
//    需把原始 48k 流写入环形缓冲（吞吐 ×3）并把本类挪到消费线程——
//    接口不变，仅组装位置不同。
//
// 2. **背压 = 生产者端丢弃，绝不等待**：环形缓冲满（GPU 满载 / ASR
//    排队）时 `.overwriteOldest` 直接覆盖最旧数据——缓冲窗口永远持有
//    「最近 N 秒」的音频，消费端恢复后从最新音频继续，系统时钟与外部
//    拾音严格对齐。生产者路径上没有任何条件变量/信号量/自旋等待。
//
// 实时安全（vDSP_desamp 是无状态 FIR：C[n] = Σ A[n·DF+p]·F[p]，本
// SDK 版本无 Delays 参数——**跨调用滤波器历史由本类手动管理**）：
// - 全路径只有 memcpy/memmove + vDSP C 函数，无分配、无锁、无 ObjC；
// - 所有暂存缓冲（历史窗/输出/单混）init 一次性预分配，容量按最大
//   回调帧数（8192 帧）上界，deinit 统一回收；
// - Kaiser 窗 FIR 在 init 设计（非 RT 路径，允许分配）。
//
// 线程安全假设：本类**生产者线程 confined**——resample/ingest 只允许
// 采集回调线程调用；非线程安全（无原子保护），不得跨线程共享调用。
// （跨线程共享只发生在 ingest 内部 ring.write 的发布点——那里由环形
// 缓冲的 acquire/release 协议负责。）

/// 48kHz（SCStream）→ 16kHz（Whisper/Qwen-ASR）的实时降采样器。
/// 跨块滤波器历史自管理：块边界处的输出与「整段一次重采样」逐样本一致
/// （相同绝对输入位置 → 相同 FIR 相位），无漂移。
final class RTAudioResampler {

    /// 输入采样率（SCStream 配置的 sampleRate）。
    static let inputSampleRate: Double = 48_000
    /// 输出采样率（ASR 引擎要求）。
    static let outputSampleRate: Double = 16_000
    /// 抽取因子（整数：48k/16k = 3；非整数比率需换多相结构，未支持）。
    let decimation: Int = 3

    /// FIR 长度：72 抽头 @48kHz = 1.5ms 支撑——48dB+ 阻带衰减下
    /// 过渡带足够窄，语音能量（<8kHz）无损。须为 decimation 整数倍。
    private static let filterLength = 72
    /// Kaiser 窗 β：8.6 ≈ 80dB 旁瓣抑制（抗混叠余量充足）。
    private static let kaiserBeta = 8.6
    /// 单次回调最大输入帧数默认上界（SCStream 实际 ~2048；取 4 倍余量）。
    static let defaultMaxInputFrames = 8192

    /// 实例的输入帧数上界（init 注入；预分配依据，precondition 契约）。
    let maxInputFrames: Int

    /// 归一化截止频率（cycles/sample）：新奈奎斯特 8kHz 的 0.94 倍
    ///（7.52kHz，留过渡带）。语音基频与共振峰几乎全部在通带内。
    private var filterTaps: [Float] = []

    /// 跨调用历史窗（尾部 P-1 样本 + 新输入拼接后的工作缓冲）。
    private let history: UnsafeMutablePointer<Float>
    private var pendingCount = 0
    /// 降采样输出暂存（resample 返回的指针指向这里，下一次调用失效）。
    private let outputScratch: UnsafeMutablePointer<Float>

    /// - Parameter maxInputFrames: 单次回调输入帧数上界（预分配依据）。
    init(maxInputFrames: Int = RTAudioResampler.defaultMaxInputFrames) {
        self.maxInputFrames = maxInputFrames
        let p = Self.filterLength
        filterTaps = Self.designAntiAliasFilter(
            decimation: decimation, length: p, beta: Self.kaiserBeta)
        // 历史窗容量：待处理尾部（< P-1+D）+ 单次输入上界。
        history = UnsafeMutablePointer<Float>.allocate(capacity: p + decimation + maxInputFrames)
        history.initialize(repeating: 0, count: p + decimation + maxInputFrames)
        outputScratch = UnsafeMutablePointer<Float>.allocate(
            capacity: maxInputFrames / decimation + 2)
    }

    deinit {
        history.deallocate()
        outputScratch.deallocate()
    }

    /// 降采样一批输入（48kHz mono）。
    /// - Returns: (输出指针, 输出帧数)。指针指向内部暂存缓冲，
    ///   **下一次 resample 调用前必须消费完毕**（生产者线程内即取即写环形缓冲）。
    func resample(input: UnsafePointer<Float>, frameCount: Int) -> (output: UnsafePointer<Float>, count: Int) {
        // 契约：frameCount ≤ init 声明的 maxInputFrames（预分配上界）。
        // 违反即调用方程序错误（HAL 回调 ~2048 帧，8192 上界有 4 倍余量）。
        precondition(frameCount <= maxInputFrames,
                     "frameCount \(frameCount) exceeds preallocated maxInputFrames \(maxInputFrames)")
        // 注意：UnsafeMutablePointer → UnsafePointer 在函数参数位可隐式
        // 转换，但元组内不行——显式 UnsafePointer(...) 包一层。
        let outputBase = UnsafePointer(outputScratch)
        guard frameCount > 0 else { return (output: outputBase, count: 0) }
        let p = Self.filterLength
        let d = decimation

        // 1. 拼接窗口 = [上次尾部 pendingCount 样本 | 新输入]。
        //    （memcpy + memmove：无分配、无对象消息。）
        memcpy(history + pendingCount, input, frameCount * MemoryLayout<Float>.size)
        let total = pendingCount + frameCount

        // 2. 输出数：输出 n 消费窗口 [n·D, n·D+P)；须完整滤波器支撑。
        //    绝对相位对齐：窗口起点 = 已产出的输出数×D，跨块无漂移。
        var outCount = (total &- (p &- 1)) / d
        if outCount < 0 { outCount = 0 }

        if outCount > 0 {
            // 3. 抗混叠 FIR + 抽取（vDSP_desamp：纯 C FIR，无分配）。
            filterTaps.withUnsafeBufferPointer { taps in
                vDSP_desamp(history,
                            vDSP_Stride(d),
                            taps.baseAddress!,
                            outputScratch,
                            vDSP_Length(outCount),
                            vDSP_Length(p))
            }
            // 4. 保留未消费尾部（total - mOut·D ∈ [P-1, P-1+D)）作下次历史。
            //    原地重叠搬移 → memmove。
            let kept = total &- outCount &* d
            memmove(history, history + outCount &* d, kept * MemoryLayout<Float>.size)
            pendingCount = kept
        } else {
            // 输入尚不足一次完整滤波支撑：全部留作历史（pending < P-1）。
            pendingCount = total
        }

        return (output: outputBase, count: outCount)
    }

    // MARK: - 滤波器设计（init 期，非 RT 路径）

    /// Kaiser 窗 sinc 低通：截止 = 新奈奎斯特 × 0.94，Σh = 1（直流增益 1）。
    static func designAntiAliasFilter(decimation: Int, length: Int, beta: Double) -> [Float] {
        // 截止：输出奈奎斯特（0.5/D）留 6% 过渡带 → fc = 0.94/(2D)。
        let cutoff = 0.94 / (2.0 * Double(decimation))
        let center = Double(length - 1) / 2.0
        var taps = [Float](repeating: 0, count: length)
        var sum: Double = 0
        let denominator = Self.besselI0(beta)
        for i in 0..<length {
            let x = Double(i) - center
            // 归一化 sinc：sin(2πfc·x)/(πx)（x=0 时取 2fc）。
            let sinc = x == 0
                ? 2.0 * cutoff
                : sin(.pi * 2.0 * cutoff * x) / (.pi * x)
            // Kaiser 窗：I0(β·√(1-(2i/(L-1)-1)²)) / I0(β)。
            let r = 2.0 * Double(i) / Double(length - 1) - 1.0
            let shaped = beta * (1.0 - r * r).squareRoot()
            let window = Self.besselI0(shaped) / denominator
            let tap = sinc * window
            taps[i] = Float(tap)
            sum += tap
        }
        // 归一化（直流增益 1：常数输入降采样后幅值不变）。
        if sum != 0 {
            for i in 0..<length { taps[i] /= Float(sum) }
        }
        return taps
    }

    /// 第一类修正贝塞尔 I0（幂级数；仅 init 期调用）。
    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        var k = 1
        // x²/4 递推，收敛到 double 精度（β=8.6 → x≤8.6，~15 项）。
        while term > sum * 1e-16, k < 64 {
            term *= (x / 2.0) * (x / 2.0) / Double(k * k)
            sum += term
            k += 1
        }
        return sum
    }
}

// MARK: - 采集前端组装（下混 → 降采样 → 环形缓冲）

/// SCStream 回调侧的完整入口：声道对齐 → 采样率对齐 → 有界缓冲。
/// ASR 侧（消费者线程）只读 `ring`。
final class RealtimeAudioIngest {

    /// 16kHz mono 样本环形缓冲（overwriteOldest：满时覆盖最旧，
    /// 消费端经 takeDiscontinuity/takeDroppedSamples 感知丢弃）。
    let ring: SPSCFloatRingBuffer
    private let resampler: RTAudioResampler
    /// 立体声下混暂存（帧数上界 = 单次回调帧数）。
    private let monoScratch: UnsafeMutablePointer<Float>
    private let monoScratchFrames: Int

    // MARK: 不支持声道数的丢弃记账
    //
    // 采集回调线程**禁止任何 I/O**（此前这里直接 `FileHandle.write` 到
    // stderr：write 是系统调用，可能因 stderr 被重定向到慢速管道/文件而
    // 阻塞——违背本类「生产者路径永不阻塞、永不分配」的承诺，也让实时
    // 字幕线程被日志拖住）。改为纯计数（一次整数自增，无分配无 I/O），
    // 由非实时路径查询上报。
    private var unsupportedChannelDrops = 0
    private var unsupportedChannelDroppedFrames = 0

    /// 取出「不支持声道数」的丢弃统计（查询即清零）。
    /// 生产者线程私有累加，仅由非实时路径（采集启停/状态刷新）调用上报。
    func takeUnsupportedChannelDrops() -> (blocks: Int, frames: Int) {
        let snapshot = (blocks: unsupportedChannelDrops, frames: unsupportedChannelDroppedFrames)
        unsupportedChannelDrops = 0
        unsupportedChannelDroppedFrames = 0
        return snapshot
    }

    /// - Parameter capacitySamples: 16kHz 环形容量（2 的幂次方）。
    ///   实时字幕建议 ≥ 2^18（262144 样本 ≈ 16.4s，覆盖 ASR 尾部重转录窗口）。
    init(capacitySamples: Int = 1 << 18, maxInputFrames: Int = RTAudioResampler.defaultMaxInputFrames) throws {
        ring = try SPSCFloatRingBuffer(capacity: capacitySamples, overflowPolicy: .overwriteOldest)
        resampler = RTAudioResampler(maxInputFrames: maxInputFrames)
        monoScratchFrames = maxInputFrames
        monoScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxInputFrames)
    }

    deinit {
        monoScratch.deallocate()
    }

    /// 采集回调入口（生产者线程 confined；永不阻塞、永不分配）。
    ///
    /// - Parameters:
    ///   - input: 交错的 Float32 PCM（SCStream 输出）。
    ///   - sampleCount: **总 Float 数**（= 帧数 × 声道数）。
    ///   - channelCount: 1（mono 直通）或 2（L+R 等权下混）。
    func ingest(input: UnsafePointer<Float>, sampleCount: Int, channelCount: Int) {
        guard sampleCount > 0, channelCount >= 1 else { return }
        let frames = sampleCount / channelCount
        guard frames > 0 else { return }
        // 声道数 >2 不支持（交错布局下 stride-2 下混会取到错乱声道）：
        // 明确丢弃整个回调块，绝不产出混串数据（SCStream 配置 channelCount=1
        // 或 2 时不会走到这里）。只记账不落盘——实时路径禁止 I/O，
        // 由 `takeUnsupportedChannelDrops()` 在非实时路径上报。
        guard channelCount <= 2 else {
            unsupportedChannelDrops += 1
            unsupportedChannelDroppedFrames += frames
            return
        }

        // 分批处理（每批 ≤ 预分配上界）：任意回调长度零丢弃。
        var consumedFrames = 0
        while consumedFrames < frames {
            let batch = Swift.min(frames - consumedFrames, monoScratchFrames)
            let base = input.advanced(by: consumedFrames * channelCount)
            switch channelCount {
            case 2:
                // 立体声交错下混：mono[i] = 0.5·L[i] + 0.5·R[i]。
                // vDSP_vsma 映射是 D = A·B + C（只有 A 乘标量，C 原样加），
                // 所以分两步：先 0.5·L 写入 mono，再累加 0.5·R。
                var half: Float = 0.5
                vDSP_vsmul(base, 2, &half, monoScratch, 1, vDSP_Length(batch))
                vDSP_vsma(base + 1, 2, &half,
                          monoScratch, 1,
                          monoScratch, 1,
                          vDSP_Length(batch))
                writeDownsampled(monoScratch, frames: batch)
            default:
                // Mono：零拷贝直通重采样。
                writeDownsampled(base, frames: batch)
            }
            consumedFrames += batch
        }
    }

    /// 消费线程专用透传：不连续标记（ASR 据此重置流式解码状态）。
    func takeDiscontinuity() -> Bool { ring.takeDiscontinuity() }
    /// 消费线程专用透传：累计被覆盖丢弃的 16kHz 样本数（查询即清零）。
    func takeDroppedSamples() -> Int { ring.takeDroppedSamples() }

    /// 降采样并写入环形缓冲（生产者路径终点；满 → 覆盖最旧，绝不等待）。
    private func writeDownsampled(_ mono: UnsafePointer<Float>, frames: Int) {
        let (output, outputCount) = resampler.resample(input: mono, frameCount: frames)
        if outputCount > 0 {
            ring.write(output, count: outputCount)
        }
    }
}
