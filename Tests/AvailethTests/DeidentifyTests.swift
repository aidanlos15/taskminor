import XCTest
@testable import Availeth

/// Window titles carry the names of customers, colleagues and records. A model
/// told it is describing "an employee" picks the nearest name and writes the
/// account as though that person were the one being watched. Observed live:
/// "Vanessa Baez performs a series of tasks related to job management…" from a
/// title reading "Vanessa Baez IP suspicious activity".
final class DeidentifyTests: XCTestCase {

    func testTheObservedPersonIsNeverNamed() {
        let cases = [
            "Vanessa Baez performs a series of tasks related to job management and timesheet entry.",
            "Vanessa Baez's daily task involves navigating through various apps.",
            "Beata Kowalski opened the timesheet and entered hours.",
        ]
        for input in cases {
            let out = NarrativeSanitizer.scrub(input)
            XCTAssertFalse(out.contains("Vanessa"), out)
            XCTAssertFalse(out.contains("Baez"), out)
            XCTAssertFalse(out.contains("Beata"), out)
            XCTAssertTrue(out.lowercased().hasPrefix("the user"), out)
        }
    }

    /// A name mentioned INSIDE the work is data the person is handling, and must
    /// survive: it is often the whole point of the workflow.
    func testNamesInsideTheWorkSurvive() {
        let input = "The user updated the Acme Corp record and emailed Beata Kowalski the summary."
        let out = NarrativeSanitizer.scrub(input)
        XCTAssertTrue(out.contains("Acme Corp"), out)
        XCTAssertTrue(out.contains("Beata Kowalski"), out)
    }

    /// Sentences that begin with an app or a common noun are not people.
    func testAppAndNounSubjectsAreUntouched() {
        let cases = [
            "Microsoft Outlook was used to draft a reply.",
            "Purchase Orders were checked against the invoice.",
            "Safari showed the Jobber schedule.",
            "Timesheet entry took most of the minute.",
            "During this minute the user copied a reference.",
        ]
        for input in cases {
            XCTAssertEqual(NarrativeSanitizer.scrub(input), input, "rewrote a non-person subject")
        }
    }

    /// A name later in the text, as the subject of a second sentence, is also
    /// caught, and the sentence before it is left intact.
    func testSecondSentenceSubjectIsCaught() {
        let input = "The user opened the timesheet. Vanessa Baez then entered the hours."
        let out = NarrativeSanitizer.scrub(input)
        XCTAssertTrue(out.hasPrefix("The user opened the timesheet."), out)
        XCTAssertFalse(out.contains("Vanessa"), out)
    }

    /// The existing redactions still work alongside the new one.
    func testAmountsIdsAndEmailsStillRedacted() {
        let out = NarrativeSanitizer.scrub("Vanessa Baez entered 18672.44 for INV-10247 and mailed a@b.com.")
        XCTAssertFalse(out.contains("Vanessa"), out)
        XCTAssertTrue(out.contains("[amount]"), out)
        XCTAssertTrue(out.contains("[email]"), out)
    }
}
