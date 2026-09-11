import XCTest
@testable import Availeth

final class StoryFormatTests: XCTestCase {

    // MARK: Cleaning

    func testCleanStripsLeakedMarkdownAndLabels() {
        XCTAssertEqual(StoryFormat.clean("** Task Automation Evaluation"), "Task Automation Evaluation")
        XCTAssertEqual(StoryFormat.clean("**Bold title**"), "Bold title")
        XCTAssertEqual(StoryFormat.clean("TITLE: Invoice entry"), "Invoice entry")
        XCTAssertEqual(StoryFormat.clean("**Summary**: Moved totals"), "Moved totals")
        XCTAssertEqual(StoryFormat.clean("## Steps"), "Steps")
        XCTAssertEqual(StoryFormat.clean("\"Quoted\""), "Quoted")
        XCTAssertEqual(StoryFormat.clean("****"), "")
    }

    func testCleanKeepsInnerBoldForTheRenderer() {
        XCTAssertEqual(StoryFormat.clean("**NetSuite** \u{2014} Vendor Bills"), "**NetSuite** \u{2014} Vendor Bills")
        XCTAssertEqual(StoryFormat.bulletBody("- **NetSuite** \u{2014} Vendor Bills; fields: Invoice Number"),
                       "**NetSuite** \u{2014} Vendor Bills; fields: Invoice Number")
        XCTAssertEqual(StoryFormat.stepBody("1. **Open** the PO")?.1, "**Open** the PO")
        XCTAssertEqual(StoryFormat.plain("**Invoice** entry"), "Invoice entry", "plain text fields drop every marker")
    }

    // MARK: Summary line

    func testLegacyParagraphSummaryIsFirstSentences() {
        let text = "** The employee reviewed the Opportunity Map on the Availeth page. They then edited a document in Fable 5.1 to shorten the copy. Finally they compared macOS and Windows versions of the text."
        let s = StoryFormat.summary(text)
        XCTAssertTrue(s.hasPrefix("The employee reviewed the Opportunity Map"))
        XCTAssertFalse(s.hasPrefix("**"))
        XCTAssertLessThanOrEqual(s.count, 150)
    }

    func testStructuredSummaryIsLeadingPlainLine() {
        let text = "Reviewed the map and tightened the landing-page copy.\n\n**📌 What happened**\n- Opened the Opportunity Map\n**🔁 Steps**\n1. Read the rows"
        XCTAssertEqual(StoryFormat.summary(text), "Reviewed the map and tightened the landing-page copy.")
    }

    func testSummaryNeverBecomesAHeading() {
        XCTAssertEqual(StoryFormat.summary("**📌 What happened**\n- Opened **NetSuite** first\n- Pasted"), "Opened NetSuite first")
        XCTAssertEqual(StoryFormat.summary("**📌 What happened**\n**🔁 Steps**"), "", "headings only → nothing to say")
        XCTAssertEqual(StoryFormat.summary("**Invoice Entry**\n- Copied the total"), "Copied the total", "a fully-bold first line is a heading — skip it rather than echo the card title")
    }

    func testSummaryCutsOnAWordBoundary() {
        let long = "The user opened each supplier invoice in Outlook and then re-entered the supplier, invoice number, line totals and tax codes into NetSuite one field at a time before saving."
        let s = StoryFormat.summary(long, limit: 80)
        XCTAssertTrue(s.hasSuffix("\u{2026}"))
        XCTAssertLessThanOrEqual(s.count, 80)
        let words = s.dropLast().split(separator: " ")
        XCTAssertTrue(long.contains(String(words.last ?? "")), "cut fell mid-word: \(s)")
        XCTAssertTrue(long.contains(String(words.last ?? "") + " "), "cut fell mid-word: \(s)")
    }

    // MARK: Blocks

    func testLegacyParagraphBecomesBulletedSection() {
        let blocks = StoryFormat.blocks("First thing happened. Second thing happened, e.g. a value was pasted. Third thing.")
        XCTAssertEqual(blocks.first, .heading("📌 What happened"))
        let bullets = blocks.compactMap { if case .bullet(let b) = $0 { return b } else { return nil } }
        XCTAssertEqual(bullets.count, 3, "sentence split must survive \"e.g.\" — got \(bullets)")
        XCTAssertEqual(bullets[0], "First thing happened.")
    }

    func testUnstructuredStoryDoesNotRepeatItsSummary() {
        let blocks = StoryFormat.blocks("Moved PO totals.\n\nThe user copied each total. They submitted the bill.")
        XCTAssertEqual(blocks, [.heading("📌 What happened"), .bullet("The user copied each total."), .bullet("They submitted the bill.")])
    }

