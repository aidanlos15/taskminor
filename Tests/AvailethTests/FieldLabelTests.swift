import XCTest
@testable import Availeth

/// What the accessibility API calls a label is often not one. These are real
/// labels that were stored as fields on the owner's Mac.
final class FieldLabelTests: XCTestCase {

    func testNumbersAreNotLabels() {
        XCTAssertFalse(FieldClassifier.isUsableLabel("5"))
        XCTAssertFalse(FieldClassifier.isUsableLabel("2"))
        XCTAssertFalse(FieldClassifier.isUsableLabel("1,234.00"))
        XCTAssertFalse(FieldClassifier.isUsableLabel(" 42 "))
    }

    func testWebAddressesAreNotLabels() {
        XCTAssertFalse(FieldClassifier.isUsableLabel("example.com"))
        XCTAssertFalse(FieldClassifier.isUsableLabel("https://commandcentre.availeth.io/"))
        XCTAssertFalse(FieldClassifier.isUsableLabel("www.nytimes.com"))
        XCTAssertTrue(FieldClassifier.looksLikeWebAddress("availeth.io"))
    }

    func testCutOffScreenTextIsNotALabel() {
        XCTAssertFalse(FieldClassifier.isUsableLabel("Twitter..."))
        XCTAssertFalse(FieldClassifier.isUsableLabel("Search the web…"))
    }

    func testTooShortIsNotALabel() {
        XCTAssertFalse(FieldClassifier.isUsableLabel(""))
        XCTAssertFalse(FieldClassifier.isUsableLabel("A"))
        XCTAssertFalse(FieldClassifier.isUsableLabel("A1"))
    }

    func testRealLabelsAreKept() {
        for label in ["Invoice Number", "Amount", "To", "PO", "Subject", "Job name", "E-mail address"] {
            XCTAssertTrue(FieldClassifier.isUsableLabel(label), label)
        }
    }

    /// Rows already in the store hold the junk, so it is dropped on read too.
    func testStoredJunkIsDroppedOnRead() {
        XCTAssertNil(Evidence.cleanField("example.com"))
        XCTAssertNil(Evidence.cleanField("https://commandcentre.availeth.io/"))
        XCTAssertNil(Evidence.cleanField("Twitter..."))
        XCTAssertNil(Evidence.cleanField("5 [identifier]"))
        XCTAssertEqual(Evidence.cleanField("Invoice Number [identifier]"), "Invoice Number")
    }

    /// A minute record built from a span full of junk labels names no fields.
    func testJunkLabelsNeverReachTheRecord() {
        let span = ActivitySpan(bundleID: "com.apple.Safari", appName: "Safari", windowTitle: "Command Centre",
                                start: Date(timeIntervalSince1970: 1_700_000_000),
                                end: Date(timeIntervalSince1970: 1_700_000_030),
                                keystrokes: 30, clicks: 3, shortcuts: "",
                                fields: "5, example.com, https://commandcentre.availeth.io/, Job name")
        let r = StoryWriter.minuteRecord(spans: [span], transfers: [], narratives: [])
        XCTAssertEqual(r.windows.first?.fields, ["Job name"])
    }
}
