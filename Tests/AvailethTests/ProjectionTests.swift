import XCTest
@testable import Availeth

/// The "potential saving / yr" figure is a rate scaled to a year. It must not
/// creep upward simply because the app has been left running for longer.
final class ProjectionTests: XCTestCase {

    private let cal = Calendar.current
    private var day0: Date { cal.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000)) }

    private func day(_ n: Int) -> Date {
        cal.date(byAdding: .day, value: n, to: day0)!
    }

    /// One run of the same routine, on day `n`, taking `seconds`.
    private func window(day n: Int, atHour h: Int = 9, seconds: TimeInterval = 1800) -> DateInterval {
        DateInterval(start: day(n).addingTimeInterval(Double(h) * 3600), duration: seconds)
    }

    private func pattern(days: Int, perDay: TimeInterval = 1800, score: Int = 80) -> WorkflowPattern {
        let windows = (0..<days).map { window(day: $0, seconds: perDay) }
        return WorkflowPattern(
            apps: ["Excel", "NetSuite"],
            occurrences: days,
            medianDuration: perDay,
            totalDuration: perDay * Double(days),
            daysObserved: days,
            daysSeen: days,
            automationScore: score,
            sampleTitles: [],
            windows: windows,
            stepLabels: [],
            source: .transfers
        )
    }

    /// The point of the whole change: the same half-hour-a-day routine projects
    /// to the same yearly figure whether it was watched for 2 days or 5.
    func testYearlyFigureIsStableAsMoreDaysAreObserved() {
        let two = pattern(days: 2)
        let five = pattern(days: 5)
        XCTAssertEqual(two.estimatedHoursPerYear, five.estimatedHoursPerYear, accuracy: 0.001)
        XCTAssertEqual(two.estimatedYearlySaving(hourlyRate: 60),
                       five.estimatedYearlySaving(hourlyRate: 60), accuracy: 0.001)
        // Half an hour a working day is 130 hours a year.
        XCTAssertEqual(two.estimatedHoursPerYear, 130, accuracy: 0.001)
    }

    /// A workflow seen on 2 of 6 watched days runs a third as often as one seen
    /// every day, and must be projected at a third of the hours.
    func testOccasionalWorkflowIsNotProjectedAsDaily() {
        var occasional = pattern(days: 2)
        occasional.daysObserved = 6 // the app watched six working days
        let daily = pattern(days: 6)
        XCTAssertEqual(occasional.estimatedHoursPerYear, daily.estimatedHoursPerYear / 3, accuracy: 0.001)
    }

    /// Reliability is about the pattern, not about how long the app ran.
    func testReliabilityFollowsDaysTheWorkWasSeen() {
        var onceOnly = pattern(days: 1)
        onceOnly.daysObserved = 10
        XCTAssertFalse(onceOnly.projectionIsReliable, "seen on one day only")
        var oneWatchedDay = pattern(days: 2)
        oneWatchedDay.daysObserved = 1
        XCTAssertFalse(oneWatchedDay.projectionIsReliable, "only one day watched")
        XCTAssertTrue(pattern(days: 3).projectionIsReliable)
    }

    /// Two patterns covering the SAME minutes must not be added together.
    func testOverlappingPatternsAreCountedOnce() {
        let a = pattern(days: 3)
        var b = pattern(days: 3)
        b.apps = ["Excel", "Salesforce"] // a different pattern, identical windows
        let summed = a.estimatedYearlySaving(hourlyRate: 60) + b.estimatedYearlySaving(hourlyRate: 60)
        let combined = WorkflowPattern.combinedYearlySaving(patterns: [a, b], hourlyRate: 60)
        XCTAssertLessThan(combined, summed * 0.6, "identical windows must not double the headline")
        XCTAssertEqual(combined, a.estimatedYearlySaving(hourlyRate: 60), accuracy: 0.001)
    }

    /// Patterns on different minutes still add up.
    func testDisjointPatternsStillAddUp() {
        let a = pattern(days: 3)
        var b = pattern(days: 3)
        b.apps = ["Mail", "Xero"]
        b.windows = (0..<3).map { window(day: $0, atHour: 14) }
        let combined = WorkflowPattern.combinedYearlySaving(patterns: [a, b], hourlyRate: 60)
        let summed = a.estimatedYearlySaving(hourlyRate: 60) + b.estimatedYearlySaving(hourlyRate: 60)
        XCTAssertEqual(combined, summed, accuracy: 0.001)
    }

    func testMergeWindowsJoinsOverlaps() {
        let t = day(0)
        let merged = WorkflowPattern.mergeWindows([
            DateInterval(start: t, duration: 600),
            DateInterval(start: t.addingTimeInterval(300), duration: 600),
            DateInterval(start: t.addingTimeInterval(5000), duration: 100),
        ])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].duration, 900, accuracy: 0.001)
    }

    /// A day the app barely saw is not a full working day of observation.
    func testThinPartialDayIsNotCountedAsAWatchedDay() {
        func span(day n: Int, hours: Double) -> ActivitySpan {
            let s = day(n).addingTimeInterval(9 * 3600)
            return ActivitySpan(bundleID: "x", appName: "Excel", windowTitle: "Book.xlsx",
                                start: s, end: s.addingTimeInterval(hours * 3600), isDemo: false)
        }
        // Three full days plus this morning's twenty minutes.
        let spans = [span(day: 0, hours: 6), span(day: 1, hours: 6), span(day: 2, hours: 6),
                     span(day: 3, hours: 0.33)]
        XCTAssertEqual(Analytics.workdaysObserved(spans), 3, "the sliver day is not a watched day")
        // If every day is thin we still count them rather than report zero.
        XCTAssertEqual(Analytics.workdaysObserved([span(day: 0, hours: 0.2), span(day: 1, hours: 0.2)]), 2)
    }
}
