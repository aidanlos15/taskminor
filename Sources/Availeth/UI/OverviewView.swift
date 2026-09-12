import Charts
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var state: AppState
    var range: TimeRange

    // All aggregates are computed once per data change in reload(), never in body.
    @State private var spans: [ActivitySpan] = []
    @State private var insights: [WorkflowInsight] = []
    @State private var opportunities: [String: Opportunity] = [:]
    @State private var appTotals: [AppTotal] = []
    @State private var tasks: [TaskGroup] = []
    @State private var hourly: [HourlyActivity] = []
    @State private var hourlyApps: [String] = []
    @State private var daily: [DailyTotal] = []
    @State private var totalTime: TimeInterval = 0
    /// app name → bundle id (for the real icon) and → the logo's primary colour.
    @State private var bundles: [String: String] = [:]
    @State private var colors: [String: Color] = [:]
    @State private var reloadTask: Task<Void, Never>?

    /// Apps shown individually in the hourly chart; the rest fold into "Other".
    private static let legendLimit = 12
    private static let other = "Other"

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                statRow

                if spans.isEmpty {
                    Panel {
                        EmptyState(
                            icon: "binoculars",
                            title: "Nothing observed yet",
                            message: state.showDemo
                                ? "The demo dataset is empty — reset it from the Privacy tab."
                                : "Availeth is watching for activity. Work normally for a while, or switch to Demo data to explore the dashboard."
                        )
                    }
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        timeByAppCard.frame(maxWidth: .infinity)
                        hourlyCard.frame(maxWidth: .infinity)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        dailyTrendCard.frame(maxWidth: .infinity)
                        topTasksCard.frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(20)
        }
        .scrollContentBackground(.hidden)
        .onAppear(perform: reload)
        .onDisappear { reloadTask?.cancel(); reloadTask = nil }
        .onChange(of: range) { reload() }
        .onChange(of: state.showDemo) { reload() }
        .onChange(of: state.dataVersion) { reload() }
    }

    /// Queries, aggregation, the logo prewarm and the colour extraction all run
    /// off the main thread (detached — `View` is @MainActor), landing in one
    /// state update so the charts never wait on disk.
    private func reload() {
        reloadTask?.cancel()
        let range = self.range, demo = state.showDemo, store = state.store
        reloadTask = Task.detached(priority: .userInitiated) {
            let loaded = store.spans(from: range.startDate(), to: Date().addingTimeInterval(60), demo: demo)
            let insights = PatternMiner.mine(spans: loaded).map { WorkflowInsighter.build($0, store: store, demo: demo) }
            let opps = store.opportunities(demo: demo)
            let totals = Analytics.timeByApp(loaded)
            let tasks = Analytics.taskGroups(loaded)
            let (hourly, hourlyApps) = Self.foldHourly(Analytics.hourlyActivity(loaded))
            let daily = Analytics.dailyTotals(loaded)
            if Task.isCancelled { return }

            // Every app on screen: its real icon and the colour of that icon.
            var bundles: [String: String] = [:]
            for s in loaded where bundles[s.appName] == nil { bundles[s.appName] = s.bundleID }
            let names = Set(totals.prefix(8).map(\.appName)).union(hourlyApps).union(tasks.prefix(6).map(\.appName))
            var colors: [String: Color] = [:]
            for name in names {
                let unit = WorkflowUnit.shortApp(name)
                _ = LogoProvider.shared.image(unit: unit, bundleID: bundles[name])
                if let c = LogoProvider.shared.color(unit: unit, bundleID: bundles[name]) { colors[name] = Color(nsColor: c) }
            }
            if Task.isCancelled { return }
            await MainActor.run {
                if Task.isCancelled { return }
                self.spans = loaded; self.insights = insights; self.opportunities = opps; self.appTotals = totals; self.tasks = tasks
                self.hourly = hourly; self.hourlyApps = hourlyApps; self.daily = daily
                self.totalTime = Analytics.totalTime(loaded)
                self.bundles = bundles; self.colors = colors
            }
        }
    }

    /// At most `legendLimit` legend entries INCLUDING "Other": when there are
    /// more apps than that, the top eleven (by minutes) keep their own series
    /// and everything else folds into one "Other" series per hour. Returns the
    /// rows and the series order for the legend.
    static func foldHourly(_ rows: [HourlyActivity]) -> ([HourlyActivity], [String]) {
        var totals: [String: TimeInterval] = [:]
        for r in rows { totals[r.appName, default: 0] += r.duration }
        let ranked = totals.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
        guard ranked.count > legendLimit else { return (rows, ranked) }
        let kept = Array(ranked.prefix(legendLimit - 1))
        let keptSet = Set(kept)
        var out = rows.filter { keptSet.contains($0.appName) }
        var otherByHour: [Int: TimeInterval] = [:]
        for r in rows where !keptSet.contains(r.appName) { otherByHour[r.hour, default: 0] += r.duration }
        out += otherByHour.map { HourlyActivity(hour: $0.key, appName: other, duration: $0.value) }
        return (out.sorted { $0.hour != $1.hour ? $0.hour < $1.hour : $0.appName < $1.appName }, kept + [other])
    }

    // MARK: - Per-app styling

    private func appColor(_ name: String) -> Color {
        if name == Self.other { return Theme.ink3 }
        return colors[name] ?? AppPalette.color(for: name)
    }

    @ViewBuilder
    private func appLogo(_ name: String, size: CGFloat) -> some View {
        if name == Self.other {
            Circle().fill(Theme.ink3.opacity(0.7)).frame(width: size * 0.55, height: size * 0.55).frame(width: size, height: size)
        } else {
            AppLogoView(unit: WorkflowUnit.shortApp(name), bundleID: bundles[name], size: size)
        }
    }

    // MARK: - Stat row

    private var statRow: some View {
        // Priced like the Workflows tab: automatable by evidence, or judged worth an app.
        let priced = insights.compactMap { i -> (WorkflowPattern, Opportunity.Kind)? in
            let k = opportunities["wf:" + i.pattern.id]?.kind ?? (i.automatable ? .integration : .manual)
            return (k == .integration || k == .customApp) ? (i.pattern, k) : nil
        }
        let candidates = priced.map(\.0)
        let potential = priced.reduce(0.0) { $0 + $1.0.estimatedYearlySaving(hourlyRate: state.hourlyRate, minimumScore: $1.1 == .customApp ? Opportunity.customAppFloorScore : 0) }

        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
            StatCard(
                icon: "clock", value: Format.duration(totalTime),
                label: "Time observed", detail: rangeLabel
            )
            StatCard(
                icon: "square.grid.3x3", value: "\(appTotals.count)",
                label: "Applications", detail: "distinct apps used"
            )
            StatCard(
                icon: "checklist", value: "\(tasks.count)",
                label: "Tasks", detail: "grouped by window"
            )
            StatCard(
                icon: "sparkles",
                value: potential > 0 ? "~" + Format.money(potential) : "—",
                label: "Automation potential",
                detail: insights.isEmpty ? "no workflows yet"
                    : (candidates.contains { !$0.projectionIsReliable }
                        ? "\(candidates.count) automatable \u{00B7} first read, 1 observed day"
                        : "\(insights.count) workflow\(insights.count == 1 ? "" : "s") \u{00B7} \(candidates.count) automatable"),
                accent: potential > 0
            )
        }
    }

    private var rangeLabel: String {
        switch range {
        case .today: return "since midnight"
        case .week: return "last 7 days"
        case .twoWeeks: return "last 14 days"
        }
    }

    // MARK: - Charts

    /// Horizontal bars, one per app: the app's icon beside its name, the bar in
    /// the icon's own colour, the total right after the bar.
    private var timeByAppCard: some View {
        let top = Array(appTotals.prefix(8))
        let maxDuration = max(top.first?.duration ?? 1, 1)
        return Card(title: "Where the time goes", subtitle: "per application") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(top) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            appLogo(item.appName, size: 20)
                            Text(item.appName)
                                .font(.system(size: 12.5)).foregroundStyle(Theme.ink2).lineLimit(1)
                        }
                        GeometryReader { geo in
                            let width = max(4, (geo.size.width - 56) * item.duration / maxDuration)
                            HStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(appColor(item.appName))
                                    .frame(width: width, height: 9)
                                Text(Format.duration(item.duration))
                                    .font(.system(size: 10.5)).numeric()
                                    .foregroundStyle(Theme.ink2)
                                    .fixedSize()
                            }
                        }
                        .frame(height: 12)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    /// Stacked minutes per hour; the top apps get their own colour and a legend
    /// entry with their icon, the long tail is one grey "Other".
    private var hourlyCard: some View {
        let observedHours = hourly.map(\.hour)
        let lower = min(6, observedHours.min() ?? 6)
        let upper = max(21, observedHours.max() ?? 21) + 1
        return Card(title: "Activity through the day", subtitle: "min / hour") {
            Chart(hourly) { item in
                BarMark(
                    x: .value("Hour", item.hour),
                    y: .value("Minutes", item.duration / 60)
                )
                .foregroundStyle(by: .value("App", item.appName))
                .cornerRadius(2)
            }
            .chartForegroundStyleScale(domain: hourlyApps, range: hourlyApps.map { appColor($0) })
            .chartXScale(domain: lower...upper)
            .chartXAxis {
                AxisMarks(values: Array(stride(from: lower, through: upper, by: 3))) { value in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel {
                        if let h = value.as(Int.self) { Text("\(h):00") }
                    }
                    .foregroundStyle(Theme.ink3)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Theme.line)
                    AxisValueLabel().foregroundStyle(Theme.ink3)
                }
            }
            .chartLegend(.hidden)
            .frame(height: 190)

            // Our own legend: the icon IS the colour key — capped at the top apps.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 9) {
                ForEach(hourlyApps, id: \.self) { name in
                    HStack(spacing: 6) {
                        appLogo(name, size: 19)
                        Text(name).font(.system(size: 11.5)).foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private var dailyTrendCard: some View {
        Card(title: "Daily observed time", subtitle: "per day") {
            if daily.count <= 1 {
                EmptyState(icon: "calendar", title: "Not enough days yet", message: "Switch to a longer range to see the trend.")
            } else {
                Chart(daily) { day in
                    BarMark(
                        x: .value("Day", day.day, unit: .day),
                        y: .value("Hours", day.duration / 3600)
                    )
                    .foregroundStyle(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.55)],
                                                    startPoint: .top, endPoint: .bottom))
                    .cornerRadius(3)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { _ in
                        AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                            .foregroundStyle(Theme.ink3)
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisGridLine().foregroundStyle(Theme.line)
                        AxisValueLabel().foregroundStyle(Theme.ink3)
                    }
                }
                .frame(height: 200)
            }
        }
    }

    private var topTasksCard: some View {
        let top = Array(tasks.prefix(6))
        let maxDuration = max(top.first?.duration ?? 1, 1)
        return Card(title: "Top tasks", subtitle: "by time") {
            VStack(spacing: 11) {
                ForEach(top) { task in
                    HStack(spacing: 10) {
                        appLogo(task.appName, size: 21)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(task.title)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2).fill(Theme.panelHi).frame(height: 3)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(appColor(task.appName))
                                        .frame(width: max(4, geo.size.width * task.duration / maxDuration), height: 3)
                                }
                            }
                            .frame(height: 3)
                        }
                        Spacer()
                        Text(Format.duration(task.duration))
                            .font(.system(size: 11)).numeric()
                            .foregroundStyle(Theme.ink3)
                    }
                }
            }
        }
    }
}
