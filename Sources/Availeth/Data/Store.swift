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
        addColumnIfMissing(table: "spans", column: "page_host", decl: "TEXT NOT NULL DEFAULT ''")

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

        // Intent labels: one row per span, written by the labeler once a
        // session has closed. No foreign key (codebase convention); orphans are
        // swept when spans are deleted.
        exec("""
            CREATE TABLE IF NOT EXISTS span_labels (
                span_id INTEGER PRIMARY KEY,
                session_key TEXT NOT NULL,
                unit TEXT NOT NULL,
                title_key TEXT NOT NULL DEFAULT '',
                intent TEXT NOT NULL,
                canon TEXT NOT NULL,
                source INTEGER NOT NULL DEFAULT 0,
                model TEXT NOT NULL DEFAULT '',
                created REAL NOT NULL,
                is_demo INTEGER NOT NULL DEFAULT 0
            );
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_labels_unit ON span_labels(is_demo, unit);")

        // Site icons found in the browser's own favicon cache. Demo and live
        // share hosts, so no is_demo.
        exec("""
            CREATE TABLE IF NOT EXISTS site_icons (
                host TEXT PRIMARY KEY,
                domain TEXT NOT NULL,
                path TEXT NOT NULL DEFAULT '',
                source TEXT NOT NULL DEFAULT '',
                width INTEGER NOT NULL DEFAULT 0,
                fetched REAL NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0
            );
            """)
        exec("CREATE INDEX IF NOT EXISTS idx_site_icons_domain ON site_icons(domain);")
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
            let sql = "INSERT INTO spans (bundle_id, app_name, window_title, start, end, is_demo, keystrokes, clicks, doc_path, shortcuts, fields, page_host) VALUES (?,?,?,?,?,?,?,?,?,?,?,?);"
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
            let sql = "INSERT INTO spans (bundle_id, app_name, window_title, start, end, is_demo, keystrokes, clicks, doc_path, shortcuts, fields, page_host) VALUES (?,?,?,?,?,?,?,?,?,?,?,?);"
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
        sqlite3_bind_text(stmt, 12, span.pageHost, -1, Store.SQLITE_TRANSIENT)
    }

    /// The column list every span reader selects, in `spanRow` order.
    /// Table-qualified, so the list is safe inside joins (span_labels has is_demo too).
    private static let spanColumns = "spans.id, spans.bundle_id, spans.app_name, spans.window_title, spans.start, spans.end, spans.is_demo, spans.keystrokes, spans.clicks, spans.doc_path, spans.shortcuts, spans.fields, spans.page_host"

    private func spanRow(_ stmt: OpaquePointer?) -> ActivitySpan {
        ActivitySpan(
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
            fields: sqlite3_column_text(stmt, 11).map { String(cString: $0) } ?? "",
            pageHost: sqlite3_column_text(stmt, 12).map { String(cString: $0) } ?? ""
        )
    }

    func deleteAll(demoOnly: Bool = false) {
        queue.sync {
            exec(demoOnly ? "DELETE FROM spans WHERE is_demo = 1;" : "DELETE FROM spans;")
            exec("DELETE FROM span_labels WHERE span_id NOT IN (SELECT id FROM spans);")
            purgeDeletedBytes()
        }
    }

    func deleteLiveData() {
        queue.sync {
            exec("DELETE FROM spans WHERE is_demo = 0;")
            exec("DELETE FROM span_labels WHERE span_id NOT IN (SELECT id FROM spans);")
            purgeDeletedBytes()
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
            let sql = "SELECT \(Store.spanColumns) FROM spans WHERE end > ? AND start < ? AND is_demo = ? ORDER BY start ASC;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, from.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, to.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, demo ? 1 : 0)
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(spanRow(stmt)) }
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

    /// Drops the IMAGES of narratives older than `cutoff` — the text stays, the
    /// frame goes — returning the file paths to delete.
    @discardableResult
    func pruneNarrativeImages(olderThan cutoff: Date) -> [String] {
        queue.sync {
            var paths: [String] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT image_path FROM narratives WHERE ts < ? AND is_demo = 0 AND image_path <> '';", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, cutoff.timeIntervalSince1970)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(stmt, 0) { paths.append(String(cString: c)) }
                }
            }
            sqlite3_finalize(stmt)
            var upd: OpaquePointer?
            if sqlite3_prepare_v2(db, "UPDATE narratives SET image_path = '' WHERE ts < ? AND is_demo = 0 AND image_path <> '';", -1, &upd, nil) == SQLITE_OK {
                sqlite3_bind_double(upd, 1, cutoff.timeIntervalSince1970)
                sqlite3_step(upd)
            }
            sqlite3_finalize(upd)
            return paths
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

    // MARK: - Span labels (intent titles)

    /// Writes (or replaces) one label row per span, atomically.
    func insertSpanLabels(_ labels: [SpanLabel]) {
        guard !labels.isEmpty else { return }
        queue.sync {
            exec("BEGIN TRANSACTION;")
            var stmt: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO span_labels (span_id, session_key, unit, title_key, intent, canon, source, model, created, is_demo) VALUES (?,?,?,?,?,?,?,?,?,?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { exec("ROLLBACK;"); return }
            for l in labels {
                sqlite3_bind_int64(stmt, 1, l.spanID)
                sqlite3_bind_text(stmt, 2, l.sessionKey, -1, Store.SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, l.unit, -1, Store.SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, l.titleKey, -1, Store.SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, l.intent, -1, Store.SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 6, l.canon, -1, Store.SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 7, Int32(l.source.rawValue))
                sqlite3_bind_text(stmt, 8, l.model, -1, Store.SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 9, l.created.timeIntervalSince1970)
                sqlite3_bind_int(stmt, 10, l.isDemo ? 1 : 0)
                sqlite3_step(stmt)
                sqlite3_reset(stmt)
            }
            sqlite3_finalize(stmt)
            exec("COMMIT;")
        }
    }

    private static let labelColumns = "l.span_id, l.session_key, l.unit, l.title_key, l.intent, l.canon, l.source, l.model, l.created, l.is_demo"

    private func labelRow(_ stmt: OpaquePointer?) -> SpanLabel {
        SpanLabel(
            spanID: sqlite3_column_int64(stmt, 0),
            sessionKey: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
            unit: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
            titleKey: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
            intent: sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "",
            canon: sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "",
            source: LabelSource(rawValue: Int(sqlite3_column_int(stmt, 6))) ?? .fallback,
            model: sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "",
            created: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
            isDemo: sqlite3_column_int(stmt, 9) == 1
        )
    }

    /// Labels of the spans overlapping [from, to), keyed by span id.
    func spanLabels(from: Date, to: Date, demo: Bool) -> [Int64: SpanLabel] {
        queue.sync {
            var out: [Int64: SpanLabel] = [:]
            var stmt: OpaquePointer?
            let sql = "SELECT \(Store.labelColumns) FROM span_labels l JOIN spans s ON s.id = l.span_id WHERE s.end > ? AND s.start < ? AND l.is_demo = ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, from.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, to.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, demo ? 1 : 0)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let l = labelRow(stmt)
                out[l.spanID] = l
            }
            return out
        }
    }

    /// Spans with no label yet that ended in [from, before) — `before` is the
    /// grace cut-off, so a session that may still grow isn't named early.
    /// Newest first, so what the user is looking at is labelled first.
    func unlabelledSpans(from: Date, before: Date, demo: Bool, limit: Int) -> [ActivitySpan] {
        queue.sync {
            var out: [ActivitySpan] = []
            var stmt: OpaquePointer?
            let sql = """
                SELECT \(Store.spanColumns) FROM spans
                LEFT JOIN span_labels l ON l.span_id = spans.id
                WHERE l.span_id IS NULL AND spans.end > ? AND spans.end < ? AND spans.is_demo = ?
                ORDER BY spans.start DESC LIMIT ?;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, from.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, before.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, demo ? 1 : 0)
            sqlite3_bind_int(stmt, 4, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(spanRow(stmt)) }
            return out
        }
    }

    /// Distinct model-made task titles for a unit, most recently used first —
    /// the "existing tasks" a new session may be matched to.
    func canonTitles(unit: String, demo: Bool, limit: Int) -> [String] {
        queue.sync {
            var out: [String] = []
            var stmt: OpaquePointer?
            let sql = "SELECT canon, MAX(created) AS latest FROM span_labels WHERE unit = ? AND is_demo = ? AND source = ? GROUP BY canon ORDER BY latest DESC LIMIT ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, unit, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, demo ? 1 : 0)
            sqlite3_bind_int(stmt, 3, Int32(LabelSource.model.rawValue))
            sqlite3_bind_int(stmt, 4, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
            }
            return out
        }
    }

    /// The label of a labelled span of `unit` with the same title key that ended
    /// within `gap` before the session started, or started within `gap` after it
    /// ended — the other half of the same sitting, whichever side it fell on.
    /// Nearest first.
    func neighbourLabel(unit: String, titleKey: String, sessionStart: Date, sessionEnd: Date, gap: TimeInterval, demo: Bool) -> SpanLabel? {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = """
                SELECT \(Store.labelColumns) FROM span_labels l JOIN spans s ON s.id = l.span_id
                WHERE l.unit = ? AND l.title_key = ? AND l.is_demo = ?
                  AND ((s.end >= ? AND s.end <= ?) OR (s.start >= ? AND s.start <= ?))
                ORDER BY MIN(ABS(s.end - ?), ABS(s.start - ?)) ASC LIMIT 1;
                """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            let start = sessionStart.timeIntervalSince1970, end = sessionEnd.timeIntervalSince1970
            sqlite3_bind_text(stmt, 1, unit, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, titleKey, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, demo ? 1 : 0)
            sqlite3_bind_double(stmt, 4, start - gap)
            sqlite3_bind_double(stmt, 5, start + 1)
            sqlite3_bind_double(stmt, 6, end - 1)
            sqlite3_bind_double(stmt, 7, end + gap)
            sqlite3_bind_double(stmt, 8, start)
            sqlite3_bind_double(stmt, 9, end)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return labelRow(stmt)
        }
    }

    /// Renames every span of a sitting — used when a later half of the sitting
    /// brought the evidence that names it.
    func relabelSession(sessionKey: String, intent: String, canon: String, source: LabelSource, model: String) {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE span_labels SET intent = ?, canon = ?, source = ?, model = ? WHERE session_key = ?;", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, intent, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, canon, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, Int32(source.rawValue))
            sqlite3_bind_text(stmt, 4, model, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, sessionKey, -1, Store.SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
    }

    func spanLabelCount(demo: Bool) -> Int {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM span_labels WHERE is_demo = ?;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, demo ? 1 : 0)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// Highest span id — a cheap "anything new since last time?" check.
    func maxSpanID(demo: Bool) -> Int64 {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(id), 0) FROM spans WHERE is_demo = ?;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, demo ? 1 : 0)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    func deleteSpanLabels(scope: DeleteScope) {
        queue.sync {
            switch scope {
            case .live: exec("DELETE FROM span_labels WHERE is_demo = 0;")
            case .demo: exec("DELETE FROM span_labels WHERE is_demo = 1;")
            case .all: exec("DELETE FROM span_labels;")
            }
            purgeDeletedBytes()
        }
    }

    // MARK: - Site icons

    func upsertSiteIcon(_ icon: SiteIcon) {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "INSERT OR REPLACE INTO site_icons (host, domain, path, source, width, fetched, attempts) VALUES (?,?,?,?,?,?,?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, icon.host, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, icon.domain, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, icon.path, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, icon.source, -1, Store.SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 5, Int32(icon.width))
            sqlite3_bind_double(stmt, 6, icon.fetched.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 7, Int32(icon.attempts))
            sqlite3_step(stmt)
        }
    }

    private func siteIconRow(_ stmt: OpaquePointer?) -> SiteIcon {
        SiteIcon(
            host: String(cString: sqlite3_column_text(stmt, 0)),
            domain: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
            path: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
            source: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
            width: Int(sqlite3_column_int(stmt, 4)),
            fetched: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
            attempts: Int(sqlite3_column_int(stmt, 6))
        )
    }

    func siteIcon(host: String) -> SiteIcon? {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT host, domain, path, source, width, fetched, attempts FROM site_icons WHERE host = ?;", -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, host, -1, Store.SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return siteIconRow(stmt)
        }
    }

    /// The best icon on file for a domain (widest, non-empty), if any.
    func siteIcon(domain: String) -> SiteIcon? {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT host, domain, path, source, width, fetched, attempts FROM site_icons WHERE domain = ? AND path <> '' ORDER BY width DESC LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, domain, -1, Store.SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return siteIconRow(stmt)
        }
    }

    func siteIcons() -> [SiteIcon] {
        queue.sync {
            var out: [SiteIcon] = []
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT host, domain, path, source, width, fetched, attempts FROM site_icons;", -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW { out.append(siteIconRow(stmt)) }
            return out
        }
    }

    /// Removes every site icon row, returning the files to delete.
    @discardableResult
    func deleteSiteIcons() -> [String] {
        queue.sync {
            var paths: [String] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT path FROM site_icons WHERE path <> '';", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(stmt, 0) { paths.append(String(cString: c)) }
                }
            }
            sqlite3_finalize(stmt)
            exec("DELETE FROM site_icons;")
            purgeDeletedBytes()
            return paths
        }
    }

    // MARK: - Cleanup of system-process rows

    private static func placeholders(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }

    /// Deletes live spans recorded for the given bundle ids (system agents that
    /// slipped in before they were filtered), and the labels that hung off them.
    @discardableResult
    func deleteSpans(bundleIDs: Set<String>) -> Int {
        guard !bundleIDs.isEmpty else { return 0 }
        return queue.sync {
            let ids = bundleIDs.sorted()
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM spans WHERE is_demo = 0 AND bundle_id IN (\(Store.placeholders(ids.count)));", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            for (i, b) in ids.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), b, -1, Store.SQLITE_TRANSIENT) }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            let n = Int(sqlite3_changes(db))
            if n > 0 {
                exec("DELETE FROM span_labels WHERE span_id NOT IN (SELECT id FROM spans);")
                purgeDeletedBytes()
            }
            return n
        }
    }

    /// Deletes live narratives captured under the given app names, returning
    /// their image paths for on-disk removal.
    @discardableResult
    func deleteNarratives(appNames: Set<String>) -> [String] {
        guard !appNames.isEmpty else { return [] }
        return queue.sync {
            let names = appNames.sorted()
            var paths: [String] = []
            var sel: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT image_path FROM narratives WHERE is_demo = 0 AND app_name IN (\(Store.placeholders(names.count)));", -1, &sel, nil) == SQLITE_OK {
                for (i, n) in names.enumerated() { sqlite3_bind_text(sel, Int32(i + 1), n, -1, Store.SQLITE_TRANSIENT) }
                while sqlite3_step(sel) == SQLITE_ROW {
                    if let c = sqlite3_column_text(sel, 0) { paths.append(String(cString: c)) }
                }
            }
            sqlite3_finalize(sel)
            var del: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM narratives WHERE is_demo = 0 AND app_name IN (\(Store.placeholders(names.count)));", -1, &del, nil) == SQLITE_OK {
                for (i, n) in names.enumerated() { sqlite3_bind_text(del, Int32(i + 1), n, -1, Store.SQLITE_TRANSIENT) }
                sqlite3_step(del)
            }
            sqlite3_finalize(del)
            if !paths.isEmpty || sqlite3_changes(db) > 0 { purgeDeletedBytes() }
            return paths.filter { !$0.isEmpty }
        }
    }

    /// Strips invisible Unicode format marks from stored app names
    /// ("\u{200E}WhatsApp") so old rows group with new ones.
    func normaliseAppNames() {
        queue.sync {
            for table in ["spans", "narratives", "screenshots"] {
                exec("UPDATE \(table) SET app_name = trim(replace(replace(replace(app_name, char(8206), ''), char(8207), ''), char(8203), '')) WHERE app_name LIKE '%' || char(8206) || '%' OR app_name LIKE '%' || char(8207) || '%' OR app_name LIKE '%' || char(8203) || '%';")
            }
        }
    }

    deinit {
        sqlite3_close(db)
    }
}
