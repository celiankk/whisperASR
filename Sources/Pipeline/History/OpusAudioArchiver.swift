import Foundation
import AVFoundation
import AudioToolbox

// MARK: - Opus 流式音频归档器（AudioConverter C-API）
//
// 16kHz 单声道 Float32 PCM → Opus 24kbps（语音档）流式转码，
// 压缩包按 [UInt16 大端长度][包字节] 帧结构追加写入归档文件，
// 回传物理字节偏移量供 SQLite 建立文本↔音频映射。
//
// 技术决策（均经原型实证）：
// - **AVAudioConverter Swift 缓冲 API 不可用**：AVAudioPCMBuffer 拒绝
//   非 PCM 格式（isPCMFormat 断言）→ 底层 AudioConverterFillComplexBuffer；
// - 输出 ASBD：kAudioFormatOpus, mFramesPerPacket=960（60ms@16k——
//   低码率下大帧减少包开销，实测 ~23kbps 有效码率）；
// - **输入永不干涸**：输入回调返回 0 包 = 向转换器声明「流结束」，
//   会毒化后续所有 Fill 调用（实证：后续 append 零产出）。因此预分配
//   输入 FIFO，仅在 ≥960 帧时驱动 Fill 并按比例上界 ioPackets，
//   回调在单次 Fill 内绝不干涸；尾部不足一帧滞留 FIFO，close() 补零冲刷；
// - 包帧结构：Opus 包本身无长度前缀，段内含多包必须帧定界——
//   2 字节长度前缀 @60ms ≈ 3% 开销，换取归档文件可独立解码还原。
//
// 线程模型：非实时路径（磁盘 IO + 编码），串行调用（归档队列）；
// 不支持并发 append。

/// 归档错误。
enum OpusArchiveError: Error, Equatable {
    case converterCreation(OSStatus)
    case fileCreation(String)
    case encodeFailed(OSStatus)
    case writeFailed(String)
    case alreadyClosed
}

/// 一次 append 的归档结果（写入 SQLite 的映射依据）。
struct OpusAppendResult: Equatable {
    /// 本段第一个包在归档文件中的物理字节偏移。
    let offset: Int64
    /// 本段写入的总字节数（含包长度前缀）。
    let length: Int
    /// 本段消费的 PCM 帧数（16kHz）。
    let pcmFrames: Int
}

final class OpusAudioArchiver {

    let fileURL: URL
    let sampleRate: Double
    let bitrate: Int
    /// 编码帧长（采样数；960 = 60ms @16kHz）。
    static let frameLength = 960

    // 编码器
    private var converter: AudioConverterRef?
    // 输出缓冲与包描述（Fill 的工作区，init 预分配）
    private let outputCapacity = 256 * 1024
    private let outputData: UnsafeMutableRawPointer
    private let descCapacity = UInt32(512)
    private let descriptions: UnsafeMutablePointer<AudioStreamPacketDescription>

    /// 输入 FIFO（预分配环形队列；回调供数，永不干涸）。
    private let fifo: InputFIFO

    // 归档文件
    private var fileHandle: FileHandle?
    private(set) var totalArchivedBytes: Int64 = 0
    private(set) var totalPCMFrames = 0
    private var isClosed = false

    var archivedDuration: Double { Double(totalPCMFrames) / sampleRate }

