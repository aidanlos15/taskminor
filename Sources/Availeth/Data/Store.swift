import Foundation
import SQLite3

/// Local SQLite store for activity spans (protected at rest by FileVault when
/// the user has it enabled). All access is serialized on an internal queue;
/// public methods are synchronous and safe to call from any thread.
final class Store {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.availeth.store")
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    let url: URL

    init(url: URL) {
        self.url = url
        queue.sync { open() }
    }

    /// Default on-disk location: ~/Library/Application Support/Availeth/availeth.sqlite
    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Availeth", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("availeth.sqlite")
    }

    /// In-memory store for tests.
    static func inMemory() -> Store {
        Store(url: URL(fileURLWithPath: ":memory:"))
    }

    private func open() {
        let path = url.path == "/:memory:" || url.path.hasSuffix(":memory:") ? ":memory:" : url.path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            fatalError("Unable to open Availeth database at \(path)")
        }
        exec("PRAGMA journal_mode=WAL;")
        // Zero freed pages so deleted activity is not recoverable from the file.
        exec("PRAGMA secure_delete=ON;")
        exec("""
            CREATE TABLE IF NOT EXISTS spans (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                bundle_id TEXT NOT NULL,
                app_name TEXT NOT NULL,
                window_title TEXT NOT NULL DEFAULT '',
                start REAL NOT NULL,
                end REAL NOT NULL,
                is_demo INTEGER NOT NULL DEFAULT 0
            );
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_spans_start ON spans(start);")
        exec("CREATE INDEX IF NOT EXISTS idx_spans_demo ON spans(is_demo);")

        // Enrichment columns, added in place for existing databases.
        addColumnIfMissing(table: "spans", column: "keystrokes", decl: "INTEGER NOT NULL DEFAULT 0")
        addColumnIfMissing(table: "spans", column: "clicks", decl: "INTEGER NOT NULL DEFAULT 0")
        addColumnIfMissing(table: "spans", column: "doc_path", decl: "TEXT NOT NULL DEFAULT ''")
        addColumnIfMissing(table: "spans", column: "shortcuts", decl: "TEXT NOT NULL DEFAULT ''")
        addColumnIfMissing(table: "spans", column: "fields", decl: "TEXT NOT NULL DEFAULT ''")

        // Cross-context copy-and-paste movements. Structure only, never content.
        exec("""
            CREATE TABLE IF NOT EXISTS transfers (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                at REAL NOT NULL,
                from_bundle TEXT NOT NULL,
                from_app TEXT NOT NULL,
                from_unit TEXT NOT NULL,
                from_title TEXT NOT NULL DEFAULT '',
                to_bundle TEXT NOT NULL,
                to_app TEXT NOT NULL,
                to_unit TEXT NOT NULL,
                to_title TEXT NOT NULL DEFAULT '',
                to_field TEXT NOT NULL DEFAULT '',
                gap REAL NOT NULL DEFAULT 0,
                is_demo INTEGER NOT NULL DEFAULT 0
            );
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_transfers_at ON transfers(at);")

        exec("""
            CREATE TABLE IF NOT EXISTS screenshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                app_name TEXT NOT NULL,
                window_title TEXT NOT NULL DEFAULT '',
                path TEXT NOT NULL,
                is_demo INTEGER NOT NULL DEFAULT 0
            );
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_shots_ts ON screenshots(ts);")

        exec("""
            CREATE TABLE IF NOT EXISTS narratives (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                app_name TEXT NOT NULL,
                window_title TEXT NOT NULL DEFAULT '',
                text TEXT NOT NULL,
                is_demo INTEGER NOT NULL DEFAULT 0
            );
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_narr_ts ON narratives(ts);")
        addColumnIfMissing(table: "narratives", column: "image_path", decl: "TEXT NOT NULL DEFAULT ''")
        addColumnIfMissing(table: "narratives", column: "trigger", decl: "TEXT NOT NULL DEFAULT ''")

        exec("""
            CREATE TABLE IF NOT EXISTS minute_summaries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                minute_start REAL NOT NULL,
                text TEXT NOT NULL,
                apps TEXT NOT NULL DEFAULT '',
                keystrokes INTEGER NOT NULL DEFAULT 0,
                clicks INTEGER NOT NULL DEFAULT 0,
                shortcuts TEXT NOT NULL DEFAULT '',
                fields TEXT NOT NULL DEFAULT '',
                source_count INTEGER NOT NULL DEFAULT 0,
                task_id INTEGER NOT NULL DEFAULT 0,
                is_demo INTEGER NOT NULL DEFAULT 0
            );
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_min_start ON minute_summaries(minute_start);")
        // Dedup any pre-existing duplicates, then enforce one summary per minute
        // so re-processing (e.g. after a crash) can never insert a duplicate.
        exec("DELETE FROM minute_summaries WHERE id NOT IN (SELECT MIN(id) FROM minute_summaries GROUP BY minute_start, is_demo);")
        exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_min_unique ON minute_summaries(minute_start, is_demo);")

        exec("""
            CREATE TABLE IF NOT EXISTS task_summaries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                start REAL NOT NULL,
                end REAL NOT NULL,
                title TEXT NOT NULL,
                text TEXT NOT NULL,
                apps TEXT NOT NULL DEFAULT '',
                minute_count INTEGER NOT NULL DEFAULT 0,
                automatable TEXT NOT NULL DEFAULT '',
                is_demo INTEGER NOT NULL DEFAULT 0
            );
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_task_start ON task_summaries(start);")

        exec("""
            CREATE TABLE IF NOT EXISTS idle_sessions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                start REAL NOT NULL,
                end REAL NOT NULL,
                is_demo INTEGER NOT NULL DEFAULT 0
            );
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_idle_start ON idle_sessions(start);")
    }

    /// SQLite has no ADD COLUMN IF NOT EXISTS; check the schema first.
    private func addColumnIfMissing(table: String, column: String, decl: String) {
        var stmt: OpaquePointer?
        var present = false
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 1), String(cString: c) == column {
                    present = true
                    break
                }
            }
        }
        sqlite3_finalize(stmt)
        if !present {
            exec("ALTER TABLE \(table) ADD COLUMN \(column) \(decl);")
        }
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            NSLog("Availeth store error: \(msg)")
        }
    }

    // MARK: - Writes

    @discardableResult
    func insert(_ span: ActivitySpan) -> Int64 {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO spans (bundle_id, app_name, window_title, start, end, is_demo, keystrokes, clicks, doc_path, shortcuts, fields) VALUES (?,?,?,?,?,?,?,?,?,?,?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            bindSpan(span, to: stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func insertBatch(_ spans: [ActivitySpan]) {
        queue.sync {
            exec("BEGIN TRANSACTION;")
            var stmt: OpaquePointer?
            let sql = "INSERT INTO spans (bundle_id, app_name, window_title, start, end, is_demo, keystrokes, clicks, doc_path, shortcuts, fields) VALUES (?,?,?,?,?,?,?,?,?,?,?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                exec("ROLLBACK;")
                return
            }
            for span in spans {
                bindSpan(span, to: stmt)
                sqlite3_step(stmt)
                sqlite3_reset(stmt)
            }
            sqlite3_finalize(stmt)
            exec("COMMIT;")
        }
    }

    private func bindSpan(_ span: ActivitySpan, to stmt: OpaquePointer?) {
        sqlite3_bind_text(stmt, 1, span.bundleID, -1, Store.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, span.appName, -1, Store.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, span.windowTitle, -1, Store.SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 4, span.start.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 5, span.end.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 6, span.isDemo ? 1 : 0)
        sqlite3_bind_int(stmt, 7, Int32(span.keystrokes))
        sqlite3_bind_int(stmt, 8, Int32(span.clicks))
        sqlite3_bind_text(stmt, 9, span.documentPath, -1, Store.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 10, span.shortcuts, -1, Store.SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 11, span.fields, -1, Store.SQLITE_TRANSIENT)
    }

    func deleteAll(demoOnly: Bool = false) {
        queue.sync {
            exec(demoOnly ? "DELETE FROM spans WHERE is_demo = 1;" : "DELETE FROM spans;")
            exec(demoOnly ? "DELETE FROM transfers WHERE is_demo = 1;" : "DELETE FROM transfers;")
            purgeDeletedBytes()
        }
    }

    func deleteLiveData() {
        queue.sync {
            exec("DELETE FROM spans WHERE is_demo = 0;")
            exec("DELETE FROM transfers WHERE is_demo = 0;")
            purgeDeletedBytes()
        }
    }

    // MARK: - Transfers

    @discardableResult
    func insert(transfer t: Transfer) -> Int64 {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO transfers (at, from_bundle, from_app, from_unit, from_title, to_bundle, to_app, to_unit, to_title, to_field, gap, is_demo) VALUES (?,?,?,?,?,?,?,?,?,?,?,?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, t.at.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, t.fromBundleID, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, t.fromApp, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, t.fromUnit, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, t.fromTitle, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, t.toBundleID, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, t.toApp, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 8, t.toUnit, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 9, t.toTitle, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 10, t.toField, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 11, t.gapSeconds)
            sqlite3_bind_int(stmt, 12, t.isDemo ? 1 : 0)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func transfers(from: Date, to: Date, demo: Bool) -> [Transfer] {
        queue.sync {
            var out: [Transfer] = []
            var stmt: OpaquePointer?
            let sql = "SELECT id, at, from_bundle, from_app, from_unit, from_title, to_bundle, to_app, to_unit, to_title, to_field, gap FROM transfers WHERE at >= ? AND at < ? AND is_demo = ? ORDER BY at ASC;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, from.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, to.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, demo ? 1 : 0)
            func str(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(Transfer(
                    id: sqlite3_column_int64(stmt, 0),
                    at: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    fromBundleID: str(2), fromApp: str(3), fromUnit: str(4), fromTitle: str(5),
                    toBundleID: str(6), toApp: str(7), toUnit: str(8), toTitle: str(9), toField: str(10),
                    gapSeconds: sqlite3_column_double(stmt, 11), isDemo: demo
                ))
            }
            return out
        }
    }

    func transferCount(demo: Bool) -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM transfers WHERE is_demo = ?;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, demo ? 1 : 0)
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    /// Makes a delete mean what the UI promises: checkpoint + truncate the WAL
    /// (which otherwise keeps deleted row images readable) and VACUUM so free
    /// pages are rewritten out of the main file.
    private func purgeDeletedBytes() {
        exec("PRAGMA wal_checkpoint(TRUNCATE);")
        exec("VACUUM;")
    }

    // MARK: - Reads

    /// Spans overlapping [from, to), demo or live, ordered by start.
    func spans(from: Date, to: Date, demo: Bool) -> [ActivitySpan] {
        queue.sync {
            var out: [ActivitySpan] = []
            var stmt: OpaquePointer?
            let sql = """
                SELECT id, bundle_id, app_name, window_title, start, end, is_demo, keystrokes, clicks, doc_path, shortcuts, fields
                FROM spans
                WHERE end > ? AND start < ? AND is_demo = ?
                ORDER BY start ASC;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, from.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, to.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, demo ? 1 : 0)
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(ActivitySpan(
                    id: sqlite3_column_int64(stmt, 0),
                    bundleID: String(cString: sqlite3_column_text(stmt, 1)),
                    appName: String(cString: sqlite3_column_text(stmt, 2)),
                    windowTitle: String(cString: sqlite3_column_text(stmt, 3)),
                    start: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                    end: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                    isDemo: sqlite3_column_int(stmt, 6) == 1,
                    keystrokes: Int(sqlite3_column_int(stmt, 7)),
                    clicks: Int(sqlite3_column_int(stmt, 8)),
                    documentPath: sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? "",
                    shortcuts: sqlite3_column_text(stmt, 10).map { String(cString: $0) } ?? "",
                    fields: sqlite3_column_text(stmt, 11).map { String(cString: $0) } ?? ""
                ))
            }
            return out
        }
    }

    func spanCount(demo: Bool) -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM spans WHERE is_demo = ?;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, demo ? 1 : 0)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    // MARK: - Screenshots

    @discardableResult
    func insertScreenshot(_ shot: Screenshot) -> Int64 {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO screenshots (ts, app_name, window_title, path, is_demo) VALUES (?,?,?,?,?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, shot.timestamp.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, shot.appName, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, shot.windowTitle, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, shot.path, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 5, shot.isDemo ? 1 : 0)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func screenshots(from: Date, to: Date, demo: Bool) -> [Screenshot] {
        queue.sync {
            var out: [Screenshot] = []
            var stmt: OpaquePointer?
            let sql = """
                SELECT id, ts, app_name, window_title, path FROM screenshots
                WHERE ts >= ? AND ts < ? AND is_demo = ?
                ORDER BY ts DESC;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, from.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, to.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, demo ? 1 : 0)
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(Screenshot(
                    id: sqlite3_column_int64(stmt, 0),
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    appName: String(cString: sqlite3_column_text(stmt, 2)),
                    windowTitle: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
                    path: String(cString: sqlite3_column_text(stmt, 4))
                ))
            }
            return out
        }
    }

    func screenshotCount(demo: Bool) -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM screenshots WHERE is_demo = ?;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, demo ? 1 : 0)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// Removes screenshot rows older than `cutoff`, returning their file paths
    /// so the caller can delete the thumbnails from disk (retention enforcement).
    @discardableResult
    func pruneScreenshots(olderThan cutoff: Date) -> [String] {
        queue.sync {
            var paths: [String] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT path FROM screenshots WHERE ts < ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    paths.append(String(cString: sqlite3_column_text(stmt, 0)))
                }
            }
            sqlite3_finalize(stmt)
            var del: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM screenshots WHERE ts < ?;", -1, &del, nil) == SQLITE_OK {
                sqlite3_bind_double(del, 1, cutoff.timeIntervalSince1970)
                sqlite3_step(del)
            }
            sqlite3_finalize(del)
            return paths
        }
    }

    /// Deletes screenshot rows (default: only live) and returns their file paths
    /// for on-disk removal.
    @discardableResult
    func deleteScreenshots(scope: DeleteScope) -> [String] {
        queue.sync {
            let predicate: String
            switch scope {
            case .live: predicate = "WHERE is_demo = 0"
            case .demo: predicate = "WHERE is_demo = 1"
            case .all: predicate = ""
            }
            var paths: [String] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT path FROM screenshots \(predicate);", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    paths.append(String(cString: sqlite3_column_text(stmt, 0)))
                }
            }
            sqlite3_finalize(stmt)
            exec("DELETE FROM screenshots \(predicate);")
            purgeDeletedBytes()
            return paths
        }
    }

    enum DeleteScope { case live, demo, all }

    // MARK: - Narratives (storyline)

    @discardableResult
    func insertNarrative(_ n: SceneNarrative) -> Int64 {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO narratives (ts, app_name, window_title, text, is_demo, image_path, trigger) VALUES (?,?,?,?,?,?,?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, n.timestamp.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, n.appName, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, n.windowTitle, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, n.text, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 5, n.isDemo ? 1 : 0)
            sqlite3_bind_text(stmt, 6, n.imagePath, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, n.trigger, -1, Store.SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func narratives(from: Date, to: Date, demo: Bool) -> [SceneNarrative] {
        queue.sync {
            var out: [SceneNarrative] = []
            var stmt: OpaquePointer?
            let sql = """
                SELECT id, ts, app_name, window_title, text, image_path, trigger FROM narratives
                WHERE ts >= ? AND ts < ? AND is_demo = ?
                ORDER BY ts DESC;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, from.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, to.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, demo ? 1 : 0)
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(SceneNarrative(
                    id: sqlite3_column_int64(stmt, 0),
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    appName: String(cString: sqlite3_column_text(stmt, 2)),
                    windowTitle: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
                    text: String(cString: sqlite3_column_text(stmt, 4)),
                    imagePath: sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "",
                    trigger: sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                ))
            }
            return out
        }
    }

    func narrativeCount(demo: Bool) -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM narratives WHERE is_demo = ?;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, demo ? 1 : 0)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// Deletes narrative rows and returns their image paths for on-disk removal.
    @discardableResult
    func deleteNarratives(scope: DeleteScope) -> [String] {
        queue.sync {
            let predicate: String
            switch scope {
            case .live: predicate = "WHERE is_demo = 0"
            case .demo: predicate = "WHERE is_demo = 1"
            case .all: predicate = ""
            }
            var paths: [String] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT image_path FROM narratives \(predicate);", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(stmt, 0) { paths.append(String(cString: c)) }
                }
            }
            sqlite3_finalize(stmt)
            exec("DELETE FROM narratives \(predicate);")
            purgeDeletedBytes()
            return paths.filter { !$0.isEmpty }
        }
    }

    /// Removes narratives older than `cutoff`, returning image paths to delete.
    @discardableResult
    func pruneNarratives(olderThan cutoff: Date) -> [String] {
        queue.sync {
            var paths: [String] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT image_path FROM narratives WHERE ts < ? AND is_demo = 0;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(stmt, 0) { paths.append(String(cString: c)) }
                }
            }
            sqlite3_finalize(stmt)
            var del: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM narratives WHERE ts < ? AND is_demo = 0;", -1, &del, nil) == SQLITE_OK {
                sqlite3_bind_double(del, 1, cutoff.timeIntervalSince1970)
                sqlite3_step(del)
            }
            sqlite3_finalize(del)
            return paths.filter { !$0.isEmpty }
        }
    }

    // MARK: - Minute summaries

    @discardableResult
    func insertMinuteSummary(_ m: MinuteSummary) -> Int64 {
        queue.sync {
            var stmt: OpaquePointer?
            // OR IGNORE: the UNIQUE(minute_start, is_demo) index makes re-inserting
            // an already-summarized minute a no-op rather than a duplicate row.
            let sql = "INSERT OR IGNORE INTO minute_summaries (minute_start, text, apps, keystrokes, clicks, shortcuts, fields, source_count, task_id, is_demo) VALUES (?,?,?,?,?,?,?,?,?,?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, m.minuteStart.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, m.text, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, m.apps, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 4, Int32(m.keystrokes))
            sqlite3_bind_int(stmt, 5, Int32(m.clicks))
            sqlite3_bind_text(stmt, 6, m.shortcuts, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 7, m.fields, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 8, Int32(m.sourceCount))
            sqlite3_bind_int64(stmt, 9, m.taskID)
            sqlite3_bind_int(stmt, 10, m.isDemo ? 1 : 0)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func minuteSummaries(from: Date, to: Date, demo: Bool) -> [MinuteSummary] {
        queue.sync { fetchMinutes("minute_start >= ? AND minute_start < ? AND is_demo = ?", [from.timeIntervalSince1970, to.timeIntervalSince1970, demo ? 1 : 0]) }
    }

    /// Ungrouped minute summaries (task_id = 0), oldest first.
    func ungroupedMinuteSummaries(demo: Bool) -> [MinuteSummary] {
        queue.sync { fetchMinutes("task_id = 0 AND is_demo = ?", [demo ? 1 : 0], order: "ASC") }
    }

    func minutesForTask(_ taskID: Int64) -> [MinuteSummary] {
        queue.sync { fetchMinutes("task_id = ?", [Double(taskID)], order: "ASC") }
    }

    /// The most recent summarized minute — the durable resume point for the
    /// synthesizer (source of truth, not a separate watermark that can rewind).
    func latestMinuteStart(demo: Bool) -> Date? {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT MAX(minute_start) FROM minute_summaries WHERE is_demo = ?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, demo ? 1 : 0)
            guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
        }
    }

    /// Inserts a task and links its minutes atomically, so a crash can't leave a
    /// task with unlinked minutes (which would be re-grouped into a duplicate).
    @discardableResult
    func insertTaskAndLink(_ t: TaskSummary, minuteIDs: [Int64]) -> Int64 {
        queue.sync {
            exec("BEGIN TRANSACTION;")
            var stmt: OpaquePointer?
            let sql = "INSERT INTO task_summaries (start, end, title, text, apps, minute_count, automatable, is_demo) VALUES (?,?,?,?,?,?,?,?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { exec("ROLLBACK;"); return 0 }
            sqlite3_bind_double(stmt, 1, t.start.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, t.end.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, t.title, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, t.text, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, t.apps, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 6, Int32(t.minuteCount))
            sqlite3_bind_text(stmt, 7, t.automatable, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 8, t.isDemo ? 1 : 0)
            guard sqlite3_step(stmt) == SQLITE_DONE else { sqlite3_finalize(stmt); exec("ROLLBACK;"); return 0 }
            sqlite3_finalize(stmt)
            let taskID = sqlite3_last_insert_rowid(db)

            var upd: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE minute_summaries SET task_id = ? WHERE id = ?;", -1, &upd, nil) == SQLITE_OK {
                for id in minuteIDs {
                    sqlite3_bind_int64(upd, 1, taskID)
                    sqlite3_bind_int64(upd, 2, id)
                    sqlite3_step(upd)
                    sqlite3_reset(upd)
                }
            }
            sqlite3_finalize(upd)
            exec("COMMIT;")
            return taskID
        }
    }

    /// Marks minutes as settled without a task (e.g. away or trivial noise), so
    /// they stop being re-fetched as ungrouped.
    func settleMinutes(_ ids: [Int64]) { setMinuteTask(minuteIDs: ids, taskID: -1) }

    private func fetchMinutes(_ whereClause: String, _ binds: [Double], order: String = "DESC") -> [MinuteSummary] {
        var out: [MinuteSummary] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id, minute_start, text, apps, keystrokes, clicks, shortcuts, fields, source_count, task_id, is_demo FROM minute_summaries WHERE \(whereClause) ORDER BY minute_start \(order);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        for (i, b) in binds.enumerated() {
            if b == b.rounded() && abs(b) < 1e9 { sqlite3_bind_int64(stmt, Int32(i + 1), Int64(b)) }
            else { sqlite3_bind_double(stmt, Int32(i + 1), b) }
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(MinuteSummary(
                id: sqlite3_column_int64(stmt, 0),
                minuteStart: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                text: String(cString: sqlite3_column_text(stmt, 2)),
                apps: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
                keystrokes: Int(sqlite3_column_int(stmt, 4)),
                clicks: Int(sqlite3_column_int(stmt, 5)),
                shortcuts: sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "",
                fields: sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "",
                sourceCount: Int(sqlite3_column_int(stmt, 8)),
                taskID: sqlite3_column_int64(stmt, 9),
                isDemo: sqlite3_column_int(stmt, 10) == 1
            ))
        }
        return out
    }

    func setMinuteTask(minuteIDs: [Int64], taskID: Int64) {
        guard !minuteIDs.isEmpty else { return }
        queue.sync {
            exec("BEGIN TRANSACTION;")
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE minute_summaries SET task_id = ? WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK {
                for id in minuteIDs {
                    sqlite3_bind_int64(stmt, 1, taskID)
                    sqlite3_bind_int64(stmt, 2, id)
                    sqlite3_step(stmt)
                    sqlite3_reset(stmt)
                }
            }
            sqlite3_finalize(stmt)
            exec("COMMIT;")
        }
    }

    // MARK: - Task summaries

    @discardableResult
    func insertTaskSummary(_ t: TaskSummary) -> Int64 {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO task_summaries (start, end, title, text, apps, minute_count, automatable, is_demo) VALUES (?,?,?,?,?,?,?,?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, t.start.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, t.end.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, t.title, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, t.text, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, t.apps, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 6, Int32(t.minuteCount))
            sqlite3_bind_text(stmt, 7, t.automatable, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 8, t.isDemo ? 1 : 0)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func taskSummaries(from: Date, to: Date, demo: Bool) -> [TaskSummary] {
        queue.sync {
            var out: [TaskSummary] = []
            var stmt: OpaquePointer?
            let sql = "SELECT id, start, end, title, text, apps, minute_count, automatable FROM task_summaries WHERE start >= ? AND start < ? AND is_demo = ? ORDER BY start DESC;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, from.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, to.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, demo ? 1 : 0)
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(TaskSummary(
                    id: sqlite3_column_int64(stmt, 0),
                    start: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    end: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    title: String(cString: sqlite3_column_text(stmt, 3)),
                    text: String(cString: sqlite3_column_text(stmt, 4)),
                    apps: sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "",
                    minuteCount: Int(sqlite3_column_int(stmt, 6)),
                    automatable: sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
                ))
            }
            return out
        }
    }

    func deleteSummaries(scope: DeleteScope) {
        queue.sync {
            let predicate: String
            switch scope {
            case .live: predicate = "WHERE is_demo = 0"
            case .demo: predicate = "WHERE is_demo = 1"
            case .all: predicate = ""
            }
            exec("DELETE FROM minute_summaries \(predicate);")
            exec("DELETE FROM task_summaries \(predicate);")
            purgeDeletedBytes()
        }
    }

    // MARK: - Idle sessions

    @discardableResult
    func insertIdleSession(_ s: IdleSession) -> Int64 {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO idle_sessions (start, end, is_demo) VALUES (?,?,?);", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, s.start.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, s.end.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, s.isDemo ? 1 : 0)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
            return sqlite3_last_insert_rowid(db)
        }
    }

    func idleSessions(from: Date, to: Date, demo: Bool) -> [IdleSession] {
        queue.sync {
            var out: [IdleSession] = []
            var stmt: OpaquePointer?
            let sql = "SELECT id, start, end FROM idle_sessions WHERE end > ? AND start < ? AND is_demo = ? ORDER BY start DESC;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, from.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, to.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, demo ? 1 : 0)
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(IdleSession(
                    id: sqlite3_column_int64(stmt, 0),
                    start: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    end: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
                ))
            }
            return out
        }
    }

    /// Total idle seconds overlapping [from, to).
    func idleSeconds(from: Date, to: Date, demo: Bool) -> TimeInterval {
        idleSessions(from: from, to: to, demo: demo).reduce(0) { acc, s in
            acc + max(0, min(s.end, to).timeIntervalSince(max(s.start, from)))
        }
    }

    func deleteIdleSessions(scope: DeleteScope) {
        queue.sync {
            switch scope {
            case .live: exec("DELETE FROM idle_sessions WHERE is_demo = 0;")
            case .demo: exec("DELETE FROM idle_sessions WHERE is_demo = 1;")
            case .all: exec("DELETE FROM idle_sessions;")
            }
            purgeDeletedBytes()
        }
    }

    deinit {
        sqlite3_close(db)
    }
}
