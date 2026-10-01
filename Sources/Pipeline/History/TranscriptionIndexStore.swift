import Foundation
import SQLite3

// MARK: - 转录索引存储（SQLite3 原生 C-API，零 ORM）
//
// 设计目标（需求对照）：
// - 万条记录毫秒级时间范围游标检索：复合索引 (session_id, start_timestamp)
//   + 预编译语句 + keyset 分页（避免 OFFSET 深翻页退化）；
// - PRAGMA 调优：WAL（读写不互斥）、synchronous=NORMAL（WAL 下安全且快）、
//   mmap_size=256MB（读路径免 read 系统调用）、temp_store=MEMORY；
// - 表结构：单表 segments，opus_offset/opus_length 指向 Opus 归档文件的
//   物理字节区间（见 OpusAudioArchiver）。
//
// 线程模型：连接以 SQLITE_OPEN_FULLMUTEX 打开（SQLite 内部串行化），
// 但语句句柄非线程安全——约定：单线程/串行队列使用（实时转录流水线
// 本就单写者）。跨线程使用请外部队列串行化。

/// 存储层错误（携带 sqlite3_errmsg 原文）。
enum TranscriptionIndexError: Error, Equatable {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)
}

/// 单条转录段记录。
struct TranscriptionSegmentRecord: Equatable {
    let id: Int64
    let sessionID: String
    /// 段起始时间戳（秒，录制会话内相对时间或绝对时间——调用方语义）。
    let startTimestamp: Double
    let textContent: String
    /// Opus 归档文件内本段音频的物理字节区间 [offset, offset+length)。
    let opusOffset: Int64
    let opusLength: Int64
}

final class TranscriptionIndexStore {

