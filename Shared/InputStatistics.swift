import Foundation
import SQLite3

enum InputStatisticsSource: Equatable {
    case typed
    case voice
}

struct InputStatisticsDay: Equatable {
    let key: Int
    let typed: Int
    let voice: Int

    var total: Int { typed + voice }
}

struct InputStatisticsSnapshot: Equatable {
    let days: [Int: InputStatisticsDay]
    let sharedStorageAvailable: Bool

    var typed: Int { days.values.reduce(0) { $0 + $1.typed } }
    var voice: Int { days.values.reduce(0) { $0 + $1.voice } }
    var total: Int { typed + voice }

    func day(for key: Int) -> InputStatisticsDay {
        days[key] ?? InputStatisticsDay(key: key, typed: 0, voice: 0)
    }

    static let empty = InputStatisticsSnapshot(days: [:], sharedStorageAvailable: true)
}

enum InputStatisticsError: LocalizedError {
    case database(String)
    case localStorageUnavailable

    var errorDescription: String? {
        switch self {
        case .database(let message): return message
        case .localStorageUnavailable: return "无法保存本机输入统计。"
        }
    }
}

enum InputStatisticsStore {
    private static let group = "group.local.yah.voice"
    private static let queue = DispatchQueue(label: "local.yah.input-statistics", qos: .utility)

    static func characterCount(in text: String) -> Int {
        text.reduce(into: 0) { count, character in
            if !character.isWhitespace { count += 1 }
        }
    }

    static func dayKey(for date: Date = Date(), timeZone: TimeZone = .current) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    static func date(forDayKey key: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var parts = DateComponents()
        parts.year = key / 10_000
        parts.month = (key / 100) % 100
        parts.day = key % 100
        parts.hour = 12
        return calendar.date(from: parts)
    }

    static func level(for total: Int) -> Int {
        guard total > 0 else { return 1 }
        return max(1, Int((1 + sqrt(1 + 8 * Double(total) / 100)) / 2))
    }

    static func threshold(for level: Int) -> Int {
        50 * max(0, level - 1) * max(0, level)
    }

    static func record(_ text: String, as source: InputStatisticsSource) {
        let count = characterCount(in: text)
        guard count > 0 else { return }
        let day = dayKey()
        queue.async {
            do {
                let typed = source == .typed ? count : 0
                let voice = source == .voice ? count : 0
                guard let local = try openLocalDatabase() else {
                    if let shared = try openSharedDatabase() {
                        try shared.increment(day: day, typed: typed, voice: voice)
                        return
                    }
                    throw InputStatisticsError.localStorageUnavailable
                }
                try local.recordSource(day: day, typed: typed, voice: voice)
                if let shared = try openSharedDatabase() { _ = try migrate(local: local, into: shared) }
            } catch {
                NSLog("Yah input statistics write failed: %@", error.localizedDescription)
            }
        }
    }