    init(fileURL: URL, sampleRate: Double = 16000, bitrate: Int = 24000) throws {
        self.fileURL = fileURL
        self.sampleRate = sampleRate
        self.bitrate = bitrate

        var srcASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var dstASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus,
            mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.frameLength),
            mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)

        var converterRef: AudioConverterRef?
        let status = AudioConverterNew(&srcASBD, &dstASBD, &converterRef)
        guard status == noErr, let converterRef else {
            throw OpusArchiveError.converterCreation(status)
        }
        converter = converterRef
        // 目标码率（kAudioConverterEncodeBitRate = 'brat'，透传 Opus 编码核）。
        var bitrateValue = UInt32(bitrate)
        AudioConverterSetProperty(converterRef, kAudioConverterEncodeBitRate,
                                  UInt32(MemoryLayout<UInt32>.size), &bitrateValue)

        outputData = UnsafeMutableRawPointer.allocate(byteCount: outputCapacity, alignment: 16)
        descriptions = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(
            capacity: Int(descCapacity))
        // FIFO 容量：64 个编码帧（~3.8s 输入余量），append 内部分批灌入。
        fifo = InputFIFO(frameCapacity: Self.frameLength * 64)

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: fileURL)
            fileHandle = handle
            totalArchivedBytes = Int64(handle.seekToEndOfFile())
        } catch {
            throw OpusArchiveError.fileCreation(fileURL.path)
        }
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
        fileHandle?.closeFile()
        outputData.deallocate()
        descriptions.deallocate()
    }

    // MARK: 流式增量归档

    /// 追加一段 PCM（16kHz mono Float32）。任意长度：内部按 FIFO 分批编码，
    /// 尾部不足 960 帧滞留 FIFO，跨 append 连续（close 时补零冲刷）。
    func append(pcm: UnsafePointer<Float>, frameCount: Int) throws -> OpusAppendResult {
        guard !isClosed else { throw OpusArchiveError.alreadyClosed }
        guard frameCount > 0 else {
            return OpusAppendResult(offset: totalArchivedBytes, length: 0, pcmFrames: 0)
        }
        let segmentStartOffset = totalArchivedBytes
        var segmentBytes = 0

        var fed = 0
        while fed < frameCount {
            // 灌 FIFO（推不下的留给下一轮 drain 后再推）。
            let fifoCountBefore = fifo.count
            let pushed = fifo.push(pcm.advanced(by: fed), frames: frameCount - fed)
            fed += pushed
            // 消费：仅在 ≥ 一个完整编码帧时驱动 Fill（回调永不干涸）。
            try drainFifo(into: &segmentBytes)
            // 停滞守卫：push 零进展且 drain 也未腾出空间 → 编码器卡死，
            // 抛错而非无限自旋（防御路径，正常流不会到达）。
            if pushed == 0 && fifo.count == fifoCountBefore {
                throw OpusArchiveError.encodeFailed(-1)
            }
        }
        totalArchivedBytes = segmentStartOffset + Int64(segmentBytes)
        totalPCMFrames += frameCount
        return OpusAppendResult(offset: segmentStartOffset,
                                length: segmentBytes,
                                pcmFrames: frameCount)
    }

    /// 冲刷尾部（不足一帧补零到 960）并关闭。调用后 archiver 不可再用。
    func close() throws {
        guard !isClosed else { return }
        isClosed = true
        // 补零对齐编码帧边界，冲出最后一段。
        let tail = fifo.count % Self.frameLength
        if tail > 0 {
            let zeros = [Float](repeating: 0, count: Self.frameLength - tail)
            _ = fifo.push(zeros, frames: zeros.count)
        }
        var segmentBytes = 0
        try drainFifo(into: &segmentBytes)
        totalArchivedBytes += Int64(segmentBytes)
        fileHandle?.closeFile()
        fileHandle = nil
    }

    // MARK: 内部

    /// 消费 FIFO：每轮 Fill 的 ioPackets ≤ fifoFrames/960（消费上界 = 供给，
    /// 回调在单次 Fill 内绝不干涸——这是转换器状态健康的关键）。
    private func drainFifo(into segmentBytes: inout Int) throws {
        while fifo.count >= Self.frameLength {
            var ioPackets = UInt32(min(Int(descCapacity), fifo.count / Self.frameLength))
            var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: (
                AudioBuffer(mNumberChannels: 1,
                            mDataByteSize: UInt32(outputCapacity),
                            mData: outputData)))
            let status = AudioConverterFillComplexBuffer(
                converter!, inputProcedure,
                Unmanaged.passUnretained(fifo).toOpaque(),
                &ioPackets, &abl, descriptions)
            guard status == noErr else {
                throw OpusArchiveError.encodeFailed(status)
            }
            guard ioPackets > 0 else { break }   // 防御：无产出则退出本轮

            let packets = Int(ioPackets)
            let buffer = outputData.assumingMemoryBound(to: UInt8.self)
            guard let fileHandle else { throw OpusArchiveError.writeFailed("归档文件已关闭") }
            for p in 0..<packets {
                let desc = descriptions[p]
                let packetBytes = Int(desc.mDataByteSize)
                let packetStart = Int(desc.mStartOffset)
                var lengthPrefix = [UInt8]()
                lengthPrefix.append(UInt8((packetBytes >> 8) & 0xFF))
                lengthPrefix.append(UInt8(packetBytes & 0xFF))
                // 用可抛错写入：此前 fileHandle?.write 静默失败仍累计 segmentBytes
                // → 调用方写入 SQLite 的 opus_offset/length 指向归档中不存在的
                // 字节区间（文本↔音频映射失效）。
                do {
                    try fileHandle.write(contentsOf: Data(lengthPrefix))
                    try fileHandle.write(contentsOf: Data(bytes: buffer + packetStart, count: packetBytes))
                } catch {
                    throw OpusArchiveError.writeFailed(error.localizedDescription)
                }
                segmentBytes += 2 + packetBytes
            }
        }
    }

    /// 输入 FIFO：预分配线性缓冲 + 压实（消费后 memmove 归位）。
    final class InputFIFO {
        let capacity: Int
        let storage: UnsafeMutablePointer<Float>
        private(set) var count = 0

        init(frameCapacity: Int) {
            capacity = frameCapacity
            storage = UnsafeMutablePointer<Float>.allocate(capacity: frameCapacity)
        }

        deinit { storage.deallocate() }

        /// 尽量推入，返回实际推入帧数（FIFO 满时 < frames）。
        func push(_ source: UnsafePointer<Float>, frames: Int) -> Int {
            let n = min(frames, capacity - count)
            if n > 0 {
                memcpy(storage + count, source, n * MemoryLayout<Float>.size)
                count += n
            }
            return n
        }

        /// 供数回调：从头取至多 maxFrames 帧。
        func consume(into destination: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
            let n = min(maxFrames, count)
            if n > 0 {
                memcpy(destination, storage, n * MemoryLayout<Float>.size)
                count -= n
                if count > 0 { memmove(storage, storage + n, count * MemoryLayout<Float>.size) }
            }
            return n
        }
    }

    // MARK: 编码回调（Swift 导入签名：userData 在最后一个参数）

    private let inputProcedure: AudioConverterComplexInputDataProc = {
        _, ioNumberDataPackets, ioData, _, inUserData in
        let fifo = Unmanaged<OpusAudioArchiver.InputFIFO>
            .fromOpaque(inUserData!).takeUnretainedValue()
        // 每次供给一个完整编码帧（960 帧 @16kHz）。
        let n = min(OpusAudioArchiver.frameLength, fifo.count)
        guard n > 0 else {
            // 不可达：drainFifo 保证 Fill 期间 FIFO 帧数 ≥ 产出需求。
            ioNumberDataPackets.pointee = 0
            return noErr
        }
        ioNumberDataPackets.pointee = UInt32(n)
        ioData.pointee.mBuffers.mDataByteSize = UInt32(n * MemoryLayout<Float>.size)
        _ = fifo.consume(into: ioData.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self),
                         maxFrames: n)
        return noErr
    }
}
