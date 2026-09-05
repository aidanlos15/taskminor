import XCTest
@testable import Availeth

final class AnalyticsTests: XCTestCase {

    private func span(app: String, title: String = "", startMinute: Double, duration: Double) -> ActivitySpan {
        let base = Calendar.current.startOfDay(for: Date()).addingTimeInterval(9 * 3600)
        let start = base.addingTimeInterval(startMinute * 60)
        return ActivitySpan(
            bundleID: "com.test.\(app)", appName: app, windowTitle: title,
            start: start, end: start.addingTimeInterval(duration * 60)
        )
    }

    func testTimeByApp() {
        let spans = [
            span(app: "Excel", startMinute: 0, duration: 10),
            span(app: "Excel", startMinute: 20, duration: 5),
            span(app: "Mail", startMinute: 30, duration: 8),
        ]
        let totals = Analytics.timeByApp(spans)
        XCTAssertEqual(totals.count, 2)
        XCTAssertEqual(totals[0].appName, "Excel")
        XCTAssertEqual(totals[0].duration, 15 * 60, accuracy: 1)
        XCTAssertEqual(totals[0].spanCount, 2)
    }

    func testTitleNormalizationStripsAppSuffixes() {
        XCTAssertEqual(
            Analytics.normalizeTitle("Purchase Orders.xlsx — Microsoft Excel", appName: "Microsoft Excel"),
            "Purchase Orders.xlsx"
        )
        XCTAssertEqual(
            Analytics.normalizeTitle("Vendor Bills — NetSuite - Google Chrome", appName: "Google Chrome"),
            "Vendor Bills — NetSuite"
        )
        XCTAssertEqual(Analytics.normalizeTitle("Inbox (42)", appName: "Mail"), "Inbox")
        XCTAssertEqual(Analytics.normalizeTitle("", appName: "Mail"), "General Mail usage")
    }

    func testTaskGroupsMergeNormalizedTitles() {
        let spans = [
            span(app: "Microsoft Excel", title: "Purchase Orders.xlsx — Microsoft Excel", startMinute: 0, duration: 10),
            span(app: "Microsoft Excel", title: "Purchase Orders.xlsx", startMinute: 20, duration: 5),
        ]
        let groups = Analytics.taskGroups(spans)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].sessions, 2)
        XCTAssertEqual(groups[0].duration, 15 * 60, accuracy: 1)
    }

    func testHourlySplitsAcrossHourBoundary() {
        // 9:30–10:30 → 30 min in hour 9, 30 min in hour 10.
        let spans = [span(app: "Excel", startMinute: 30, duration: 60)]
        let hourly = Analytics.hourlyActivity(spans)
        XCTAssertEqual(hourly.count, 2)
        XCTAssertEqual(hourly.first { $0.hour == 9 }?.duration ?? 0, 30 * 60, accuracy: 2)
        XCTAssertEqual(hourly.first { $0.hour == 10 }?.duration ?? 0, 30 * 60, accuracy: 2)
    }

    func testDaysObserved() {
        let today = span(app: "Excel", startMinute: 0, duration: 5)
        var yesterday = today
        yesterday.start = today.start.addingTimeInterval(-86400)
        yesterday.end = today.end.addingTimeInterval(-86400)
        XCTAssertEqual(Analytics.daysObserved([today, yesterday]), 2)
    }
}