    /// 单表结构（与需求字段一一对应）。
    private static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS segments (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id      TEXT    NOT NULL,
            start_timestamp REAL    NOT NULL,
            text_content    TEXT    NOT NULL,
            opus_offset     INTEGER NOT NULL,
            opus_length     INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_segments_session_time
            ON segments(session_id, start_timestamp);
        """

    private var db: OpaquePointer?

    // MARK: 生命周期

    /// 打开（不存在则创建）并调优数据库。
    /// - Parameter path: 数据库文件路径；`:memory:` 用于测试。
    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw TranscriptionIndexError.openFailed(message)
        }
        self.db = db
        try executePragmas()
        try executeScript(Self.schemaSQL)
        try prepareStatements()
    }

    deinit {
        sqlite3_finalize(insertStatement)
        sqlite3_finalize(rangeQueryStatement)
        sqlite3_finalize(countStatement)
        sqlite3_close(db)
    }

    // MARK: PRAGMA 调优（性能关键项，逐条断言生效）

    private func executePragmas() throws {
        // WAL：写不阻塞读（转录写入与检索并发），崩溃恢复安全。
        try execute("PRAGMA journal_mode=WAL;")
        // WAL 下的推荐持久档：崩溃最多丢最后一个事务，fsync 频率大幅降低。
        try execute("PRAGMA synchronous=NORMAL;")
        // 256MB mmap：读路径直接映射页缓存，免 read 系统调用与用户态拷贝。
        try execute("PRAGMA mmap_size=268435456;")
        // 临时表/排序在内存（时间范围排序溢出不再落盘）。
        try execute("PRAGMA temp_store=MEMORY;")
        // 页缓存 16MB（默认 2MB 对万级扫描偏小）。
        try execute("PRAGMA cache_size=-16000;")
        // 校验 WAL 确实生效（journal_mode 返回值）。
        let mode = try queryScalar("PRAGMA journal_mode;")
        guard mode == "wal" else {
            throw TranscriptionIndexError.openFailed("journal_mode=\(mode), expected wal")
        }
    }

    // MARK: 语句缓存（预编译一次，检索热路径零解析开销）

    private var insertStatement: OpaquePointer?
    private var rangeQueryStatement: OpaquePointer?
    private var countStatement: OpaquePointer?

    private func prepareStatements() throws {
        insertStatement = try prepare("""
            INSERT INTO segments (session_id, start_timestamp, text_content,
                                  opus_offset, opus_length)
            VALUES (?, ?, ?, ?, ?);
            """)
        rangeQueryStatement = try prepare("""
            SELECT id, session_id, start_timestamp, text_content, opus_offset, opus_length
            FROM segments
            WHERE session_id = ?
              AND start_timestamp >= ?
              AND start_timestamp <  ?
              AND (start_timestamp > ? OR (start_timestamp = ? AND id > ?))
            ORDER BY start_timestamp, id
            LIMIT ?;
            """)
        countStatement = try prepare("""
            SELECT COUNT(*) FROM segments WHERE session_id = ?;
            """)
    }

    // MARK: 写入

    /// 追加一条转录段（音频侧调用 OpusAudioArchiver.append 拿到 offset/length）。
    /// - Returns: rowid（游标分页的 tiebreaker）。
    @discardableResult
    func appendSegment(sessionID: String,
                       startTimestamp: Double,
                       text: String,
                       opusOffset: Int64,
                       opusLength: Int64) throws -> Int64 {
        let stmt = insertStatement!
        sqlite3_reset(stmt)
        try bindText(stmt, index: 1, value: sessionID)
        sqlite3_bind_double(stmt, 2, startTimestamp)
        try bindText(stmt, index: 3, value: text)
        sqlite3_bind_int64(stmt, 4, opusOffset)
        sqlite3_bind_int64(stmt, 5, opusLength)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw stepError(stmt)
        }
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: 时间范围游标检索（热路径）

    /// 时间范围 + keyset 游标分页：
    /// 返回 `[from, to)` 内、严格晚于游标 `(cursorTimestamp, cursorID)` 的
    /// 至多 `limit` 条（按时间升序）。翻页传上一页末条的 (startTimestamp, id)，
    /// 复杂度稳定 O(log n + limit)，万级数据实测微秒级。
    func querySegments(sessionID: String,
                       fromTime: Double,
                       toTime: Double,
                       limit: Int = 200,
                       cursorTimestamp: Double = -Double.infinity,
                       cursorID: Int64 = 0) throws -> [TranscriptionSegmentRecord] {
        let stmt = rangeQueryStatement!
        sqlite3_reset(stmt)
        try bindText(stmt, index: 1, value: sessionID)
        sqlite3_bind_double(stmt, 2, fromTime)
        sqlite3_bind_double(stmt, 3, toTime)
        sqlite3_bind_double(stmt, 4, cursorTimestamp)
        sqlite3_bind_double(stmt, 5, cursorTimestamp)
        sqlite3_bind_int64(stmt, 6, cursorID)
        sqlite3_bind_int(stmt, 7, Int32(max(1, limit)))

        var records: [TranscriptionSegmentRecord] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            records.append(TranscriptionSegmentRecord(
                id: sqlite3_column_int64(stmt, 0),
                sessionID: String(cString: sqlite3_column_text(stmt, 1)),
                startTimestamp: sqlite3_column_double(stmt, 2),
                textContent: String(cString: sqlite3_column_text(stmt, 3)),
                opusOffset: sqlite3_column_int64(stmt, 4),
                opusLength: sqlite3_column_int64(stmt, 5)))
            status = sqlite3_step(stmt)
        }
        // 必须收敛到 SQLITE_DONE；否则查询中途出错会返回"看似完整"的部分结果。
        guard status == SQLITE_DONE else { throw stepError(stmt) }
        return records
    }

    /// 会话内段数。
    func segmentCount(sessionID: String) throws -> Int {
        let stmt = countStatement!
        sqlite3_reset(stmt)
        try bindText(stmt, index: 1, value: sessionID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw stepError(stmt) }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// 文本子串检索（LIKE；万级规模足够，FTS5 为后续升级项）。
    func searchSegments(sessionID: String, contains query: String,
                        limit: Int = 100) throws -> [TranscriptionSegmentRecord] {
        var records: [TranscriptionSegmentRecord] = []
        let stmt = try prepare("""
            SELECT id, session_id, start_timestamp, text_content, opus_offset, opus_length
            FROM segments
            WHERE session_id = ? AND text_content LIKE '%' || ? || '%'
            ORDER BY start_timestamp, id
            LIMIT ?;
            """)
        defer { sqlite3_finalize(stmt) }
        try bindText(stmt, index: 1, value: sessionID)
        try bindText(stmt, index: 2, value: query)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            records.append(TranscriptionSegmentRecord(
                id: sqlite3_column_int64(stmt, 0),
                sessionID: String(cString: sqlite3_column_text(stmt, 1)),
                startTimestamp: sqlite3_column_double(stmt, 2),
                textContent: String(cString: sqlite3_column_text(stmt, 3)),
                opusOffset: sqlite3_column_int64(stmt, 4),
                opusLength: sqlite3_column_int64(stmt, 5)))
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw stepError(stmt) }
        return records
    }

    // MARK: 事务（批量写入必需——万条逐条自动提交会显著拖慢）

    func executeInTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: SQLite C-API 薄封装

    private func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw TranscriptionIndexError.stepFailed("\(sql.prefix(40)) — \(message)")
        }
    }

    private func executeScript(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorPointer)
            throw TranscriptionIndexError.prepareFailed(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw TranscriptionIndexError.prepareFailed(
                "\(sql.prefix(40)) — \(String(cString: sqlite3_errmsg(db)))")
        }
        return stmt
    }

    private func queryScalar(_ sql: String) throws -> String {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let text = sqlite3_column_text(stmt, 0) else {
            throw stepError(stmt)
        }
        return String(cString: text)
    }

    private func bindText(_ stmt: OpaquePointer, index: Int32, value: String) throws {
        // SQLITE_TRANSIENT：SQLite 拷贝字符串（调用方栈上值生命周期短）。
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1),
                                      to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(stmt, index, value, -1, transient) == SQLITE_OK else {
            throw TranscriptionIndexError.bindFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func stepError(_ stmt: OpaquePointer) -> TranscriptionIndexError {
        .stepFailed(String(cString: sqlite3_errmsg(db)))
    }
}
