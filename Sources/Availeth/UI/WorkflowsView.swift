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
    @State private var segments: [RecordingSegment] = []
    @State private var opportunities: [String: Opportunity] = [:]
    @State private var selected: WorkflowInsight?

    /// The judgement for a workflow: the model's when it has one, else the
    /// evidence-based automatable read.
    private func kind(_ insight: WorkflowInsight) -> Opportunity.Kind {
        opportunities["wf:" + insight.pattern.id]?.kind ?? (insight.automatable ? .integration : .manual)
    }
    /// Priced when there is something to build or automate.
    private func priced(_ insight: WorkflowInsight) -> Bool {
        let k = kind(insight)
        return k == .integration || k == .customApp
    }
    private func saving(_ insight: WorkflowInsight) -> Double {
        insight.pattern.estimatedYearlySaving(hourlyRate: state.hourlyRate, minimumScore: kind(insight) == .customApp ? Opportunity.customAppFloorScore : 0)
    }
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
                               bundles: bundles, sites: sites, segments: segments,
                               opportunity: opportunities["wf:" + insight.pattern.id])
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
        let rate = state.hourlyRate
        reloadTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            let spans = store.spans(from: range.startDate(), to: Date().addingTimeInterval(60), demo: demo)
            let patterns = PatternMiner.mine(spans: spans)
            let built = patterns.map { WorkflowInsighter.build($0, store: store, demo: demo) }
            let map = LogoProvider.bundleMap(spans)
            let siteMap = LogoProvider.siteMap(spans)
            LogoProvider.shared.prewarm(units: Array(Set(built.flatMap { $0.pattern.apps })), bundles: map, sites: siteMap)
            let recs = demo ? [] : store.recordings(from: range.startDate(), to: Date().addingTimeInterval(60))
            let opps = store.opportunities(demo: demo)
            let ordered = built.sorted { a, b in
                func rank(_ i: WorkflowInsight) -> Int {
                    switch opps["wf:" + i.pattern.id]?.kind ?? (i.automatable ? .integration : .manual) {
                    case .integration: return 0
                    case .customApp: return 0
                    case .streamline: return 1
                    case .manual: return 2
                    }
                }
                if rank(a) != rank(b) { return rank(a) < rank(b) }
                // Within a rank, by the number actually shown.
                func money(_ i: WorkflowInsight) -> Double {
                    let k = opps["wf:" + i.pattern.id]?.kind ?? (i.automatable ? .integration : .manual)
                    return i.pattern.estimatedYearlySaving(hourlyRate: rate, minimumScore: k == .customApp ? Opportunity.customAppFloorScore : 0)
                }
                if rank(a) == 0, money(a) != money(b) { return money(a) > money(b) }
                return a.pattern.automationScore > b.pattern.automationScore
            }
            if Task.isCancelled { return }
            await MainActor.run { self.insights = ordered; self.bundles = map; self.sites = siteMap; self.segments = recs; self.opportunities = opps }
        }
    }

    // MARK: - The map

    private var automatable: [WorkflowPattern] {
        insights.filter { priced($0) }.map(\.pattern)
    }

    private var mapPanel: some View {
        let totalSaving = insights.filter { priced($0) }.reduce(0.0) { $0 + saving($1) }
        let firstRead = automatable.contains { !$0.projectionIsReliable }
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
                    if automatable.isEmpty {
                        Text("No automatable workflow yet")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink3)
                    } else {
                        VStack(alignment: .trailing, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text("~" + Format.money(totalSaving))
                                    .font(.system(size: 22, weight: .bold)).numeric()
                                    .foregroundStyle(Theme.ink)
                                Text("/yr").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                            }
                            if firstRead {
                                Text("first read \u{2014} projected from one observed day")
                                    .font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
                            }
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
        let auto = insights.filter { kind($0) == .integration }.count
        let apps = insights.filter { kind($0) == .customApp }.count
        var parts = ["\(n) workflow\(n == 1 ? "" : "s")", "\(auto) automatable"]
        if apps > 0 { parts.append("\(apps) worth a custom app") }
        parts.append("at \(Format.money(state.hourlyRate))/h")
        return parts.joined(separator: " \u{00B7} ")
    }

    private func row(_ insight: WorkflowInsight, index: Int) -> some View {
        let p = insight.pattern
        let priced = priced(insight)
        let opp = opportunities["wf:" + p.id]
        return Button { selected = insight } label: {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(insight.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if let opp, opp.kind == .customApp || opp.kind == .integration {
                        Text(opp.headline)
                            .font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(1)
                    }
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
                            Text("~" + Format.money(saving(insight)))
                                .font(.system(size: 18, weight: .bold)).numeric()
                                .foregroundStyle(Theme.ink)
                            Text("/yr").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                        }
                    } else {
                        Text("\u{2014}").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink3)
                    }
                    OpportunityPill(kind: kind(insight))
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
