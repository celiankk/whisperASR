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

    /// 最近一次持久化失败（写盘/回写失败）。
    /// `TranscriptionStore` 现在会显式返回失败，这里收口成可观察状态：
    /// UI 可据此提示用户"记录只存在于内存、重启会丢失"，而不是显示"已完成"
    /// 却在重启后让记录凭空消失。查询成功后由调用方清除。
    private(set) var lastPersistenceFailure: TranscriptionStore.PersistenceFailure?

    /// 最近一次启动载入时损坏/不可读的记录（诊断用；这些记录以失败状态
    /// 保留在列表中，不再被静默剔除）。
    private(set) var loadIssues: [TranscriptionStore.LoadIssue] = []

    /// 清除失败状态（UI 提示展示完毕后调用）。
    func clearPersistenceFailure() {
        lastPersistenceFailure = nil
    }

    // MARK: 查询

    var first: TranscriptionItem? { items.first }

    func contains(fileURL: URL) -> Bool {
        items.contains { $0.fileURL == fileURL }
    }

    /// 按 id 判断条目是否仍在列表中（异步完成回调回写前的存在性检查）。
    func contains(id: UUID) -> Bool {
        items.contains { $0.id == id }
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
        loadIssues = TranscriptionStore.loadIssues
        if !loadIssues.isEmpty {
            AppLogger.shared.log(
                .ui,
                "History loaded with \(loadIssues.count) unreadable record(s) — kept as failed items")
        }
        enforceLimit()
    }

    /// 新增记录：置顶插入 + 持久化 + 上限裁剪。
    /// - Returns: 持久化失败信息（nil = 已成功落盘）。调用方（UI）应据此提示，
    ///   否则用户会看到"已完成"、重启后记录消失。
    @discardableResult
    func add(_ item: TranscriptionItem) -> TranscriptionStore.PersistenceFailure? {
        items.insert(item, at: 0)
        let failure = TranscriptionStore.save(item)
        enforceLimit()
        return record(failure, context: "add \(item.id.uuidString)")
    }

    /// 更新持久化（重命名 / 状态变化后调用）。
    /// 未 hydrate 的条目只回写元数据（整体重存会用空 segments 覆盖磁盘）。
    /// - Returns: 持久化失败信息（nil = 已成功落盘）。
    @discardableResult
    func save(_ item: TranscriptionItem) -> TranscriptionStore.PersistenceFailure? {
        let failure = item.transcriptHydrated
            ? TranscriptionStore.save(item)
            : TranscriptionStore.saveMetadata(item)
        return record(failure, context: "save \(item.id.uuidString)")
    }

    // MARK: 译文清除

    /// 清除某条记录的译文与对齐数据（语义化入口；**必须先 hydrate**）。
    ///
    /// 为什么不能直接 `item.translatedSegments = []; save(item)`：未 hydrate
    /// 的条目走 `saveMetadata`，而它只回写元数据、不碰译文字段 → 磁盘上的译文
    /// 与对齐数据原样保留，重启后"复活"。这里先 hydrate（成功则整条重存），
    /// hydrate 失败时退回 store 的磁盘层清除（只动译文字段，不碰转录内容）。
    /// - Returns: 持久化失败信息（nil = 已成功落盘）。
    @discardableResult
    func clearTranslations(for item: TranscriptionItem) -> TranscriptionStore.PersistenceFailure? {
        item.hydrateTranscriptIfNeeded()
        item.translatedSegments = []
        item.translationLanguage = nil
        let failure: TranscriptionStore.PersistenceFailure?
        if item.transcriptHydrated {
            failure = TranscriptionStore.save(item)
        } else {
            // 转录内容读不出来（文件缺失/损坏）：内存 segments 为空，整条重存
            // 会清空磁盘转录 → 改走磁盘层只清译文。
            failure = TranscriptionStore.clearTranslations(for: item.id)
        }
        return record(failure, context: "clearTranslations \(item.id.uuidString)")
    }

    /// 统一收口：记录失败状态 + 日志（成功则清空上次的失败状态）。
    private func record(_ failure: TranscriptionStore.PersistenceFailure?,
                        context: String) -> TranscriptionStore.PersistenceFailure? {
        if let failure {
            lastPersistenceFailure = failure
            AppLogger.shared.log(.ui, "History persistence FAILED (\(context)): \(failure.message)")
        } else {
            lastPersistenceFailure = nil
        }
        return failure
    }

    // MARK: 删除

    /// 删除单条记录（录音文件移废纸篓，可恢复）。
    /// 进行中的转录拒绝删除：转录完成回调会 `history.save(item)` 回写磁盘，
    /// 删除后必然复活（且指向已进废纸篓的音频）。此前只有批量删除做了这个
    /// 过滤，右键单条「移除」绕过 → 真实复活。
    /// - Returns: 是否删除成功。
    @discardableResult
    func remove(_ item: TranscriptionItem) -> Bool {
        guard item.status != .transcribing else {
            AppLogger.shared.log(.ui, "Refused to delete in-progress transcription \(item.id)")
            return false
        }
        items.removeAll { $0.id == item.id }
        TranscriptionStore.delete(item)
        return true
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
        // 载入期损坏的记录（loadIssues）时间戳取远古值、必然排在最旧，
        // 若参与裁剪会在用户还没看到前就被删掉——这等于把"静默丢弃"换个
        // 位置发生。把它们排除在裁剪之外（数量有界，不影响内存封顶）。
        let protectedIDs = Set(loadIssues.compactMap(\.id))
        // items 按时间倒序：suffix 即最旧。
        let toRemove = items
            .filter { $0.status != .transcribing && !protectedIDs.contains($0.id) }
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