    static func load(completion: @escaping (Result<InputStatisticsSnapshot, Error>) -> Void) {
        queue.async {
            do {
                guard let shared = try openSharedDatabase() else {
                    completion(.success(InputStatisticsSnapshot(days: [:], sharedStorageAvailable: false)))
                    return
                }
                if let local = try openLocalDatabase() {
                    _ = try migrate(local: local, into: shared)
                }
                completion(.success(InputStatisticsSnapshot(
                    days: try shared.days(),
                    sharedStorageAvailable: true
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func openSharedDatabase() throws -> StatisticsDatabase? {
        guard let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: group
        ) else { return nil }
        return try StatisticsDatabase(url: directory.appendingPathComponent("input-statistics.sqlite"), isShared: true)
    }

    private static func openLocalDatabase() throws -> StatisticsDatabase? {
        guard let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try StatisticsDatabase(url: directory.appendingPathComponent("input-statistics.sqlite"), isShared: false)
    }

    private static func migrate(local: StatisticsDatabase, into shared: StatisticsDatabase) throws -> Int {
        let sourceID = try local.sourceID()
        let pending = try local.pendingRecords()
        guard !pending.isEmpty else { return 0 }
        let merged = try shared.merge(pending, sourceID: sourceID)
        try local.clearPending(merged)
        return merged.count
    }
}

final class StatisticsDatabase {
    struct PendingRecord {
        let day: Int
        let version: Int
        let typed: Int
        let voice: Int
    }

    private var handle: OpaquePointer?

    init(url: URL, isShared: Bool) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite 无法打开数据库"
            if let database { sqlite3_close(database) }
            throw InputStatisticsError.database(message)
        }
        handle = database
        sqlite3_busy_timeout(database, 1_500)
        try execute("PRAGMA journal_mode=WAL")
        try execute("""
            CREATE TABLE IF NOT EXISTS days (
                day INTEGER PRIMARY KEY,
                typed INTEGER NOT NULL DEFAULT 0,
                voice INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS pending (
                day INTEGER PRIMARY KEY,
                version INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """)
        if isShared {
            try execute("""
                CREATE TABLE IF NOT EXISTS watermarks (
                    source_id TEXT NOT NULL,
                    day INTEGER NOT NULL,
                    typed INTEGER NOT NULL,
                    voice INTEGER NOT NULL,
                    PRIMARY KEY (source_id, day)
                );
                """)
        }
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func increment(day: Int, typed: Int, voice: Int) throws {
        try transaction {
            try add(day: day, typed: typed, voice: voice)
        }
    }

    func recordSource(day: Int, typed: Int, voice: Int) throws {
        try transaction {
            try add(day: day, typed: typed, voice: voice)
            let pending = try prepare("""
                INSERT INTO pending (day, version) VALUES (?, 1)
                ON CONFLICT(day) DO UPDATE SET version = version + 1
                """)
            defer { sqlite3_finalize(pending) }
            sqlite3_bind_int64(pending, 1, sqlite3_int64(day))
            try stepDone(pending)
        }
    }

    func sourceID() throws -> String {
        let query = try prepare("SELECT value FROM metadata WHERE key = 'source-id'")
        defer { sqlite3_finalize(query) }
        let status = sqlite3_step(query)
        if status == SQLITE_ROW, let rawValue = sqlite3_column_text(query, 0) {
            let value = String(cString: rawValue)
            guard sqlite3_step(query) == SQLITE_DONE else { throw databaseError() }
            return value
        }
        guard status == SQLITE_DONE else { throw databaseError() }
        let value = UUID().uuidString
        let insert = try prepare("INSERT OR IGNORE INTO metadata (key, value) VALUES ('source-id', ?)")
        defer { sqlite3_finalize(insert) }
        bind(value, at: 1, to: insert)
        try stepDone(insert)
        let resolved = try prepare("SELECT value FROM metadata WHERE key = 'source-id'")
        defer { sqlite3_finalize(resolved) }
        guard sqlite3_step(resolved) == SQLITE_ROW,
              let rawResolved = sqlite3_column_text(resolved, 0) else { throw databaseError() }
        let sourceID = String(cString: rawResolved)
        guard sqlite3_step(resolved) == SQLITE_DONE else { throw databaseError() }
        return sourceID
    }

    func pendingRecords() throws -> [PendingRecord] {
        let statement = try prepare("""
            SELECT pending.day, pending.version, days.typed, days.voice
            FROM pending
            JOIN days ON days.day = pending.day
            """)
        defer { sqlite3_finalize(statement) }
        var records: [PendingRecord] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            records.append(PendingRecord(
                day: Int(sqlite3_column_int64(statement, 0)),
                version: Int(sqlite3_column_int64(statement, 1)),
                typed: Int(sqlite3_column_int64(statement, 2)),
                voice: Int(sqlite3_column_int64(statement, 3))
            ))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw databaseError() }
        return records
    }

    func merge(_ records: [PendingRecord], sourceID: String) throws -> [PendingRecord] {
        try transaction {
            let query = try prepare("SELECT typed, voice FROM watermarks WHERE source_id = ? AND day = ?")
            defer { sqlite3_finalize(query) }
            let upsert = try prepare("""
                INSERT INTO watermarks (source_id, day, typed, voice) VALUES (?, ?, ?, ?)
                ON CONFLICT(source_id, day) DO UPDATE SET
                    typed = MAX(typed, excluded.typed),
                    voice = MAX(voice, excluded.voice)
                """)
            defer { sqlite3_finalize(upsert) }
            for record in records {
                sqlite3_reset(query)
                sqlite3_clear_bindings(query)
                bind(sourceID, at: 1, to: query)
                sqlite3_bind_int64(query, 2, sqlite3_int64(record.day))
                let status = sqlite3_step(query)
                let previousTyped = status == SQLITE_ROW ? Int(sqlite3_column_int64(query, 0)) : 0
                let previousVoice = status == SQLITE_ROW ? Int(sqlite3_column_int64(query, 1)) : 0
                if status == SQLITE_ROW {
                    guard sqlite3_step(query) == SQLITE_DONE else { throw databaseError() }
                } else if status != SQLITE_DONE {
                    throw databaseError()
                }

                let typedDelta = max(0, record.typed - previousTyped)
                let voiceDelta = max(0, record.voice - previousVoice)
                if typedDelta > 0 || voiceDelta > 0 {
                    try add(day: record.day, typed: typedDelta, voice: voiceDelta)
                }

                sqlite3_reset(upsert)
                sqlite3_clear_bindings(upsert)
                bind(sourceID, at: 1, to: upsert)
                sqlite3_bind_int64(upsert, 2, sqlite3_int64(record.day))
                sqlite3_bind_int64(upsert, 3, sqlite3_int64(max(record.typed, previousTyped)))
                sqlite3_bind_int64(upsert, 4, sqlite3_int64(max(record.voice, previousVoice)))
                try stepDone(upsert)
            }
        }
        return records
    }

    func clearPending(_ records: [PendingRecord]) throws {
        guard !records.isEmpty else { return }
        try transaction {
            let statement = try prepare("DELETE FROM pending WHERE day = ? AND version = ?")
            defer { sqlite3_finalize(statement) }
            for record in records {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_int64(statement, 1, sqlite3_int64(record.day))
                sqlite3_bind_int64(statement, 2, sqlite3_int64(record.version))
                try stepDone(statement)
            }
        }
    }

    func days() throws -> [Int: InputStatisticsDay] {
        let statement = try prepare("SELECT day, typed, voice FROM days")
        defer { sqlite3_finalize(statement) }
        var result: [Int: InputStatisticsDay] = [:]
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let key = Int(sqlite3_column_int64(statement, 0))
            result[key] = InputStatisticsDay(
                key: key,
                typed: Int(sqlite3_column_int64(statement, 1)),
                voice: Int(sqlite3_column_int64(statement, 2))
            )
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw databaseError() }
        return result
    }

    private func add(day: Int, typed: Int, voice: Int) throws {
        let statement = try prepare("""
            INSERT INTO days (day, typed, voice) VALUES (?, ?, ?)
            ON CONFLICT(day) DO UPDATE SET
                typed = typed + excluded.typed,
                voice = voice + excluded.voice
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sqlite3_int64(day))
        sqlite3_bind_int64(statement, 2, sqlite3_int64(typed))
        sqlite3_bind_int64(statement, 3, sqlite3_int64(voice))
        try stepDone(statement)
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw databaseError()
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? databaseError().localizedDescription
            sqlite3_free(message)
            throw InputStatisticsError.database(detail)
        }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() }
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func databaseError() -> InputStatisticsError {
        .database(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite 操作失败")
    }
}
