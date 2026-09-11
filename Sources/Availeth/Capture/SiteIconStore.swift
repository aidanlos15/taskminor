import AppKit
import CryptoKit
import Foundation
import SQLite3

/// Site icons without the network. The browser has already saved the favicon
/// of every page the user visited, so this reads it from the browser's own
/// cache on this Mac and keeps one file per site under
/// Application Support/Availeth/favicons. Nothing is fetched from the internet.
///
/// Browser caches are exclusively locked while the browser runs, so each read
/// copies the database into a private temp directory, opens the copy, and
/// deletes it afterwards. Safari's cache lives in a TCC-protected folder and is
/// consulted only if it happens to be readable — we never prompt for Full Disk
/// Access. A host with no icon anywhere is recorded as a miss and retried at
/// most once a day; a cache that fails mid-read is simply skipped and tried again.
final class SiteIconStore: @unchecked Sendable {
    static let shared = SiteIconStore()

    /// Fired on the store's own queue when an icon file lands, with its icon key.
    var onIconStored: ((String) -> Void)?
    /// Where browser profiles live; injectable for tests.
    var applicationSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    /// Where Safari's cache lives; injectable for tests.
    var safariDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari", isDirectory: true)
    /// Where icon files are written; defaults beside the database.
    var directory: URL = SiteIconStore.defaultDirectory()
    var negativeRetry: TimeInterval = 24 * 3600
    var coalesceDelay: TimeInterval = 2

    private static let tempPrefix = "availeth-icons-"

    private var store: Store?
    private let queue = DispatchQueue(label: "com.availeth.siteicons", qos: .utility)
    private let lock = NSLock()
    private var pending: [String: URL?] = [:]          // host → page URL (transient, in memory only)
    private var scheduled = false
    private var memory: [String: NSImage?] = [:]       // icon key → image, nil = known missing

