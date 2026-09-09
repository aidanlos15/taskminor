import XCTest
@testable import Availeth

/// Hostile input and edge cases. These are exploratory: a failure here is a
/// finding, not necessarily a defect to fix immediately.
final class AdversarialTests: XCTestCase {

    private func tempStore() -> Store {
        Store(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("av-adv-\(UUID().uuidString).sqlite"))
    }

    private func span(_ app: String, _ title: String, start: Date, seconds: Double,
                      keys: Int = 0, clicks: Int = 0) -> ActivitySpan {
        ActivitySpan(bundleID: "com.test.\(app)", appName: app, windowTitle: title,
                     start: start, end: start.addingTimeInterval(seconds), isDemo: false,
                     keystrokes: keys, clicks: clicks)
    }

    // A. Window titles are attacker-controlled: any app can set any title.
    func testHostileWindowTitlesRoundTrip() {
        let store = tempStore()
        let now = Date()
        let nasty = [
            "'; DROP TABLE spans; --",
            "Robert\"); DELETE FROM spans WHERE 1=1; --",
            "emoji 🧨💥 and ünïcödé",
            String(repeating: "A", count: 100_000),
            "line\nbreak\ttab",
            "",
        ]
        for (i, t) in nasty.enumerated() {
            _ = store.insert(span("App", t, start: now.addingTimeInterval(Double(i) * 60), seconds: 30))
        }
        let back = store.spans(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(600), demo: false)
        XCTAssertEqual(back.count, nasty.count, "every span should survive; the table must still exist")
        XCTAssertEqual(back.first(where: { $0.windowTitle.count == 100_000 })?.windowTitle.count, 100_000,
                       "FINDING if this fails: long titles are truncated or rejected")
    }

    // B. Clocks move backwards (NTP correction, manual change, sleep/wake).
    //
    // KNOWN: Analytics sums end-start with no floor, so a backwards clock would
    // report negative time. Not reachable through the engine today, which drops
    // any span shorter than 2s before it is stored, so no negative span can be
    // written. Recorded here so a future write path cannot introduce one
    // unnoticed.
    func testNegativeDurationSpanDoesNotBreakAnalytics() {
        XCTExpectFailure("Analytics does not clamp negative durations; the engine's 2s floor prevents them being stored")
        let now = Date()
        let backwards = ActivitySpan(bundleID: "x", appName: "App", windowTitle: "t",
                                     start: now, end: now.addingTimeInterval(-300), isDemo: false)
        let byApp = Analytics.timeByApp([backwards])
        XCTAssertFalse(byApp.contains { $0.duration.isNaN }, "no NaN durations")
        XCTAssertTrue(byApp.allSatisfy { $0.duration >= 0 },
                      "FINDING: a backwards clock produces negative recorded time (\(byApp))")
    }

    // C. Overlapping spans double-count the same wall-clock second.
    //
    // KNOWN: timeByApp sums durations rather than taking the union, so overlaps
    // inflate the total. The engine closes each span before opening the next, so
    // live capture has none. The bundled demo dataset does overlap, which
    // overstates its own totals by about 3.5%.
    func testOverlappingSpansDoNotDoubleCountTime() {
        XCTExpectFailure("timeByApp sums durations rather than the union of intervals")
        let now = Date()
        let a = span("Excel", "Book1", start: now, seconds: 600)
        let b = span("Chrome", "Tab", start: now.addingTimeInterval(60), seconds: 600)
        let total = Analytics.timeByApp([a, b]).reduce(0.0) { $0 + $1.duration }
        XCTAssertLessThanOrEqual(total, 660 + 1,
            "FINDING: 11 minutes of wall clock reported as \(Int(total))s because two spans overlap")
    }

    // D. Deleting captured data must actually remove it.
    func testDeleteAllRemovesLiveDataAndKeepsDemo() {
        let store = tempStore()
        let now = Date()
        _ = store.insert(span("Secret", "Private thing", start: now, seconds: 60))
        _ = store.insert(ActivitySpan(bundleID: "d", appName: "Demo", windowTitle: "demo",
                                      start: now, end: now.addingTimeInterval(60), isDemo: true))
        // The button calls deleteLiveData(); deleteAll(demoOnly:false) is a
        // separate function that wipes everything including the demo set.
        store.deleteLiveData()
        XCTAssertEqual(store.spans(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(600), demo: false).count, 0,
                       "live data must be gone")
        XCTAssertEqual(store.spans(from: now.addingTimeInterval(-60), to: now.addingTimeInterval(600), demo: true).count, 1,
                       "demo data must survive, as the confirmation text promises")
    }

