import XCTest
@testable import Availeth

final class LabelKeyTests: XCTestCase {

    func testCleanTitleStripsBrowserAndProfileTails() {
        XCTAssertEqual(LabelKey.cleanTitle("Claude - Google Chrome - Aidan", appName: "Google Chrome"), "Claude")
        XCTAssertEqual(LabelKey.cleanTitle("AIB Internet Banking - Google Chrome - Aidan", appName: "Google Chrome"), "AIB Internet Banking")
        XCTAssertEqual(LabelKey.cleanTitle("Vendor Bills \u{2014} Safari", appName: "Safari"), "Vendor Bills")
        XCTAssertEqual(LabelKey.cleanTitle("\u{25CF} Budget.xlsx \u{2014} Excel", appName: "Microsoft Excel"), "Budget.xlsx")
        XCTAssertEqual(LabelKey.cleanTitle("Inbox (42)", appName: "Mail"), "Inbox")
        XCTAssertEqual(LabelKey.cleanTitle("", appName: "Claude"), "General Claude usage")
        // A real title that merely contains a dash survives intact.
        XCTAssertEqual(LabelKey.cleanTitle("Smart campaign - Ring of Kerry Hotel - Google Ads - Google Chrome - Ring", appName: "Google Chrome"),
                       "Smart campaign - Ring of Kerry Hotel - Google Ads")
    }

    func testCanonKey() {
        XCTAssertEqual(LabelKey.canonKey("  Debug   a Swift-build error! "), "debug a swift build error")
        XCTAssertEqual(LabelKey.canonKey("Claude"), "claude")
        XCTAssertEqual(LabelKey.canonKey("***"), "")
    }

    func testUninformativeTitles() {
        XCTAssertTrue(LabelKey.isUninformative(unit: "Claude", cleanTitle: "Claude"))
        XCTAssertTrue(LabelKey.isUninformative(unit: "Claude", cleanTitle: "General Claude usage"))
        XCTAssertTrue(LabelKey.isUninformative(unit: "Claude", cleanTitle: "New chat"))
        XCTAssertTrue(LabelKey.isUninformative(unit: "ChatGPT", cleanTitle: "ChatGPT | OpenAI"))
        XCTAssertTrue(LabelKey.isUninformative(unit: "Claude", cleanTitle: "New chat - Claude"))
        XCTAssertTrue(LabelKey.isUninformative(unit: "AIB Internet Banking", cleanTitle: "AIB Internet Banking"))
        XCTAssertFalse(LabelKey.isUninformative(unit: "Google Ads", cleanTitle: "Smart campaign - Ring of Kerry Hotel - Google Ads"))
        XCTAssertFalse(LabelKey.isUninformative(unit: "Google Sheets", cleanTitle: "Vendor list - Google Sheets"), "a document on a known service is informative")
        XCTAssertFalse(LabelKey.isUninformative(unit: "Gmail", cleanTitle: "Invoices - Gmail"))
        XCTAssertFalse(LabelKey.isUninformative(unit: "Claude", cleanTitle: "Claude pricing plans"))
        XCTAssertFalse(LabelKey.isUninformative(unit: "Excel", cleanTitle: "Purchase Orders.xlsx"))
        XCTAssertFalse(LabelKey.isUninformative(unit: "Notes", cleanTitle: "All iCloud \u{2013} 174 notes"))
    }

    func testBrowserTailOnlyStrippedForBrowsers() {
        XCTAssertEqual(LabelKey.cleanTitle("Notes - Arc", appName: "Notes"), "Notes - Arc", "a note called Arc is a note, not a browser tail")
        XCTAssertEqual(LabelKey.cleanTitle("Notes - Arc", appName: "Arc"), "Notes")
    }

    func testMergeIsConservative() {
        let existing = ["Debug a Swift build error", "Draft the supplier payment-terms email", "Reconcile Q3 supplier invoices"]
        XCTAssertEqual(LabelKey.merge("Debug the Swift build errors", into: existing), "Debug a Swift build error", "same words, plural folded")
        XCTAssertEqual(LabelKey.merge("Debug the Swift build error again", into: existing), "Debug a Swift build error", "superset adopts")
        XCTAssertEqual(LabelKey.merge("Fix Swift build errors", into: existing), "Fix Swift build errors", "one word of four differs — left to the model's MATCH")
        XCTAssertEqual(LabelKey.merge("Reconcile Q4 supplier invoices", into: existing), "Reconcile Q4 supplier invoices", "a differing number is a different task")
        XCTAssertEqual(LabelKey.merge("Compare AI model capabilities", into: existing), "Compare AI model capabilities", "unrelated stays new")
        XCTAssertEqual(LabelKey.merge("Email", into: existing), "Email", "one-word titles never merge")
        XCTAssertEqual(LabelKey.merge("Draft supplier email", into: []), "Draft supplier email")
    }
}
