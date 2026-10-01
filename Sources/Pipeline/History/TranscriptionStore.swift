import Foundation

enum TranscriptionStore {

    // MARK: - Failure reporting

    /// 持久化失败的显式回报。
    ///
    /// 此前写盘失败只落日志：`HistoryManager.add` 不感知 → UI 显示"已完成"，
    /// 重启后记录凭空消失（用户数据静默丢失）。现在由 store 返回失败，
    /// 由 `TranscriptionHistoryManager` 收口并向 UI 暴露。
    /// 字段与 JSON 无关（不参与编解码），不影响磁盘格式兼容。
    struct PersistenceFailure: Error, Equatable, Sendable, LocalizedError {
        /// 失败的操作名（"save" / "saveMetadata" / "clearTranslations"）。
        let operation: String
        /// 可直接展示给用户的原因。
        let message: String

        var errorDescription: String? { message }
    }

    /// 载入期问题（JSON 损坏/不可读）。
    ///
    /// 损坏条目不再从列表剔除（文件仍在磁盘上，用户会看到记录"凭空消失"），
    /// 而是合成一条显式标记为失败的条目留在列表里；这里额外保留一份可查询
    /// 快照，供诊断/上报使用。
    struct LoadIssue: Equatable, Sendable {
        /// 由文件名恢复出的原记录 id（文件名即 `<uuid>.json`）。
        let id: UUID?
        let fileName: String
        let reason: String
    }

    /// 载入问题的线程安全暂存（`loadAll` 在后台线程并发解析，结果在主线程读）。
    private final class IssueBox: @unchecked Sendable {
        private let lock = NSLock()
        private var issues: [LoadIssue] = []

        func replace(with issues: [LoadIssue]) {
            lock.lock()
            self.issues = issues
            lock.unlock()
        }

        var snapshot: [LoadIssue] {
            lock.lock()
            defer { lock.unlock() }
            return issues
        }
    }

    private static let issueBox = IssueBox()

    /// 最近一次 `loadAll()` 遇到的损坏/不可读记录（快照）。
    static var loadIssues: [LoadIssue] { issueBox.snapshot }

    // MARK: - Codable DTO

    private struct StoredItem: Codable {
        let id: UUID
        var fileName: String
        var filePath: String
        let segments: [TranscriptionSegment]
        let fullText: String
        let dateAdded: Date
        var statusTag: String          // "completed", "failed", "pending"
        var errorMessage: String?
        // 译文字段必须可写：清除译文要读原 JSON、只改这两个字段后回写
        // （未 hydrate 的条目内存 segments 为空，整体重存会清掉转录内容）。
        // 类型/键名不变 → 旧 JSON 仍能读、新 JSON 仍能被旧版本读。
        var translatedSegments: [String]?
        var translationLanguage: String?
    }

    // MARK: - Directory

