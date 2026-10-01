import Foundation
import Observation
import os

// MARK: - 管线延迟聚合器（共享延迟存储）
//
// 转录管线各阶段的最新耗时，供状态页仪表盘与浮层 debug 双端读写。
//
// 管线：
//   音频采集 → ASR 推理 → 翻译 API → 字幕渲染
//
// 各阶段的计时点（由调用方在对应代码路径手动 mark）：
// - recordASR(ms:)      识别引擎推理耗时
// - recordTranslate(ms) 翻译 API 往返
// - recordDisplay(ms)   字幕提交（= ASR 输入到上屏的总延迟）
//
// 线程模型：所有写入通过 OSAllocatedUnfairLock 串行（调用方线程不定：
// FloatingLetterViewModel 的翻译回调可能从非主线程触发），仪表盘读同理。

@Observable
final class PipelineLatencyStore {

    static let shared = PipelineLatencyStore()

    private let lock = OSAllocatedUnfairLock<LatencyData>(initialState: LatencyData())

    struct LatencyData {
        var asrMs: Double = 0
        var translateMs: Double = 0
        var displayMs: Double = 0
        var asrAvgMs: Double = 0
        var translateAvgMs: Double = 0
        var displayAvgMs: Double = 0
        var lastUpdated = Date.distantPast
        var asrWindow: [Double] = []
        var translateWindow: [Double] = []
        var displayWindow: [Double] = []
    }

    private static let windowSize = 20

    private init() {}

    // MARK: 读取（仪表盘 tick 调用）

    var snapshot: LatencyData {
        lock.withLock { $0 }
    }

    // MARK: 写入

    func recordASR(ms: Double) {
        lock.withLock { data in
            data.asrMs = ms
            data.asrWindow.append(ms)
            if data.asrWindow.count > Self.windowSize { data.asrWindow.removeFirst() }
            data.asrAvgMs = data.asrWindow.reduce(0, +) / Double(data.asrWindow.count)
            data.lastUpdated = Date()
        }
    }

    func recordTranslate(ms: Double) {
        lock.withLock { data in
            data.translateMs = ms
            data.translateWindow.append(ms)
            if data.translateWindow.count > Self.windowSize { data.translateWindow.removeFirst() }
            data.translateAvgMs = data.translateWindow.reduce(0, +) / Double(data.translateWindow.count)
            data.lastUpdated = Date()
        }
    }

    func recordDisplay(ms: Double) {
        lock.withLock { data in
            data.displayMs = ms
            data.displayWindow.append(ms)
            if data.displayWindow.count > Self.windowSize { data.displayWindow.removeFirst() }
            data.displayAvgMs = data.displayWindow.reduce(0, +) / Double(data.displayWindow.count)
            data.lastUpdated = Date()
        }
    }

    /// 全量重置（新录制会话）。
    func reset() {
        lock.withLock { data in
            data = LatencyData()
        }
    }
}