    static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Availeth/favicons", isDirectory: true)
    }

    func attach(store: Store) { self.store = store }

    // MARK: - Requests

    /// Asks for the icon of a host seen in a browser tab. Coalesced: bursts of
    /// tab switches cost one round of database copies.
    func request(host: String, pageURL: URL?) {
        lock.lock()
        pending[host] = pageURL
        let kick = !scheduled
        scheduled = true
        lock.unlock()
        if kick { queue.asyncAfter(deadline: .now() + coalesceDelay) { [weak self] in _ = self?.drain() } }
    }

    /// Requests icons for hosts with no usable row — how spans captured while
    /// a cache was locked, or before an icon existed, catch up later. A row
    /// whose file has gone missing counts as missing.
    func requestMissing(hosts: Set<String>) {
        guard let store, !hosts.isEmpty else { return }
        let known = Dictionary(uniqueKeysWithValues: store.siteIcons().map { ($0.host, $0) })
        let now = Date()
        for h in hosts {
            if let row = known[h] {
                if !row.path.isEmpty, FileManager.default.fileExists(atPath: row.path) { continue }
                if row.path.isEmpty, now.timeIntervalSince(row.fetched) < negativeRetry { continue }
                if !row.path.isEmpty { lock.lock(); memory.removeValue(forKey: row.domain); lock.unlock() }
            }
            request(host: h, pageURL: nil)
        }
    }

    /// Runs the pending requests now (tests) and returns the icon keys that got an icon.
    @discardableResult
    func drainNow() -> [String] {
        var stored: [String] = []
        queue.sync { stored = self.drain() }
        return stored
    }

    private func drain() -> [String] {
        lock.lock()
        let batch = pending
        pending.removeAll()
        scheduled = false
        lock.unlock()
        guard let store, !batch.isEmpty else { return [] }

        Self.sweepTemp()
        let now = Date()
        var stored: [String] = []
        var caches: [FaviconCache]?
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(Self.tempPrefix + UUID().uuidString, isDirectory: true)
        defer {
            caches?.forEach { $0.close() }
            try? FileManager.default.removeItem(at: tmp)
        }

        for (host, pageURL) in batch.sorted(by: { $0.key < $1.key }) {
            let key = HostNormalizer.iconKey(host: host)
            let existing = store.siteIcon(host: host)
            if let existing {
                if !existing.path.isEmpty, FileManager.default.fileExists(atPath: existing.path) { continue }
                if existing.path.isEmpty, now.timeIntervalSince(existing.fetched) < negativeRetry { continue }
            }
            // Another host of the same brand already has an icon: share it.
            if let sibling = store.siteIcon(domain: key), FileManager.default.fileExists(atPath: sibling.path) {
                store.upsertSiteIcon(SiteIcon(host: host, domain: key, path: sibling.path, source: sibling.source,
                                              width: sibling.width, fetched: now, attempts: 0))
                continue
            }
            if caches == nil {
                try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                caches = openCaches(tmp: tmp)
            }
            var best: FaviconHit?
            var failed = false
            for cache in caches ?? [] {
                switch cache.lookup(host: host, pageURL: pageURL) {
                case .hit(let hit): if hit.width > (best?.width ?? -1) { best = hit }
                case .miss: break
                case .failed: failed = true
                }
                if let b = best, b.width >= 128 { break }
            }
            if let hit = best, let path = write(hit, key: key) {
                store.upsertSiteIcon(SiteIcon(host: host, domain: key, path: path, source: hit.source, width: hit.width, fetched: now, attempts: 0))
                lock.lock(); memory.removeValue(forKey: key); lock.unlock()
                stored.append(key)
                onIconStored?(key)
            } else if !(caches ?? []).isEmpty, !failed {
                // Every readable cache answered cleanly and none had it: a miss, retried tomorrow.
                store.upsertSiteIcon(SiteIcon(host: host, domain: key, path: "", source: "", width: 0, fetched: now,
                                              attempts: (existing?.attempts ?? 0) + 1))
            }
            // No readable cache, or one failed mid-read (a torn copy): no row, so the next request tries again.
        }
        return stored
    }

    /// Copies left behind by a crash mid-drain hold page URLs — remove them.
    private static func sweepTemp() {
        let dir = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for i in items where i.hasPrefix(tempPrefix) { try? FileManager.default.removeItem(at: dir.appendingPathComponent(i)) }
    }

    // MARK: - Reading

    /// The icon on file for an icon key, decoded once and memoised. Off-main only.
    func cachedImage(domain key: String) -> NSImage? {
        lock.lock()
        if let hit = memory[key] { lock.unlock(); return hit }
        lock.unlock()
        var img: NSImage?
        if let row = store?.siteIcon(domain: key), !row.path.isEmpty {
            img = NSImage(contentsOfFile: row.path)
        }
        lock.lock(); memory[key] = img; lock.unlock()
        return img
    }

    /// Removes every icon file and row (Delete all my captured data). Runs on
    /// the store's queue so an in-flight drain can't re-create anything after it.
    func purgeAll() {
        queue.sync {
            lock.lock()
            pending.removeAll()
            scheduled = false
            memory.removeAll()
            lock.unlock()
            if let store {
                Self.deleteFiles(store.deleteSiteIcons())
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func deleteFiles(_ paths: [String]) {
        for p in paths { try? FileManager.default.removeItem(atPath: p) }
    }

    // MARK: - Writing

    private func write(_ hit: FaviconHit, key: String) -> String? {
        guard hit.data.count <= 512 * 1024, hit.data.count > 16 else { return nil }
        // Sanity: it must decode to a real image at a sensible size.
        guard let img = NSImage(data: hit.data), img.size.width >= 8, img.size.height >= 8 else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = hit.isSVG ? "svg" : (hit.data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "png" : "ico")
        let safe = key.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        let url = directory.appendingPathComponent("\(safe).\(ext)")
        do {
            try hit.data.write(to: url, options: .atomic)
            return url.path
        } catch {
            return nil
        }
    }

    // MARK: - Sources

    /// Every readable browser cache on this Mac, copied into `tmp`.
    private func openCaches(tmp: URL) -> [FaviconCache] {
        var out: [FaviconCache] = []
        // Chromium family: <user data>/<profile>/Favicons.
        for userData in ["Google/Chrome", "Google/Chrome Canary", "Chromium", "BraveSoftware/Brave-Browser",
                         "Microsoft Edge", "Vivaldi", "Arc/User Data"] {
            let dir = applicationSupport.appendingPathComponent(userData, isDirectory: true)
            guard let profiles = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for p in profiles where p == "Default" || p.hasPrefix("Profile ") {
                let db = dir.appendingPathComponent(p).appendingPathComponent("Favicons")
                guard FileManager.default.fileExists(atPath: db.path) else { continue }
                if let c = ChromiumFaviconCache(db: db, tmp: tmp) { out.append(c) }
            }
        }
        // Firefox: <profile>/favicons.sqlite.
        let ffProfiles = applicationSupport.appendingPathComponent("Firefox/Profiles", isDirectory: true)
        if let profiles = try? FileManager.default.contentsOfDirectory(atPath: ffProfiles.path) {
            for p in profiles {
                let db = ffProfiles.appendingPathComponent(p).appendingPathComponent("favicons.sqlite")
                guard FileManager.default.fileExists(atPath: db.path) else { continue }
                if let c = FirefoxFaviconCache(db: db, tmp: tmp) { out.append(c) }
            }
        }
        // Safari: only if the folder is readable (Full Disk Access). Never prompts.
        let safariDB = safariDirectory.appendingPathComponent("Favicon Cache/favicons.db")
        if FileManager.default.isReadableFile(atPath: safariDB.path), let c = SafariFaviconCache(db: safariDB, tmp: tmp) {
            out.append(c)
        }
        return out
    }
}

struct FaviconHit {
    var data: Data
    var width: Int
    var isSVG: Bool
    var source: String
}

/// A cache either has the icon, cleanly doesn't, or couldn't answer (torn copy).
enum FaviconLookup {
    case hit(FaviconHit)
    case miss
    case failed
}

/// One browser cache database, copied and opened privately.
protocol FaviconCache: AnyObject {
    func lookup(host: String, pageURL: URL?) -> FaviconLookup
    func close()
}

/// Minimal SQLite access for a private copy of a browser database.
final class SQLiteCopy {
    enum Row<T> { case value(T), none, error }

    private var db: OpaquePointer?

    /// Copies `source` (and its journal/WAL sidecars) into `tmp` and opens the
    /// copy read-write — it is ours, and a hot journal then rolls back cleanly.
    init?(source: URL, tmp: URL, sidecars: [String]) {
        let dest = tmp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let main = dest.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: main)
            for s in sidecars {
                let side = source.deletingLastPathComponent().appendingPathComponent(source.lastPathComponent + s)
                if FileManager.default.fileExists(atPath: side.path) {
                    try? FileManager.default.copyItem(at: side, to: dest.appendingPathComponent(source.lastPathComponent + s))
                }
            }
            guard sqlite3_open_v2(main.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
                sqlite3_close(db); db = nil; return nil
            }
            sqlite3_busy_timeout(db, 250)
            // A corrupt or truncated copy fails here rather than mid-query.
            guard case .value = firstText("SELECT name FROM sqlite_master LIMIT 1;", binds: []) else {
                sqlite3_close(db); db = nil; return nil
            }
        } catch {
            return nil
        }
    }

    func close() { if db != nil { sqlite3_close(db); db = nil } }
    deinit { close() }

    private func bind(_ stmt: OpaquePointer?, _ binds: [String]) {
        for (i, b) in binds.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), b, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    /// First row of a (BLOB, INTEGER) query.
    func firstBlob(_ sql: String, binds: [String]) -> Row<(Data, Int)> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return .error }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        switch sqlite3_step(stmt) {
        case SQLITE_ROW:
            guard let bytes = sqlite3_column_blob(stmt, 0) else { return .none }
            let n = Int(sqlite3_column_bytes(stmt, 0))
            return n > 0 ? .value((Data(bytes: bytes, count: n), Int(sqlite3_column_int(stmt, 1)))) : .none
        case SQLITE_DONE: return .none
        default: return .error
        }
    }

    func firstText(_ sql: String, binds: [String]) -> Row<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return .error }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return sqlite3_column_text(stmt, 0).map { .value(String(cString: $0)) } ?? .none
        case SQLITE_DONE: return .none
        default: return .error
        }
    }

    /// LIKE patterns for every page on a host, both schemes, with and without www.
    static func hostPatterns(_ host: String) -> [String] {
        ["https://\(host)/%", "http://\(host)/%", "https://www.\(host)/%", "http://www.\(host)/%"]
    }
}

