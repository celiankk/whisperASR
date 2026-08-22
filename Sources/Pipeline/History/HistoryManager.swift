import Foundation
import Observation

// MARK: - 转录历史统一管理（HistoryManager）
//
// 历史列表的唯一数据出入口：保存 / 删除 / 批量删除 / 查询 / 上限裁剪。
// View（SidebarView）与业务流程（AppState）都不直接操作数组与持久化，
// 全部经本管理器收口：
// - 删除安全语义与 TranscriptionStore 一致：应用录制的音频移废纸篓（可恢复），
//   导入的文件只移除转录记录、不动磁盘文件；
// - 进行中的转录不允许删除（完成回调会回写，删除会复活）；
// - 固定上限裁剪最旧记录，防长时间运行内存无界增长。

@Observable
final class TranscriptionHistoryManager {
    /// 历史记录上限：超出时从最旧开始裁剪（录音进废纸篓，可恢复）。
    /// 500 条已远超日常使用；元数据 + 段文本的常驻内存因此封顶。
    static let maxItems = 500

    private(set) var items: [TranscriptionItem] = []

    // MARK: 查询

    var first: TranscriptionItem? { items.first }

    func contains(fileURL: URL) -> Bool {
        items.contains { $0.fileURL == fileURL }
    }

    func item(fileURL: URL) -> TranscriptionItem? {
        items.first { $0.fileURL == fileURL }
    }

    func firstPending() -> TranscriptionItem? {
        items.first { $0.status == .pending }
    }

    // MARK: 载入 / 新增

    /// 启动时从磁盘恢复全部记录（按添加时间倒序）。
    func load() {
        items = TranscriptionStore.loadAll()
        enforceLimit()
    }

    /// 新增记录：置顶插入 + 持久化 + 上限裁剪。
    func add(_ item: TranscriptionItem) {
        items.insert(item, at: 0)
        TranscriptionStore.save(item)
        enforceLimit()
    }

    /// 更新持久化（重命名 / 状态变化后调用）。
    /// 未 hydrate 的条目只回写元数据（整体重存会用空 segments 覆盖磁盘）。
    func save(_ item: TranscriptionItem) {
        if item.transcriptHydrated {
            TranscriptionStore.save(item)
        } else {
            TranscriptionStore.saveMetadata(item)
        }
    }

    // MARK: 删除

    /// 删除单条记录（录音文件移废纸篓，可恢复）。
    func remove(_ item: TranscriptionItem) {
        items.removeAll { $0.id == item.id }
        TranscriptionStore.delete(item)
    }

    /// 批量删除：跳过进行中的转录（完成回调会回写，删除会复活）。
    /// 返回实际删除数量。
    @discardableResult
    func remove(ids: Set<UUID>) -> Int {
        guard !ids.isEmpty else { return 0 }
        let targets = items.filter { ids.contains($0.id) && $0.status != .transcribing }
        guard !targets.isEmpty else { return 0 }
        let targetIDs = Set(targets.map(\.id))
        items.removeAll { targetIDs.contains($0.id) }
        for item in targets {
            TranscriptionStore.delete(item)
        }
        AppLogger.shared.log(.ui, "History batch delete: \(targets.count) items")
        return targets.count
    }

    // MARK: 上限裁剪

    /// 超出上限时裁剪最旧的可删记录（进行中的转录不动）。
    private func enforceLimit() {
        let excess = items.count - Self.maxItems
        guard excess > 0 else { return }
        // items 按时间倒序：suffix 即最旧。
        let toRemove = items
            .filter { $0.status != .transcribing }
            .suffix(excess)
        guard !toRemove.isEmpty else { return }
        let removeIDs = Set(toRemove.map(\.id))
        items.removeAll { removeIDs.contains($0.id) }
        for item in toRemove {
            TranscriptionStore.delete(item)
        }
        AppLogger.shared.log(
            .ui,
            "History limit \(Self.maxItems) exceeded, trimmed \(toRemove.count) oldest items"
        )
    }
}
