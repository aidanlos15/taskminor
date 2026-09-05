import XCTest
@testable import Availeth

final class PatternMinerTests: XCTestCase {

    private func span(_ app: String, minute: Double, duration: Double = 2, title: String = "", dayOffset: Int = 0) -> ActivitySpan {
        let base = Calendar.current.startOfDay(for: Date())
            .addingTimeInterval(TimeInterval(dayOffset) * 86400 + 9 * 3600)
        let start = base.addingTimeInterval(minute * 60)
        return ActivitySpan(
            bundleID: "com.test.\(app)", appName: app, windowTitle: title,
            start: start, end: start.addingTimeInterval(duration * 60)
        )
    }

    /// A sequence repeated 4 times must be discovered with the right count.
    func testDetectsRepeatedSequence() {
        var spans: [ActivitySpan] = []
        var t = 0.0
        let tails = ["Notes", "Calendar", "Finder", "Safari"] // genuinely varying tail
        for i in 0..<4 {
            spans.append(span("Mail", minute: t)); t += 3
            spans.append(span("Preview", minute: t)); t += 3
            spans.append(span("Excel", minute: t)); t += 3
            spans.append(span("Chrome", minute: t)); t += 3
            spans.append(span(tails[i], minute: t)); t += 3
            t += 2
        }
        let patterns = PatternMiner.mine(spans: spans)
        let target = patterns.first { $0.apps == ["Mail", "Preview", "Excel", "Chrome"] }
        XCTAssertNotNil(target, "Expected the Mail→Preview→Excel→Chrome pattern, got: \(patterns.map(\.apps))")
        XCTAssertEqual(target?.occurrences, 4)
    }

    /// A workflow looping back-to-back must be reported once, not once per
    /// cyclic rotation of the sequence.
    func testDedupesCyclicRotations() {
        var spans: [ActivitySpan] = []
        var t = 0.0
        for _ in 0..<6 {
            for app in ["Mail", "Preview", "Excel", "Chrome", "Notes"] {
                spans.append(span(app, minute: t)); t += 3
            }
        }
        let patterns = PatternMiner.mine(spans: spans)
        let fiveApp = patterns.filter { Set($0.apps) == Set(["Mail", "Preview", "Excel", "Chrome", "Notes"]) }
        XCTAssertEqual(fiveApp.count, 1, "Rotations of one cycle should collapse to a single pattern, got: \(fiveApp.map(\.apps))")
    }

    /// Sub-patterns of a discovered longer pattern should be subsumed away.
    func testSubsumesShorterPatterns() {
        var spans: [ActivitySpan] = []
        var t = 0.0
        for _ in 0..<5 {
            for app in ["Mail", "Preview", "Excel", "Chrome"] {
                spans.append(span(app, minute: t)); t += 3
            }
            t += 2
        }
        let patterns = PatternMiner.mine(spans: spans)
        XCTAssertFalse(
            patterns.contains { $0.apps == ["Mail", "Preview", "Excel"] },
            "3-gram subsumed by the 4-gram should not be reported"
        )
    }

    /// Sequences occurring fewer than minOccurrences times must not appear.
    func testIgnoresRareSequences() {
        var spans: [ActivitySpan] = []
        var t = 0.0
        for _ in 0..<2 {
            for app in ["Mail", "Excel", "Chrome"] {
                spans.append(span(app, minute: t)); t += 3
            }
            t += 2
        }
        XCTAssertTrue(PatternMiner.mine(spans: spans).isEmpty)
    }

    /// Single-app runs are not workflows.
    func testRequiresMultipleApps() {
        var spans: [ActivitySpan] = []
        var t = 0.0
        for _ in 0..<10 {
            spans.append(span("Excel", minute: t)); t += 3
        }
        XCTAssertTrue(PatternMiner.mine(spans: spans).isEmpty)
    }

