import Foundation
import SQLite3

final class JournalStore {
    private let db: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    struct DatabaseError: LocalizedError {
        var errorDescription: String? { "DaySpool could not open or update its local journal." }
    }

    static func local() throws -> JournalStore {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
            .appendingPathComponent("DaySpool", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        return try JournalStore(path: folder.appendingPathComponent("journal.sqlite").path)
    }

    init(path: String) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw DatabaseError()
        }
        db = handle
        do {
            if path != ":memory:" {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
            try script("""
                PRAGMA foreign_keys = ON;
                PRAGMA secure_delete = ON;
                CREATE TABLE IF NOT EXISTS events (
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL,
                    bundle TEXT NOT NULL, app TEXT NOT NULL, window TEXT NOT NULL, body TEXT NOT NULL,
                    session TEXT REFERENCES events(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS events_start ON events(start);
                CREATE INDEX IF NOT EXISTS events_session ON events(session);
                CREATE TABLE IF NOT EXISTS reports (
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL,
                    state TEXT NOT NULL DEFAULT 'pending', next_attempt REAL NOT NULL DEFAULT 0, content TEXT
                );
                CREATE INDEX IF NOT EXISTS reports_range ON reports(kind, start, end);
                CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value REAL NOT NULL);
                """)
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    func insert(_ event: JournalEvent) throws {
        try execute("INSERT INTO events VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", [
            event.id, event.kind.rawValue, event.start, event.end, event.bundleID, event.appName,
            event.window, event.body, event.sessionID
        ])
    }

    func insertBatch(_ events: [JournalEvent]) throws {
        guard !events.isEmpty else { return }
        try transaction {
            for event in events { try insert(event) }
        }
    }

    func extend(_ id: String, to end: Date) throws {
        try execute("UPDATE events SET end = MAX(end, ?) WHERE id = ? AND kind = 'activity'", [end, id])
    }

    func recent(search: String = "", kind: EventKind? = nil, limit: Int = 350) throws -> [JournalEvent] {
        if let kind {
            if search.isEmpty {
                return try query("SELECT * FROM events WHERE kind = ? ORDER BY start DESC LIMIT ?",
                                 [kind.rawValue, limit], row: Self.event)
            }
            return try query("""
                SELECT * FROM events WHERE kind = ?
                AND instr(lower(app || ' ' || window || ' ' || body), lower(?)) > 0
                ORDER BY start DESC LIMIT ?
                """, [kind.rawValue, search, limit], row: Self.event)
        }
        if search.isEmpty {
            return try query("SELECT * FROM events ORDER BY start DESC LIMIT ?", [limit], row: Self.event)
        }
        return try query("""
            SELECT * FROM events
            WHERE instr(lower(app || ' ' || window || ' ' || body), lower(?)) > 0
            ORDER BY start DESC LIMIT ?
            """, [search, limit], row: Self.event)
    }

    func event(id: String) throws -> JournalEvent? {
        try query("SELECT * FROM events WHERE id = ?", [id], row: Self.event).first
    }

    func evidence(for period: ReportPeriod, filesSince: Date? = nil) throws -> [JournalEvent] {
        // Keep a sample from each ten-minute slice, even during high-frequency editing.
        try query("""
            WITH candidates AS (
                SELECT *, ROW_NUMBER() OVER (
                    PARTITION BY kind, CAST((MAX(start, ?) - ?) / 600 AS INTEGER)
                    ORDER BY start DESC
                ) AS position
                FROM events WHERE start < ? AND (start >= ? OR end > ?) AND (kind != 'file' OR start >= ?)
            )
            SELECT id, kind, start, end, bundle, app, window, body, session
            FROM candidates WHERE position <= 4 ORDER BY position, start
            """, [period.start, period.start, period.end, period.start, period.start, filesSince], row: Self.event)
    }

    func enqueueClosed(now: Date, calendar: Calendar) throws {
        guard let first = try query("SELECT MIN(start) FROM events", row: { row in
            sqlite3_column_type(row, 0) == SQLITE_NULL ? nil : Self.date(row, 0)
        }).first else { return }
        let scan = try query("SELECT value FROM metadata WHERE key = 'last_scan'", row: { Self.date($0, 0) }).first
        let begin = min(now, max(first, scan ?? first))
        try transaction {
            for kind in ReportKind.allCases {
                for period in ReportCalendar.closedPeriods(kind: kind, first: begin, now: now, calendar: calendar) {
                    let hasEvents = try query("""
                        SELECT 1 FROM events WHERE start < ? AND (start >= ? OR end > ?) LIMIT 1
                        """, [period.end, period.start, period.start], row: { _ in true }).first ?? false
                    if hasEvents {
                        try enqueue(period)
                    }
                }
            }
            try execute("INSERT OR REPLACE INTO metadata VALUES ('last_scan', ?)", [now])
        }
    }

    func enqueue(_ period: ReportPeriod) throws {
        try execute("INSERT OR IGNORE INTO reports(id, kind, start, end) VALUES (?, ?, ?, ?)",
                    [period.id, period.kind.rawValue, period.start, period.end])
    }

    func due(now: Date, after cutoff: Date = .distantPast) throws -> StoredReport? {
        try query("""
            SELECT r.* FROM reports r WHERE r.state != 'ready' AND r.next_attempt <= ?
            AND r.id NOT LIKE 'manual:%' AND r.end > ?
            AND NOT EXISTS (
                SELECT 1 FROM reports c
                WHERE c.kind = CASE r.kind WHEN 'day' THEN 'hour' WHEN 'week' THEN 'day' ELSE '' END
                AND c.start >= r.start AND c.end <= r.end AND c.state != 'ready'
                AND c.id NOT LIKE 'manual:%' AND c.end > ?
            )
            ORDER BY CASE r.kind WHEN 'hour' THEN 0 WHEN 'day' THEN 1 ELSE 2 END, r.start DESC LIMIT 1
            """, [now, cutoff, cutoff], row: Self.report).first
    }

    func reports(kind: ReportKind? = nil, inside parent: ReportPeriod? = nil, after cutoff: Date = .distantPast) throws -> [StoredReport] {
        if let kind, let parent {
            return try query("""
                SELECT * FROM reports WHERE kind = ? AND start >= ? AND end <= ?
                AND id NOT LIKE 'manual:%' AND end > ? ORDER BY start
                """, [kind.rawValue, parent.start, parent.end, cutoff], row: Self.report)
        }
        if let kind {
            return try query("SELECT * FROM reports WHERE kind = ? ORDER BY start DESC LIMIT 250",
                             [kind.rawValue], row: Self.report)
        }
        return try ReportKind.allCases.flatMap { try reports(kind: $0) }
    }

    func save(_ report: ReportContent, for period: ReportPeriod) throws {
        let content = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        try execute("UPDATE reports SET state = 'ready', content = ?, next_attempt = 0 WHERE id = ?",
                    [content, period.id])
    }

    func fail(_ period: ReportPeriod, retry: Date) throws {
        try execute("UPDATE reports SET state = 'failed', next_attempt = ? WHERE id = ?", [retry, period.id])
    }

    func retryFailed() throws {
        try execute("UPDATE reports SET state = 'pending', next_attempt = 0 WHERE state = 'failed' AND id NOT LIKE 'manual:%'")
    }

    func remove(_ event: JournalEvent) throws {
        try transaction {
            let last = try query("SELECT MAX(end) FROM events WHERE id = ? OR session = ?",
                                 [event.id, event.id], row: { Self.date($0, 0) }).first ?? event.end
            try execute("DELETE FROM events WHERE id = ?", [event.id])
            try execute("""
                UPDATE reports SET state = 'pending', content = NULL, next_attempt = 0
                WHERE start <= ? AND end > ?
                """, [last, event.start])
            try execute("""
                DELETE FROM reports WHERE NOT EXISTS (
                    SELECT 1 FROM events e WHERE e.start < reports.end
                    AND (e.start >= reports.start OR e.end > reports.start)
                )
                """)
        }
    }

    func removeAll() throws {
        try transaction { try script("DELETE FROM events; DELETE FROM reports; DELETE FROM metadata;") }
    }

    private func transaction(_ operation: () throws -> Void) throws {
        try script("BEGIN IMMEDIATE")
        do {
            try operation()
            try script("COMMIT")
        } catch {
            try? script("ROLLBACK")
            throw error
        }
    }

    private func script(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw DatabaseError() }
    }

    private func execute(_ sql: String, _ values: [Any?] = []) throws {
        _ = try query(sql, values) { _ in true }
    }

    private func query<T>(_ sql: String, _ values: [Any?] = [], row: (OpaquePointer) -> T?) throws -> [T] {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared else {
            throw DatabaseError()
        }
        defer { sqlite3_finalize(statement) }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            let result: Int32
            switch value {
            case let value as String:
                result = value.withCString { sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), Self.transient) }
            case let value as Date: result = sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
            case let value as Int: result = sqlite3_bind_int64(statement, index, Int64(value))
            case nil: result = sqlite3_bind_null(statement, index)
            default: throw DatabaseError()
            }
            guard result == SQLITE_OK else { throw DatabaseError() }
        }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: if let value = row(statement) { rows.append(value) }
            case SQLITE_DONE: return rows
            default: throw DatabaseError()
            }
        }
    }

    private static func text(_ row: OpaquePointer, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(row, index) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: raw, count: Int(sqlite3_column_bytes(row, index))), as: UTF8.self)
    }

    private static func date(_ row: OpaquePointer, _ index: Int32) -> Date {
        Date(timeIntervalSince1970: sqlite3_column_double(row, index))
    }

    private static func event(_ row: OpaquePointer) -> JournalEvent? {
        guard let id = text(row, 0), let kind = text(row, 1).flatMap(EventKind.init) else { return nil }
        return JournalEvent(id: id, kind: kind, start: date(row, 2), end: date(row, 3),
                            bundleID: text(row, 4) ?? "", appName: text(row, 5) ?? "",
                            window: text(row, 6) ?? "", body: text(row, 7) ?? "", sessionID: text(row, 8))
    }

    private static func report(_ row: OpaquePointer) -> StoredReport? {
        guard let kind = text(row, 1).flatMap(ReportKind.init),
              let state = text(row, 4).flatMap(ReportState.init) else { return nil }
        let content = text(row, 6).flatMap { try? JSONDecoder().decode(ReportContent.self, from: Data($0.utf8)) }
        return StoredReport(period: .init(kind: kind, start: date(row, 2), end: date(row, 3),
                                          isManual: text(row, 0)?.hasPrefix("manual:") == true),
                            state: state, content: content, nextAttempt: date(row, 5))
    }
}