    func testStructuredBlocksParseHeadingsBulletsAndSteps() {
        let text = "One-line summary.\n**📌 What happened**\n- Opened NetSuite\n* Pasted the PO\n**🔁 Steps**\n1. Copy the total\n2) Paste into the bill"
        let blocks = StoryFormat.blocks(text)
        XCTAssertEqual(blocks, [
            .heading("📌 What happened"),
            .bullet("Opened NetSuite"),
            .bullet("Pasted the PO"),
            .heading("🔁 Steps"),
            .step(1, "Copy the total"),
            .step(2, "Paste into the bill"),
        ], "the leading summary line is dropped (it's on the card) and every block type is recognised")
    }

    func testLooserMarkersStillParse() {
        let text = "Summary.\r\n## What happened:\r\n\u{2014} Opened the PO\r\n**Steps**:\r\nStep 1: Copy the total\r\n****\r\nSTORY:\r\nWhat a machine could do:\r\n\u{2022} Everything"
        XCTAssertEqual(StoryFormat.blocks(text), [
            .heading("What happened"),
            .bullet("Opened the PO"),
            .heading("Steps"),
            .step(1, "Copy the total"),
            .heading("What a machine could do"),
            .bullet("Everything"),
        ], "CRLF, '#', trailing colons, 'Step 1:', em-dash bullets, and junk lines")
    }

    func testHeadingDetection() {
        XCTAssertTrue(StoryFormat.isHeading("**🛠️ Systems and data**"))
        XCTAssertTrue(StoryFormat.isHeading("**What happened**:"))
        XCTAssertTrue(StoryFormat.isHeading("**What happened:**"))
        XCTAssertTrue(StoryFormat.isHeading("## Steps"))
        XCTAssertTrue(StoryFormat.isHeading("What happened:"))
        XCTAssertFalse(StoryFormat.isHeading("**bold** in the middle of **text**"))
        XCTAssertFalse(StoryFormat.isHeading("- a bullet"))
        XCTAssertFalse(StoryFormat.isHeading("- Set the job title:"))
        XCTAssertFalse(StoryFormat.isHeading("Then they opened the file, pasted, and saved it:"))
    }

    // MARK: Level + units

    func testLevelSplitsReason() {
        let r = StoryFormat.level("High — copy/paste between NetSuite and Excel on every run")
        XCTAssertEqual(r.level, "High")
        XCTAssertTrue(r.reason.hasPrefix("copy/paste"))
        XCTAssertEqual(StoryFormat.level("Low").level, "Low")
        XCTAssertEqual(StoryFormat.level("").level, "Low")
    }

    func testStoryCardUnitsMatchLogoKeys() {
        XCTAssertEqual(StoryCard.units("Google Chrome, Claude, Microsoft Excel, Claude"), ["Chrome", "Claude", "Excel"])
        XCTAssertEqual(LogoProvider.key(for: StoryCard.units("Google Chrome").first ?? ""), "chrome")
    }

    // MARK: Synthesizer parser keeps structure

    func testParserKeepsStructureAndSummary() {
        let raw = "TITLE: **Invoice entry**\nSUMMARY: Moved PO totals into NetSuite.\nSTORY:\n**📌 What happened**\n- Copied the total\n**🔁 Steps**\n1. Open the PO"
        let (title, story) = Synthesizer.parseTitleAndStory(raw, fallbackApps: ["Excel"])
        XCTAssertEqual(title, "Invoice entry")
        XCTAssertTrue(story.hasPrefix("Moved PO totals into NetSuite."))
        XCTAssertTrue(story.contains("\n- Copied the total"))
        XCTAssertTrue(StoryFormat.isStructured(story))
        XCTAssertEqual(StoryFormat.summary(story), "Moved PO totals into NetSuite.")
    }

    func testParserLabelsMustStartTheLine() {
        let raw = "TITLE: HR update\nSTORY:\n- Set the job title: Manager in Workday\n- Wrote the summary: Q3 numbers\n- Saved the record"
        let (title, story) = Synthesizer.parseTitleAndStory(raw, fallbackApps: ["Chrome"])
        XCTAssertEqual(title, "HR update")
        XCTAssertEqual(story, "- Set the job title: Manager in Workday\n- Wrote the summary: Q3 numbers\n- Saved the record")
    }

    func testParserAcceptsBoldLabelsCRLFAndMissingStoryLabel() {
        let raw = "**TITLE**: **Invoice** entry\r\n**SUMMARY:** \"Moved totals.\"\r\n**📌 What happened**\r\n- Copied the total"
        let (title, story) = Synthesizer.parseTitleAndStory(raw, fallbackApps: ["Excel"])
        XCTAssertEqual(title, "Invoice entry")
        XCTAssertEqual(story, "Moved totals.\n\n**📌 What happened**\n- Copied the total")
    }
}