/// Chrome, Brave, Edge, Arc, Vivaldi, Chromium: `Favicons` (rollback journal).
/// Bitmaps are PNG, one row per size; the exact page wins, then the widest.
final class ChromiumFaviconCache: FaviconCache {
    private let copy: SQLiteCopy
    init?(db: URL, tmp: URL) {
        guard let c = SQLiteCopy(source: db, tmp: tmp, sidecars: ["-journal"]) else { return nil }
        copy = c
    }
    func lookup(host: String, pageURL: URL?) -> FaviconLookup {
        var page = pageURL?.absoluteString ?? ""
        if let hash = page.firstIndex(of: "#") { page = String(page[..<hash]) }
        let sql = """
            SELECT b.image_data, b.width FROM icon_mapping m
            JOIN favicons f ON f.id = m.icon_id
            JOIN favicon_bitmaps b ON b.icon_id = f.id
            WHERE m.page_url = ?1 OR m.page_url LIKE ?2 OR m.page_url LIKE ?3 OR m.page_url LIKE ?4 OR m.page_url LIKE ?5
            ORDER BY (m.page_url = ?1) DESC, b.width DESC, b.last_updated DESC LIMIT 1;
            """
        switch copy.firstBlob(sql, binds: [page] + SQLiteCopy.hostPatterns(host)) {
        case .value(let (data, width)): return .hit(FaviconHit(data: data, width: width, isSVG: false, source: "chromium"))
        case .none: return .miss
        case .error: return .failed
        }
    }
    func close() { copy.close() }
}