    /// Consecutive same-app spans collapse into one sequence item.
    func testSessionizeCollapsesConsecutiveSameApp() {
        let spans = [
            span("Mail", minute: 0),
            span("Mail", minute: 2.5),
            span("Excel", minute: 5),
        ]
        let sessions = PatternMiner.sessionize(spans)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].map(\.app), ["Mail", "Excel"])
        XCTAssertEqual(sessions[0][0].duration, 4 * 60, accuracy: 1)
    }

    /// A gap larger than sessionGap splits sessions.
    func testSessionizeSplitsOnGap() {
        let spans = [
            span("Mail", minute: 0),
            span("Excel", minute: 3),
            span("Mail", minute: 60), // 55-minute gap
            span("Excel", minute: 63),
        ]
        let sessions = PatternMiner.sessionize(spans)
        XCTAssertEqual(sessions.count, 2)
    }

    /// Noise apps (Slack etc.) are filtered before mining.
    func testNoiseAppsFiltered() {
        let spans = [
            span("Mail", minute: 0),
            span("Slack", minute: 3),
            span("Excel", minute: 6),
        ]
        let sessions = PatternMiner.sessionize(spans)
        XCTAssertEqual(sessions[0].map(\.app), ["Mail", "Excel"])
    }

    /// The demo dataset must contain the invoice workflow, discoverably.
    func testDemoDataYieldsInvoiceWorkflow() {
        let spans = DemoData.generate()
        XCTAssertFalse(spans.isEmpty)
        XCTAssertTrue(spans.allSatisfy(\.isDemo))
        let patterns = PatternMiner.mine(spans: spans)
        XCTAssertFalse(patterns.isEmpty, "Demo data should contain minable workflows")
        // Units now: Excel (not "Microsoft Excel"), and the Chrome/NetSuite tab
        // surfaces as "NetSuite" (not "Chrome") — the whole point of the fix.
        let invoice = patterns.first {
            $0.apps.contains("Mail") && $0.apps.contains("Excel") && $0.apps.contains("NetSuite")
        }
        XCTAssertNotNil(invoice, "Expected the invoice chain (…Excel→NetSuite) in: \(patterns.map(\.apps))")
        XCTAssertGreaterThanOrEqual(invoice?.occurrences ?? 0, 10)
    }

    /// Overlapping patterns must never double-count the same activity:
    /// the summed pattern time can't exceed the stream's total active time.
    func testNoDoubleCountingAcrossPatterns() {
        var spans: [ActivitySpan] = []
        var t = 0.0
        // Interleaved ABGD / ABG / BGD shapes that share segments.
        for _ in 0..<2 {
            for app in ["Alpha", "Beta", "Gamma", "Delta"] { spans.append(span(app, minute: t)); t += 3 }
            t += 2
        }
        for _ in 0..<3 {
            for app in ["Alpha", "Beta", "Gamma"] { spans.append(span(app, minute: t)); t += 3 }
            t += 2
        }
        for _ in 0..<3 {
            for app in ["Beta", "Gamma", "Delta"] { spans.append(span(app, minute: t)); t += 3 }
            t += 2
        }
        let totalActive = spans.reduce(0.0) { $0 + $1.duration }
        let patterns = PatternMiner.mine(spans: spans)
        let summed = patterns.reduce(0.0) { $0 + $1.totalDuration }
        XCTAssertLessThanOrEqual(summed, totalActive + 1, "Patterns double-count shared activity: \(patterns.map { ($0.apps, $0.occurrences) })")
    }

    /// Wrap-around windows of a repeating cycle (e.g. A,B,C,D,A) must not be
    /// reported as patterns of their own.
    func testCyclicWrapDetection() {
        XCTAssertTrue(PatternMiner.isCyclicWrap(["A", "B", "C", "D", "A"], minPeriod: 3))
        XCTAssertTrue(PatternMiner.isCyclicWrap(["A", "B", "C", "A", "B"], minPeriod: 3))
        XCTAssertFalse(PatternMiner.isCyclicWrap(["A", "B", "C", "D"], minPeriod: 3))
        // Short return-loops (Chrome→Excel→Chrome) are legitimate workflows.
        XCTAssertFalse(PatternMiner.isCyclicWrap(["C", "E", "C"], minPeriod: 3))
    }

    /// Score must reward repetition and consistency, and stay in bounds.
    func testScoreBounds() {
        let consistent = PatternMiner.score(apps: ["Mail", "Microsoft Excel", "Google Chrome"], durations: Array(repeating: 300, count: 30))
        let erratic = PatternMiner.score(apps: ["Foo", "Bar", "Baz"], durations: [10, 2000, 30])
        XCTAssertGreaterThan(consistent, erratic)
        XCTAssertLessThanOrEqual(consistent, 98)
        XCTAssertGreaterThanOrEqual(erratic, 5)
    }
}