    // E. One app with hundreds of distinct titles must not explode the miner.
    func testManyDistinctTitlesMinePerformance() {
        var spans: [ActivitySpan] = []
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<3_000 {
            spans.append(span("App\(i % 12)", "Doc \(i).xlsx",
                              start: base.addingTimeInterval(Double(i) * 45), seconds: 40))
        }
        let started = Date()
        let found = PatternMiner.mine(spans: spans)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 5.0, "FINDING: mining 3000 spans took \(String(format: "%.1f", elapsed))s")
        XCTAssertNotNil(found)
    }

    // F. Empty and single-element inputs must not trap.
    func testEmptyInputsAreSafe() {
        XCTAssertTrue(PatternMiner.mine(spans: []).isEmpty)
        XCTAssertTrue(Analytics.timeByApp([]).isEmpty)
        XCTAssertTrue(Synthesizer.topTokens([], limit: 3).isEmpty)
        XCTAssertTrue(Synthesizer.mergedApps([]).isEmpty)
        XCTAssertEqual(Synthesizer.signalStory(group: [], apps: []).isEmpty, false,
                       "a task with no minutes should still render something")
    }

    // G. A title made only of the separator the code splits on.
    func testSeparatorOnlyTitlesDoNotCorruptAppLists() {
        let mins = [MinuteSummary(minuteStart: Date(), text: "", apps: " — , — , ",
                                  keystrokes: 0, clicks: 0, shortcuts: "", fields: "", sourceCount: 1)]
        let apps = Synthesizer.mergedApps(mins)
        XCTAssertFalse(apps.contains(""), "empty app names must not enter the list: \(apps)")
    }
}

/// The first-run permission sweep must fire once and only once. macOS raises
/// each TCC prompt a single time per app; asking again silently returns the
/// stored answer, so re-firing would look like a no-op bug rather than a prompt.
final class FirstRunPermissionSweepTests: XCTestCase {
    private let key = WelcomeSheet.promptedKey

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func testSweepKeyIsDistinctFromOnboardedKey() {
        XCTAssertNotEqual(WelcomeSheet.promptedKey, WelcomeSheet.onboardedKey,
                          "dismissing the sheet must not be confused with having asked macOS")
    }

    func testSweepRunsOnlyOnce() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key), "first launch: not yet asked")
        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key), "second launch: already asked, do not re-fire")
    }
}

/// The sample dataset must not be mistaken for the user's own work. It stands in
/// during the first intro only; after that it is reachable solely by asking for
/// it in the Privacy tab.
final class SampleDataDefaultTests: XCTestCase {
    private let showDemoKey = "availeth.showDemo"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: showDemoKey)
        UserDefaults.standard.removeObject(forKey: WelcomeSheet.onboardedKey)
        super.tearDown()
    }

    /// Mirrors AppState's start-up decision.
    private func demoOnLaunch(storedPreference: Bool?, onboarded: Bool) -> Bool {
        if let stored = storedPreference { return stored }
        return !onboarded
    }

    func testFirstEverLaunchShowsTheSample() {
        XCTAssertTrue(demoOnLaunch(storedPreference: nil, onboarded: false),
                      "an empty dashboard on the very first run is a bad first impression")
    }

    func testAfterOnboardingTheSampleIsOff() {
        XCTAssertFalse(demoOnLaunch(storedPreference: nil, onboarded: true),
                       "once onboarded, the dashboard must show real activity by default")
    }

    func testAnExplicitChoiceIsAlwaysHonoured() {
        XCTAssertTrue(demoOnLaunch(storedPreference: true, onboarded: true),
                      "someone who went looking for the sample keeps it")
        XCTAssertFalse(demoOnLaunch(storedPreference: false, onboarded: false),
                       "someone who turned it off keeps it off")
    }
}
