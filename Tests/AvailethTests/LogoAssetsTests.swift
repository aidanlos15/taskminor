import XCTest
@testable import Availeth

/// Guards the Opportunity Map's logos: every service the title matcher can
/// produce must have a bundled mark, and every mark must decode, so a new
/// service can never silently regress to a lettermark.
final class LogoAssetsTests: XCTestCase {
    private var logosDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Logos")
    }

    /// Services with no public vector mark. Add here deliberately, not by accident.
    private let exempt: Set<String> = ["Temu", "Base44"]

    func testEveryKnownServiceHasABundledLogo() {
        var missing: [String] = []
        for name in WorkflowUnit.serviceNames where !exempt.contains(name) {
            let file = logosDir.appendingPathComponent(LogoProvider.key(for: name) + ".svg")
            if !FileManager.default.fileExists(atPath: file.path) { missing.append(name) }
        }
        XCTAssertTrue(missing.isEmpty, "No bundled logo for: \(missing)")
    }

    func testCommonAppUnitsHaveLogos() {
        for unit in ["Excel", "Outlook", "Teams", "Chrome", "Slack", "Sheets", "Notion", "Zoom", "Dropbox", "Trello", "Asana", "NetSuite"] {
            let file = logosDir.appendingPathComponent(LogoProvider.key(for: unit) + ".svg")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "No bundled logo for \(unit)")
        }
    }

    func testEveryBundledLogoDecodes() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: logosDir.path).filter { $0.hasSuffix(".svg") }
        XCTAssertGreaterThan(files.count, 30)
        for f in files {
            let image = NSImage(contentsOfFile: logosDir.appendingPathComponent(f).path)
            XCTAssertNotNil(image, "\(f) failed to decode")
            XCTAssertGreaterThan(image?.size.width ?? 0, 0, "\(f) has no size")
        }
    }

    /// Every host → mark mapping points at a real bundled file.
    func testBundledMarkKeysExist() {
        for key in HostNormalizer.bundledMarkKeys.sorted() {
            XCTAssertTrue(FileManager.default.fileExists(atPath: logosDir.appendingPathComponent(key + ".svg").path), "No Logos/\(key).svg for a host mapping")
        }
    }

    func testKeyNormalisation() {
        XCTAssertEqual(LogoProvider.key(for: "Google Sheets"), "googlesheets")
        XCTAssertEqual(LogoProvider.key(for: "NetSuite"), "netsuite")
        XCTAssertEqual(LogoProvider.key(for: "Xero"), "xero")
    }

    /// Only units that are real apps get a bundle id; browser sites never do.
    func testBundleMapOnlyMapsApps() {
        let now = Date()
        let spans = [
            ActivitySpan(bundleID: "com.microsoft.Excel", appName: "Microsoft Excel", windowTitle: "Book.xlsx", start: now, end: now.addingTimeInterval(10)),
            ActivitySpan(bundleID: "com.google.Chrome", appName: "Google Chrome", windowTitle: "Vendor Bills — NetSuite", start: now, end: now.addingTimeInterval(10)),
        ]
        let map = LogoProvider.bundleMap(spans)
        XCTAssertEqual(map["Excel"], "com.microsoft.Excel")
        XCTAssertNil(map["NetSuite"], "a browser site must not be mapped to the browser's bundle id")
    }
}