/// Firefox: `favicons.sqlite` (WAL). Page-linked icons first, then the host's
/// root icon; width 65535 means the payload is SVG.
final class FirefoxFaviconCache: FaviconCache {
    private let copy: SQLiteCopy
    init?(db: URL, tmp: URL) {
        guard let c = SQLiteCopy(source: db, tmp: tmp, sidecars: ["-wal", "-shm"]) else { return nil }
        copy = c
    }
    func lookup(host: String, pageURL: URL?) -> FaviconLookup {
        let p = SQLiteCopy.hostPatterns(host)
        let linked = """
            SELECT i.data, i.width FROM moz_pages_w_icons p
            JOIN moz_icons_to_pages ip ON ip.page_id = p.id
            JOIN moz_icons i ON i.id = ip.icon_id
            WHERE p.page_url LIKE ?1 OR p.page_url LIKE ?2 OR p.page_url LIKE ?3 OR p.page_url LIKE ?4
            ORDER BY i.width DESC LIMIT 1;
            """
        let root = """
            SELECT data, width FROM moz_icons
            WHERE root = 1 AND (icon_url LIKE ?1 OR icon_url LIKE ?2 OR icon_url LIKE ?3 OR icon_url LIKE ?4)
            ORDER BY width DESC LIMIT 1;
            """
        var result = copy.firstBlob(linked, binds: p)
        if case .none = result { result = copy.firstBlob(root, binds: p) }
        switch result {
        case .value(let (data, width)):
            let svg = width == 65535
            return .hit(FaviconHit(data: data, width: svg ? 256 : width, isSVG: svg, source: "firefox"))
        case .none: return .miss
        case .error: return .failed
        }
    }
    func close() { copy.close() }
}

/// Safari: `Favicon Cache/favicons.db` plus image files named by the MD5 of the
/// icon's uuid. Only reachable with Full Disk Access; best effort.
final class SafariFaviconCache: FaviconCache {
    private let copy: SQLiteCopy
    private let imagesDir: URL
    init?(db: URL, tmp: URL) {
        guard let c = SQLiteCopy(source: db, tmp: tmp, sidecars: ["-wal", "-shm"]) else { return nil }
        copy = c
        imagesDir = db.deletingLastPathComponent().appendingPathComponent("favicons", isDirectory: true)
    }
    func lookup(host: String, pageURL: URL?) -> FaviconLookup {
        let sql = """
            SELECT I.uuid FROM icon_info I JOIN page_url P ON P.uuid = I.uuid
            WHERE P.url LIKE ?1 OR P.url LIKE ?2 OR P.url LIKE ?3 OR P.url LIKE ?4
            ORDER BY I.timestamp DESC LIMIT 1;
            """
        switch copy.firstText(sql, binds: SQLiteCopy.hostPatterns(host)) {
        case .error: return .failed
        case .none: return .miss
        case .value(let uuid):
            let name = Insecure.MD5.hash(data: Data(uuid.utf8)).map { String(format: "%02X", $0) }.joined()
            guard let data = try? Data(contentsOf: imagesDir.appendingPathComponent(name)), let img = NSImage(data: data) else { return .miss }
            let svg = data.starts(with: Array("<svg".utf8)) || data.starts(with: Array("<?xml".utf8))
            return .hit(FaviconHit(data: data, width: Int(img.size.width), isSVG: svg, source: "safari"))
        }
    }
    func close() { copy.close() }
}
