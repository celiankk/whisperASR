import Foundation

// MARK: - ASR 请求队列（ASRRequestQueue）
//
// 在线识别请求管理：请求排队、取消旧请求、防止重复发送。
//
// 规则：
// - 新的音频优先：新请求提交时，取消尚未完成的旧请求；
// - 防止重复发送：同一时刻最多一个在途请求（旧请求被取消后
//   新请求才执行，结果由新请求的调用方接收）。
//
// 上层（AppState 实时循环）串行调用，本队列是对并发场景的保险——
// 例如超时取消后旧请求仍挂在网络上时，新请求到来先取消它。
//
// actor 隔离：Task 句柄状态天然线程安全，且避免在 async 上下文持有锁。

actor ASRRequestQueue {
    private var current: Task<TranscriptionResult, Error>?

    /// 提交转录请求。若已有在途请求，先取消它（新的音频优先）。
    func submit(
        _ operation: @escaping @Sendable () async throws -> TranscriptionResult
    ) async throws -> TranscriptionResult {
        current?.cancel()
        let task = Task { try await operation() }
        current = task
        return try await task.value
    }

    /// 取消在途请求并等待其结束（停止录制 / 切换引擎时调用）。
    func cancelPending() async {
        let task = current
        current = nil
        task?.cancel()
        _ = await task?.result
    }

    var hasPending: Bool { current != nil }
}
