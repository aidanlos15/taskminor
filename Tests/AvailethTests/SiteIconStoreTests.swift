import AppKit
import SQLite3
import XCTest
@testable import Availeth

/// Exercises the favicon pipeline against fixture browser caches built with the
/// real schemas, in a temp "Application Support" — never the user's own profiles.
final class SiteIconStoreTests: XCTestCase {
    private var root: URL!
    private var iconsDir: URL!
    private var store: Store!
    private var icons: SiteIconStore!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("availeth-siteicons-\(UUID().uuidString)", isDirectory: true)
        iconsDir = root.appendingPathComponent("favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = Store.inMemory()
        icons = SiteIconStore()
        icons.applicationSupport = root.appendingPathComponent("AppSupport", isDirectory: true)
        icons.safariDirectory = root.appendingPathComponent("NoSafari", isDirectory: true)
        icons.directory = iconsDir
        icons.attach(store: store)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// A real 16×16 PNG so the decode sanity check passes.
    private func png(color: NSColor, size: Int = 16) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill(); NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, sql) }

    /// Builds <AppSupport>/Google/Chrome/<profile>/Favicons with the Chromium schema.
    private func makeChromiumCache(profile: String, pages: [(url: String, iconID: Int)], bitmaps: [(iconID: Int, width: Int, data: Data)]) {
        let dir = icons.applicationSupport.appendingPathComponent("Google/Chrome/\(profile)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("Favicons").path, &db), SQLITE_OK)
        exec(db, "CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR); INSERT INTO meta VALUES('version','9');")
        exec(db, "CREATE TABLE favicons(id INTEGER PRIMARY KEY, url LONGVARCHAR NOT NULL, icon_type INTEGER DEFAULT 1);")
        exec(db, "CREATE TABLE favicon_bitmaps(id INTEGER PRIMARY KEY, icon_id INTEGER NOT NULL, last_updated INTEGER DEFAULT 0, image_data BLOB, width INTEGER DEFAULT 0, height INTEGER DEFAULT 0, last_requested INTEGER DEFAULT 0);")
        exec(db, "CREATE TABLE icon_mapping(id INTEGER PRIMARY KEY, page_url LONGVARCHAR NOT NULL, icon_id INTEGER, page_url_type INTEGER DEFAULT 0);")
        for id in Set(pages.map(\.iconID)) { exec(db, "INSERT INTO favicons(id, url) VALUES(\(id), 'https://example/favicon-\(id).ico');") }
        for p in pages { exec(db, "INSERT INTO icon_mapping(page_url, icon_id) VALUES('\(p.url)', \(p.iconID));") }
        for b in bitmaps {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO favicon_bitmaps(icon_id, image_data, width, height, last_updated) VALUES(?,?,?,?,1);", -1, &stmt, nil)
            sqlite3_bind_int(stmt, 1, Int32(b.iconID))
            b.data.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(b.data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            sqlite3_bind_int(stmt, 3, Int32(b.width)); sqlite3_bind_int(stmt, 4, Int32(b.width))
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
        sqlite3_close(db)
    }

    private func makeFirefoxCache(profile: String, rootIcons: [(iconURL: String, width: Int, data: Data)]) {
        let dir = icons.applicationSupport.appendingPathComponent("Firefox/Profiles/\(profile)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("favicons.sqlite").path, &db), SQLITE_OK)
        exec(db, "CREATE TABLE moz_icons(id INTEGER PRIMARY KEY, icon_url TEXT NOT NULL, fixed_icon_url_hash INTEGER NOT NULL, width INTEGER NOT NULL DEFAULT 0, root INTEGER NOT NULL DEFAULT 0, color INTEGER, expire_ms INTEGER NOT NULL DEFAULT 0, flags INTEGER NOT NULL DEFAULT 0, data BLOB);")
        exec(db, "CREATE TABLE moz_pages_w_icons(id INTEGER PRIMARY KEY, page_url TEXT NOT NULL, page_url_hash INTEGER NOT NULL);")
        exec(db, "CREATE TABLE moz_icons_to_pages(page_id INTEGER NOT NULL, icon_id INTEGER NOT NULL, expire_ms INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(page_id, icon_id)) WITHOUT ROWID;")
        for r in rootIcons {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO moz_icons(icon_url, fixed_icon_url_hash, width, root, data) VALUES(?, 1, ?, 1, ?);", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, r.iconURL, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(stmt, 2, Int32(r.width))
            r.data.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(r.data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
        sqlite3_close(db)
    }

    // MARK: Tests

    func testChromiumIconIsFoundWrittenAndServed() {
        let small = png(color: .red), big = png(color: .blue, size: 32)
        makeChromiumCache(profile: "Default",
                          pages: [("https://onlinebanking.aib.ie/inet/roi/login.htm", 1), ("https://aib.ie/", 1), ("https://claude.ai/new", 2)],
                          bitmaps: [(1, 16, small), (1, 32, big), (2, 16, small)])
        icons.request(host: "onlinebanking.aib.ie", pageURL: URL(string: "https://onlinebanking.aib.ie/inet/roi/login.htm#x"))
        XCTAssertEqual(icons.drainNow(), ["aib.ie"])

        let row = store.siteIcon(host: "onlinebanking.aib.ie")
        XCTAssertEqual(row?.domain, "aib.ie")
        XCTAssertEqual(row?.source, "chromium")
        XCTAssertEqual(row?.width, 32, "the widest bitmap wins")
        XCTAssertEqual(row?.path, iconsDir.appendingPathComponent("aib.ie.png").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: row!.path))
        XCTAssertNotNil(icons.cachedImage(domain: "aib.ie"))
        XCTAssertEqual(store.siteIcon(domain: "aib.ie")?.width, 32)

        // A sibling host of the same brand shares the file without another lookup.
        icons.request(host: "aib.ie", pageURL: nil)
        XCTAssertEqual(icons.drainNow(), [], "nothing new stored")
        XCTAssertEqual(store.siteIcon(host: "aib.ie")?.path, row?.path)
    }

    func testHostPrefixMatchWhenPageUnknownAndOtherProfilesAreSearched() {
        makeChromiumCache(profile: "Profile 4", pages: [("https://claude.ai/chat/abc", 9)], bitmaps: [(9, 16, png(color: .orange))])
        icons.request(host: "claude.ai", pageURL: nil)
        XCTAssertEqual(icons.drainNow(), ["claude.ai"])
        XCTAssertEqual(store.siteIcon(host: "claude.ai")?.source, "chromium")
    }

    func testFirefoxRootIconAndSVGFlag() {
        makeFirefoxCache(profile: "abc.default-release", rootIcons: [("https://www.mozilla.org/favicon.ico", 32, png(color: .green))])
        icons.request(host: "mozilla.org", pageURL: nil)
        XCTAssertEqual(icons.drainNow(), ["mozilla.org"])
        XCTAssertEqual(store.siteIcon(host: "mozilla.org")?.source, "firefox")
        XCTAssertTrue(store.siteIcon(host: "mozilla.org")!.path.hasSuffix("mozilla.org.png"))
    }

    func testMissRecordedOnceADay() {
        makeChromiumCache(profile: "Default", pages: [("https://aib.ie/", 1)], bitmaps: [(1, 16, png(color: .red))])
        icons.request(host: "nowhere.example", pageURL: nil)
        XCTAssertEqual(icons.drainNow(), [])
        let miss = store.siteIcon(host: "nowhere.example")
        XCTAssertEqual(miss?.path, "")
        XCTAssertEqual(miss?.attempts, 1)
        XCTAssertNil(icons.cachedImage(domain: "nowhere.example"))

        icons.request(host: "nowhere.example", pageURL: nil)
        icons.drainNow()
        XCTAssertEqual(store.siteIcon(host: "nowhere.example")?.attempts, 1, "not retried inside the retry window")
        icons.negativeRetry = 0
        icons.request(host: "nowhere.example", pageURL: nil)
        icons.drainNow()
        XCTAssertEqual(store.siteIcon(host: "nowhere.example")?.attempts, 2, "retried once the window passed")
    }

    func testNoReadableCacheLeavesNoRow() {
        icons.request(host: "aib.ie", pageURL: nil)
        XCTAssertEqual(icons.drainNow(), [])
        XCTAssertNil(store.siteIcon(host: "aib.ie"), "no browser cache to read is not a miss — try again later")
    }

    func testCorruptCacheIsSkipped() {
        let dir = icons.applicationSupport.appendingPathComponent("Google/Chrome/Default", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(repeating: 0x41, count: 4096).write(to: dir.appendingPathComponent("Favicons"))
        icons.request(host: "aib.ie", pageURL: nil)
        XCTAssertEqual(icons.drainNow(), [])
        XCTAssertNil(store.siteIcon(host: "aib.ie"))
    }

    func testRequestMissingSkipsKnownHosts() {
        makeChromiumCache(profile: "Default", pages: [("https://aib.ie/", 1)], bitmaps: [(1, 16, png(color: .red))])
        icons.request(host: "aib.ie", pageURL: nil)
        icons.drainNow()
        icons.requestMissing(hosts: ["aib.ie", "claude.ai"])
        XCTAssertEqual(icons.drainNow(), [], "aib.ie is known; claude.ai is a fresh miss")
        XCTAssertNotNil(store.siteIcon(host: "claude.ai"))
        XCTAssertEqual(store.siteIcons().count, 2)
    }

    func testPurgeRemovesRowsAndFiles() {
        makeChromiumCache(profile: "Default", pages: [("https://aib.ie/", 1)], bitmaps: [(1, 16, png(color: .red))])
        icons.request(host: "aib.ie", pageURL: nil)
        icons.drainNow()
        let path = store.siteIcon(host: "aib.ie")!.path
        icons.purgeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(store.siteIcons().isEmpty)
        XCTAssertNil(icons.cachedImage(domain: "aib.ie"))
    }

    func testPageHostRoundTripsThroughTheStore() {
        let now = Date()
        store.insert(ActivitySpan(bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: "AIB Internet Banking - Google Chrome - Aidan",
                                  start: now.addingTimeInterval(-300), end: now.addingTimeInterval(-60), pageHost: "onlinebanking.aib.ie"))
        store.insert(ActivitySpan(bundleID: "com.microsoft.Excel", appName: "Microsoft Excel", windowTitle: "PO.xlsx",
                                  start: now.addingTimeInterval(-50), end: now.addingTimeInterval(-10)))
        let spans = store.spans(from: now.addingTimeInterval(-600), to: now, demo: false)
        XCTAssertEqual(spans.map(\.pageHost), ["onlinebanking.aib.ie", ""])
        XCTAssertEqual(LogoProvider.siteMap(spans), ["AIB Internet Banking": "onlinebanking.aib.ie"])
        XCTAssertEqual(LogoProvider.hosts(spans), ["onlinebanking.aib.ie"])
    }

    func testMissingIconFileIsRefetched() {
        makeChromiumCache(profile: "Default", pages: [("https://aib.ie/", 1)], bitmaps: [(1, 16, png(color: .red))])
        icons.request(host: "aib.ie", pageURL: nil)
        icons.drainNow()
        let path = store.siteIcon(host: "aib.ie")!.path
        try? FileManager.default.removeItem(atPath: path)
        icons.requestMissing(hosts: ["aib.ie"])
        XCTAssertEqual(icons.drainNow(), ["aib.ie"], "a row whose file vanished is fetched again")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
}
