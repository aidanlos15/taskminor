import SwiftUI

/// The Automation Opportunity Map: every repeated cross-app workflow as one row —
/// name, the apps it moves through (real logos, data flowing between them), how
/// often and how long, and what it's worth per year if a machine did it.
struct WorkflowsView: View {
    @EnvironmentObject private var state: AppState
    var range: TimeRange

    @State private var insights: [WorkflowInsight] = []
    @State private var bundles: [String: String] = [:]
    @State private var sites: [String: String] = [:]
    @State private var selected: WorkflowInsight?
    @State private var reloadTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                mapPanel
                if !insights.isEmpty { disclaimer }
            }
            .padding(20)
        }
        .scrollContentBackground(.hidden)
        .onAppear(perform: reload)
        .onDisappear { reloadTask?.cancel(); reloadTask = nil }
        .onChange(of: range) { reload() }
        .onChange(of: state.showDemo) { reload() }
        .onChange(of: state.dataVersion) { reload() }
        .sheet(item: $selected) { insight in
            WorkflowDetailView(insight: insight, hourlyRate: state.hourlyRate,
                               storylineOn: state.engine.screenshotMode == .storyline,
                               bundles: bundles, sites: sites)
        }
    }

    /// Mining + insight-building are heavy and dataVersion fires on every span
    /// save — so this runs OFF the main thread, debounced, and also warms the
    /// logo cache there so rows never touch disk while rendering. It must be a
    /// DETACHED task: `View` is @MainActor, so a plain `Task {}` here would
    /// inherit the main actor and run all of this on the UI thread.
    private func reload() {
        reloadTask?.cancel()
        let range = self.range
        let demo = state.showDemo
        let store = state.store
        reloadTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            let spans = store.spans(from: range.startDate(), to: Date().addingTimeInterval(60), demo: demo)
            let patterns = PatternMiner.mine(spans: spans)
            let built = patterns.map { WorkflowInsighter.build($0, store: store, demo: demo) }
                .sorted { a, b in
                    if a.automatable != b.automatable { return a.automatable }         // real candidates first
                    return a.pattern.automationScore > b.pattern.automationScore
                }
            let map = LogoProvider.bundleMap(spans)
            let siteMap = LogoProvider.siteMap(spans)
            LogoProvider.shared.prewarm(units: Array(Set(built.flatMap { $0.pattern.apps })), bundles: map, sites: siteMap)
            if Task.isCancelled { return }
            await MainActor.run { self.insights = built; self.bundles = map; self.sites = siteMap }
        }
    }

    // MARK: - The map

    private var reliable: [WorkflowPattern] {
        insights.filter { $0.automatable && $0.pattern.projectionIsReliable }.map(\.pattern)
    }

    private var mapPanel: some View {
        let totalSaving = reliable.reduce(0.0) { $0 + $1.estimatedYearlySaving(hourlyRate: state.hourlyRate) }
        return VStack(spacing: 0) {
            // Header
            HStack(alignment: .center, spacing: 12) {
                Text("Automation Opportunity Map")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                HeaderBadge(text: state.showDemo ? "Example \u{00B7} demo data" : "\(range.rawValue) \u{00B7} your Mac")
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            hairline

            if insights.isEmpty {
                EmptyState(
                    icon: "arrow.triangle.branch",
                    title: "No repeated workflows yet",
                    message: "Availeth looks for cross-app sequences that repeat at least 3 times. Give it a few days, pick a longer range, or switch to Demo data to see what a map looks like."
                )
                .padding(.horizontal, 18)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(insights.enumerated()), id: \.element.pattern.id) { index, insight in
                        row(insight, index: index)
                        hairline
                    }
                }
                // Footer: the headline number
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(footerCaption)
                        .font(.system(size: 12)).numeric()
                        .foregroundStyle(Theme.ink3)
                    Spacer()
                    if reliable.isEmpty {
                        Text("Yearly projections appear after 2+ observed days")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink3)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text("~" + Format.money(totalSaving))
                                .font(.system(size: 22, weight: .bold)).numeric()
                                .foregroundStyle(Theme.ink)
                            Text("/yr").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
            }
        }
        .panelSkin()
    }

    private var footerCaption: String {
        let n = insights.count
        let auto = insights.filter(\.automatable).count
        return "\(n) workflow\(n == 1 ? "" : "s") \u{00B7} \(auto) automatable \u{00B7} at \(Format.money(state.hourlyRate))/h"
    }

    private func row(_ insight: WorkflowInsight, index: Int) -> some View {
        let p = insight.pattern
        let priced = insight.automatable && p.projectionIsReliable
        return Button { selected = insight } label: {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(insight.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    UnitChain(units: p.apps, bundles: bundles, sites: sites, stagger: Double(index) * 0.35, animating: selected == nil)
                    HStack(spacing: 5) {
                        Text("\(p.occurrences)\u{00D7}").font(.system(size: 12, weight: .semibold)).numeric().foregroundStyle(Theme.ink2)
                        Text(p.daysObserved > 1 ? "in \(p.daysObserved) workdays" : "today").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                        Text("\u{00B7}").foregroundStyle(Theme.ink3)
                        Text("median").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                        Text(Format.preciseDuration(p.medianDuration)).font(.system(size: 12, weight: .semibold)).numeric().foregroundStyle(Theme.ink2)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 7) {
                    if priced {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(Format.money(p.estimatedYearlySaving(hourlyRate: state.hourlyRate)))
                                .font(.system(size: 18, weight: .bold)).numeric()
                                .foregroundStyle(Theme.ink)
                            Text("/yr").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                        }
                    } else {
                        Text("\u{2014}").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink3)
                    }
                    AutomationPill(automatable: insight.automatable)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("See the full breakdown")
    }

    private var hairline: some View { Rectangle().fill(Theme.line).frame(height: 1) }

    private var disclaimer: some View {
        Text("Estimates are heuristic ranges extrapolated from the observed window at \(Format.money(state.hourlyRate))/hr. Treat them as directional \u{2014} a real engagement validates each workflow with the people who run it.")
            .font(.system(size: 11)).numeric()
            .foregroundStyle(Theme.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

// Make WorkflowInsight identifiable for .sheet(item:).
extension WorkflowInsight: Identifiable {
    var id: String { pattern.id }
}
