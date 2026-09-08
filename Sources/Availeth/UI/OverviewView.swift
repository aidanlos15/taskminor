import Charts
import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var state: AppState
    var range: TimeRange

    // All aggregates are computed once per data change in reload(), never in body.
    @State private var spans: [ActivitySpan] = []
    @State private var patterns: [WorkflowPattern] = []
    @State private var appTotals: [AppTotal] = []
    @State private var tasks: [TaskGroup] = []
    @State private var hourly: [HourlyActivity] = []
    @State private var daily: [DailyTotal] = []
    @State private var totalTime: TimeInterval = 0

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
                                ? "The sample dataset is empty. Reset it from the Privacy tab."
                                : "Availeth is watching for activity. Work normally for a while, or turn on the sample data in the Privacy tab to explore the dashboard."
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
        .onChange(of: range) { reload() }
        .onChange(of: state.showDemo) { reload() }
        .onChange(of: state.dataVersion) { reload() }
    }

    private func reload() {
        let loaded = state.spans(in: range)
        spans = loaded
        patterns = PatternMiner.mine(spans: loaded)
        appTotals = Analytics.timeByApp(loaded)
        tasks = Analytics.taskGroups(loaded)
        hourly = Analytics.hourlyActivity(loaded)
        daily = Analytics.dailyTotals(loaded)
        totalTime = Analytics.totalTime(loaded)
    }

    // MARK: - Stat row

    private var statRow: some View {
        let reliable = patterns.filter(\.projectionIsReliable)
        let potential = reliable.reduce(0.0) { $0 + $1.estimatedYearlySaving(hourlyRate: state.hourlyRate) }

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
                detail: patterns.isEmpty ? "no workflows yet"
                    : (potential > 0 ? "\(patterns.count) workflows detected" : "needs 2+ observed days"),
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

    private var timeByAppCard: some View {
        let top = Array(appTotals.prefix(8))
        return Card(title: "Where the time goes", subtitle: "per application") {
            Chart(top) { item in
                BarMark(
                    x: .value("Hours", item.duration / 3600),
                    y: .value("App", item.appName)
                )
                .foregroundStyle(AppPalette.color(for: item.appName))
                .cornerRadius(3)
                .annotation(position: .trailing, spacing: 6) {
                    Text(Format.duration(item.duration))
                        .font(.system(size: 10.5)).numeric()
                        .foregroundStyle(Theme.ink2)
                }
            }
            .chartYScale(domain: top.map(\.appName))
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks { _ in
                    AxisValueLabel().foregroundStyle(Theme.ink2)
                }
            }
            .frame(height: max(180, CGFloat(top.count) * 32))
        }
    }

    private var hourlyCard: some View {
        let observedHours = hourly.map(\.hour)
        let lower = min(6, observedHours.min() ?? 6)
        let upper = max(21, observedHours.max() ?? 21) + 1
        let apps = Array(Set(hourly.map(\.appName))).sorted()
        return Card(title: "Activity through the day", subtitle: "min / hour") {
            Chart(hourly) { item in
                BarMark(
                    x: .value("Hour", item.hour),
                    y: .value("Minutes", item.duration / 60)
                )
                .foregroundStyle(by: .value("App", item.appName))
                .cornerRadius(2)
            }
            .chartForegroundStyleScale(domain: apps, range: apps.map { AppPalette.color(for: $0) })
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
            .chartLegend(position: .bottom, spacing: 8)
            .frame(height: 220)
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
        let maxDuration = top.first?.duration ?? 1
        return Card(title: "Top tasks", subtitle: "by time") {
            VStack(spacing: 11) {
                ForEach(top) { task in
                    HStack(spacing: 11) {
                        Circle()
                            .fill(AppPalette.color(for: task.appName))
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(task.title)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2).fill(Theme.panelHi).frame(height: 3)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(AppPalette.color(for: task.appName))
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