    private static var storeDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("WhisperASR", isDirectory: true)
            .appendingPathComponent("Transcriptions", isDirectory: true)
    }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: storeDirectory, withIntermediateDirectories: true
        )
    }

    private static func fileURL(for id: UUID) -> URL {
        storeDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private static var recordingsDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("WhisperASR", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Resolve a stored recording path, healing it if it no longer exists. After
    /// moving to a new Mac the absolute path embeds the old username and breaks;
    /// if a file of the same name sits in the local Recordings folder we re-link
    /// to it. Only kicks in when the original is missing, so files that live
    /// elsewhere (e.g. drag-dropped) are left untouched.
    private static func resolveRecordingURL(storedPath: String) -> URL {
        let original = URL(fileURLWithPath: storedPath)
        if FileManager.default.fileExists(atPath: storedPath) { return original }
        let candidate = recordingsDirectory.appendingPathComponent(original.lastPathComponent)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        return original
    }

    // MARK: - Save

    /// 整条写盘。
    /// - Returns: 失败信息（nil = 已成功落盘）。
    @discardableResult
    static func save(_ item: TranscriptionItem) -> PersistenceFailure? {
        ensureDirectory()

        let statusTag: String
        let errorMessage: String?
        switch item.status {
        case .completed:
            statusTag = "completed"
            errorMessage = nil
        case .failed(let msg):
            statusTag = "failed"
            errorMessage = msg
        default:
            statusTag = "pending"
            errorMessage = nil
        }

        let stored = StoredItem(
            id: item.id,
            fileName: item.fileName,
            filePath: item.fileURL.path,
            segments: item.segments,
            fullText: item.fullText,
            dateAdded: item.dateAdded,
            statusTag: statusTag,
            errorMessage: errorMessage,
            translatedSegments: item.translatedSegments.isEmpty ? nil : item.translatedSegments,
            translationLanguage: item.translationLanguage
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // 关键持久化路径：编码/写盘失败必须**向上返回**（此前只落日志——
        // 磁盘满/权限错误时用户看到"已完成"，重启后记录凭空消失）。
        do {
            let data = try encoder.encode(stored)
            try data.write(to: fileURL(for: item.id), options: .atomic)
            return nil
        } catch {
            AppLogger.shared.log(
                .ui,
                "TranscriptionStore.save FAILED (\(item.id.uuidString)): \(error.localizedDescription)")
            return PersistenceFailure(
                operation: "save",
                message: "Couldn't save this transcription to disk: \(error.localizedDescription)")
        }
    }

    // MARK: - Load

    static func loadAll() -> [TranscriptionItem] {
        ensureDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: storeDirectory, includingPropertiesForKeys: nil
        ) else { return [] }

        let jsonURLs = files.filter { $0.pathExtension == "json" }
        guard !jsonURLs.isEmpty else { return [] }

        let count = jsonURLs.count
        var items = [TranscriptionItem?](repeating: nil, count: count)
        var issues = [LoadIssue?](repeating: nil, count: count)

        // 多核并行反序列化：启动时并发读取/解析元数据，避免 500 个文件单线程卡顿。
        //
        // 并发写入必须经 UnsafeMutableBufferPointer：Swift Array 即使在多线程下
        // 各写不同下标也**不保证安全**（会触发排他性检查或元素错位），此前直接
        // `items[index] = item` 属未定义行为。缓冲已预分配、每个下标恰好由一个
        // 迭代写入、无下标会被写两次；concurrentPerform 返回即全部写入完成
        //（happens-before），随后再读 `items` 安全。
        items.withUnsafeMutableBufferPointer { buffer in
            issues.withUnsafeMutableBufferPointer { issueBuffer in
                guard let base = buffer.baseAddress,
                      let issueBase = issueBuffer.baseAddress else { return }
                DispatchQueue.concurrentPerform(iterations: count) { index in
                    let url = jsonURLs[index]
                    // 文件名即记录 id（`<uuid>.json`）：损坏时也能还原 id 与来源，
                    // 从而合成一条可识别、可删除、可排查的"损坏"条目。
                    let stem = url.deletingPathExtension().lastPathComponent
                    let recoveredID = UUID(uuidString: stem)

                    guard let data = try? Data(contentsOf: url) else {
                        let reason = "Stored record is unreadable (file could not be read). "
                            + "The file is kept on disk."
                        AppLogger.shared.log(
                            .ui, "loadAll: unreadable file \(url.lastPathComponent) (kept as failed item)")
                        issueBase[index] = LoadIssue(id: recoveredID, fileName: url.lastPathComponent,
                                                     reason: reason)
                        base[index] = corruptItem(id: recoveredID, stem: stem, url: url, reason: reason)
                        return
                    }
                    guard let stored = try? JSONDecoder().decode(StoredItem.self, from: data) else {
                        // 损坏/半写的 JSON：**不剔除**——文件仍在磁盘上，剔除等于
                        // 用户数据凭空消失。合成为显式失败的条目（列表可见、可删、
                        // 可排查），并记入 loadIssues。
                        let reason = "Stored record is unreadable (corrupt JSON). "
                            + "The file is kept on disk."
                        AppLogger.shared.log(
                            .ui, "loadAll: corrupt JSON \(url.lastPathComponent) (kept as failed item)")
                        issueBase[index] = LoadIssue(id: recoveredID, fileName: url.lastPathComponent,
                                                     reason: reason)
                        base[index] = corruptItem(id: recoveredID, stem: stem, url: url, reason: reason)
                        return
                    }

                    let status: TranscriptionStatus
                    switch stored.statusTag {
                    case "completed": status = .completed
                    case "failed":    status = .failed(stored.errorMessage ?? "Unknown error")
                    default:          status = .pending
                    }

                    // 懒加载：fullText 供列表/搜索（小头），segments 与译文
                    //（内存大头）延迟到条目被打开时载入（hydrateTranscriptIfNeeded）。
                    let item = TranscriptionItem(
                        id: stored.id,
                        fileName: stored.fileName,
                        fileURL: resolveRecordingURL(storedPath: stored.filePath),
                        dateAdded: stored.dateAdded,
                        status: status,
                        segments: [],
                        fullText: stored.fullText,
                        translatedSegments: [],
                        translationLanguage: nil
                    )
                    item.transcriptHydrated = false
                    base[index] = item
                }
            }
        }

        issueBox.replace(with: issues.compactMap { $0 })
        return items.compactMap { $0 }.sorted { $0.dateAdded > $1.dateAdded }
    }

    /// 合成"损坏记录"条目：id 由文件名还原（`<uuid>.json`），时间戳取远古值
    /// 使其排在列表末尾；`transcriptHydrated = false` 保证后续任何 save 走
    /// `saveMetadata`（不会用空 segments 覆盖磁盘），且因 JSON 无法解码，
    /// saveMetadata 会返回失败而不会误写。
    private static func corruptItem(id: UUID?, stem: String, url: URL, reason: String)
        -> TranscriptionItem {
        let item = TranscriptionItem(
            id: id ?? UUID(),
            fileName: stem + ".json",
            fileURL: url,
            dateAdded: .distantPast,
            status: .failed(reason),
            segments: [],
            fullText: "",
            translatedSegments: [],
            translationLanguage: nil
        )
        item.transcriptHydrated = false
        return item
    }

    /// 载入单条记录的完整转录内容（懒加载用；文件缺失/损坏返回 nil）。
    static func loadTranscript(for id: UUID)
        -> (segments: [TranscriptionSegment],
            translatedSegments: [String],
            translationLanguage: String?)? {
        guard let data = try? Data(contentsOf: fileURL(for: id)),
              let stored = try? JSONDecoder().decode(StoredItem.self, from: data)
        else { return nil }
        return (stored.segments, stored.translatedSegments ?? [], stored.translationLanguage)
    }

    /// 仅回写元数据（文件名 / 状态 / 错误信息）：读磁盘 JSON 原文替换元数据
    /// 字段后写回。未 hydrate 的条目内存里 segments 为空，禁止整体重存
    /// （否则会把磁盘上的转录内容清空）。
    /// - Returns: 失败信息（nil = 已成功落盘）。
    @discardableResult
    static func saveMetadata(_ item: TranscriptionItem) -> PersistenceFailure? {
        let url = fileURL(for: item.id)
        guard let data = try? Data(contentsOf: url),
              var stored = try? JSONDecoder().decode(StoredItem.self, from: data)
        else {
            // 静默返回会让 UI 显示新名字、磁盘保持旧值（重启后改动"消失"），
            // 外部删除/JSON 损坏也无从发现——现在返回失败让调用方感知。
            let message = "The stored record is missing or unreadable, so the change "
                + "couldn't be written to disk."
            AppLogger.shared.log(
                .ui,
                "TranscriptionStore.saveMetadata skipped (missing/corrupt JSON) \(item.id.uuidString)")
            return PersistenceFailure(operation: "saveMetadata", message: message)
        }
        stored.fileName = item.fileName
        stored.filePath = item.fileURL.path
        let statusTag: String
        var errorMessage: String? = nil
        switch item.status {
        case .completed: statusTag = "completed"
        case .failed(let msg): statusTag = "failed"; errorMessage = msg
        default: statusTag = "pending"
        }
        stored.statusTag = statusTag
        stored.errorMessage = errorMessage
        do {
            let encoded = try JSONEncoder().encode(stored)
            try encoded.write(to: url, options: .atomic)
            return nil
        } catch {
            AppLogger.shared.log(
                .ui,
                "TranscriptionStore.saveMetadata FAILED (\(item.id.uuidString)): \(error.localizedDescription)")
            return PersistenceFailure(
                operation: "saveMetadata",
                message: "Couldn't update this record on disk: \(error.localizedDescription)")
        }
    }

    // MARK: - Clear translations

    /// 磁盘层清除译文与对齐数据（**不依赖内存 hydrate**）。
    ///
    /// 为什么需要这个入口：`AppState.clearTranslation` 先清内存再 `history.save`，
    /// 而未 hydrate 的条目走 `saveMetadata`——它只回写元数据、完全不碰译文字段，
    /// 于是磁盘上的译文原样保留，重启后"复活"。
    /// 这里直接读原 JSON、只清 `translatedSegments` / `translationLanguage`
    /// 后回写：不碰 `segments`，所以未 hydrate 也不会清掉磁盘转录内容。
    /// - Returns: 失败信息（nil = 已成功落盘）。
    @discardableResult
    static func clearTranslations(for id: UUID) -> PersistenceFailure? {
        let url = fileURL(for: id)
        guard let data = try? Data(contentsOf: url),
              var stored = try? JSONDecoder().decode(StoredItem.self, from: data)
        else {
            let message = "The stored record is missing or unreadable, so its translation "
                + "couldn't be cleared."
            AppLogger.shared.log(
                .ui,
                "TranscriptionStore.clearTranslations skipped (missing/corrupt JSON) \(id.uuidString)")
            return PersistenceFailure(operation: "clearTranslations", message: message)
        }
        stored.translatedSegments = nil
        stored.translationLanguage = nil
        do {
            let encoded = try JSONEncoder().encode(stored)
            try encoded.write(to: url, options: .atomic)
            return nil
        } catch {
            AppLogger.shared.log(
                .ui,
                "TranscriptionStore.clearTranslations FAILED (\(id.uuidString)): \(error.localizedDescription)")
            return PersistenceFailure(
                operation: "clearTranslations",
                message: "Couldn't clear the translation on disk: \(error.localizedDescription)")
        }
    }

    // MARK: - Delete

    /// Whether the audio file lives in the app's own Recordings folder, i.e. was
    /// recorded by WhisperASR rather than imported (drag-drop / file picker).
    static func isAppRecording(_ url: URL) -> Bool {
        url.standardizedFileURL.path
            .hasPrefix(recordingsDirectory.standardizedFileURL.path + "/")
    }

    static func delete(_ item: TranscriptionItem) {
        // 删除失败必须留痕：JSON 残留会让已删除条目在下次启动 loadAll 时
        // "复活"（内存已移除、磁盘仍在），用户会看到记录删了又出现。
        do {
            try FileManager.default.removeItem(at: fileURL(for: item.id))
        } catch {
            AppLogger.shared.log(
                .ui,
                "TranscriptionStore.delete FAILED (\(item.id.uuidString)): \(error.localizedDescription) "
                + "— item may reappear on next launch")
        }
        // Only audio the app recorded is ours to dispose of — and it goes to the
        // Trash, not straight to deletion. Imported files are left untouched.
        if isAppRecording(item.fileURL) {
            do {
                try FileManager.default.trashItem(at: item.fileURL, resultingItemURL: nil)
            } catch {
                AppLogger.shared.log(
                    .ui,
                    "TranscriptionStore.trash FAILED (\(item.fileURL.lastPathComponent)): \(error.localizedDescription)")
            }
        }
    }
}
