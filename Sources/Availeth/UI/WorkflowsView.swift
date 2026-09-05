import SwiftUI

struct WorkflowsView: View {
    @EnvironmentObject private var state: AppState
    var range: TimeRange

    @State private var insights: [WorkflowInsight] = []
    @State private var selected: WorkflowInsight?
    @State private var reloadTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard

                if insights.isEmpty {
                    Card {
                        EmptyState(
                            icon: "arrow.triangle.branch",
                            title: "No repeated workflows detected yet",
                            message: "Availeth looks for cross-app sequences that repeat at least 3 times. Give it a few days of observation, pick a longer range — or switch to Demo data to see what detection looks like."
                        )
                    }
                } else {
                    ForEach(insights, id: \.pattern.id) { insight in
                        WorkflowCard(insight: insight, hourlyRate: state.hourlyRate) { selected = insight }
                    }
                    disclaimer
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onAppear(perform: reload)
        .onChange(of: range) { reload() }
        .onChange(of: state.showDemo) { reload() }
        .onChange(of: state.dataVersion) { reload() }
        .sheet(item: $selected) { insight in
            WorkflowDetailView(insight: insight, hourlyRate: state.hourlyRate)
        }
    }

    /// Mining + insight-building are heavy (n-gram mining plus store queries per
    /// occurrence window), and dataVersion fires on every span save — so this
    /// runs OFF the main thread and debounces bursts, assigning results back on
    /// the main actor. The Store is internally serialized, so background reads
    /// are safe.
    private func reload() {
        reloadTask?.cancel()
        let range = self.range
        let demo = state.showDemo
        let store = state.store
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            let spans = store.spans(from: range.startDate(), to: Date().addingTimeInterval(60), demo: demo)
            let patterns = PatternMiner.mine(spans: spans)
            let built = patterns.map { WorkflowInsighter.build($0, store: store, demo: demo) }
                .sorted { a, b in
                    if a.automatable != b.automatable { return a.automatable }         // real candidates first
                    return a.pattern.automationScore > b.pattern.automationScore
                }
            if Task.isCancelled { return }
            await MainActor.run { self.insights = built }
        }
    }

    private var headerCard: some View {
        // Only genuine automation candidates count toward the headline figure.
        let reliable = insights.filter { $0.automatable && $0.pattern.projectionIsReliable }.map(\.pattern)
        let totalSaving = reliable.reduce(0.0) { $0 + $1.estimatedYearlySaving(hourlyRate: state.hourlyRate) }
        let totalHours = reliable.reduce(0.0) { $0 + $1.estimatedHoursPerYear }
        return Card {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Automation Opportunity Map")
                        .font(.title2.weight(.bold))
                    Text("Tasks you repeat across apps, found automatically. Click any one to see exactly what you did and what a bot could do instead.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !reliable.isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("~" + Format.money(totalSaving) + " / yr")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.purple)
                        Text("\(Format.hours(totalHours)) of repetitive work per year")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !insights.isEmpty {
                    Text("Yearly projections appear\nafter 2+ observed days")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private var disclaimer: some View {
        Text("Estimates are heuristic ranges extrapolated from the observed window at \(Format.money(state.hourlyRate))/hr. Treat them as directional — a real engagement validates each workflow with the people who run it.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

struct WorkflowCard: View {
    var insight: WorkflowInsight
    var hourlyRate: Double
    var onOpen: () -> Void

    private var pattern: WorkflowPattern { insight.pattern }

    var body: some View {
        Button(action: onOpen) {
            Card {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        // Plain-language name + what it is.
                        Text(insight.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(insight.whatItIs)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        // What to automate — the point of the whole card.
                        Label {
                            Text(insight.whatToAutomate)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "wand.and.stars").foregroundStyle(.purple)
                        }

                        chain

                        HStack(spacing: 22) {
                            metric(value: "\(pattern.occurrences)×", label: occurrenceLabel)
                            metric(value: Format.preciseDuration(pattern.medianDuration), label: "median duration")
                            // $ figures only for genuine automation candidates.
                            if insight.automatable && pattern.projectionIsReliable {
                                metric(value: Format.hours(pattern.estimatedHoursPerYear), label: "est. per year")
                                metric(value: "~" + Format.money(pattern.estimatedYearlySaving(hourlyRate: hourlyRate)), label: "potential saving / yr", emphasized: true)
                            } else if !insight.automatable {
                                Text("Likely needs a person")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(Capsule().fill(.quaternary.opacity(0.6)))
                            } else {
                                metric(value: "—", label: "est. per year")
                            }
                        }

                        Label("Click to see the full breakdown", systemImage: "arrow.up.right.square")
                            .font(.caption2).foregroundStyle(.indigo)
                    }
                    Spacer()
                    scoreGauge
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var occurrenceLabel: String {
        pattern.daysObserved > 1 ? "in \(pattern.daysObserved) workdays" : "today"
    }

    private var chain: some View {
        HStack(spacing: 6) {
            ForEach(Array(pattern.apps.enumerated()), id: \.offset) { index, app in
                if index > 0 {
                    Image(systemName: "arrow.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                }
                AppChip(name: app)
            }
        }
    }

    private func metric(value: String, label: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(emphasized ? AnyShapeStyle(Color.purple) : AnyShapeStyle(.primary))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var scoreGauge: some View {
        VStack(spacing: 4) {
            Gauge(value: Double(pattern.automationScore), in: 0...100) {
                EmptyView()
            } currentValueLabel: {
                Text("\(pattern.automationScore)").font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(scoreColor)
            .scaleEffect(1.05)
            Text("automation\nscore").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(width: 76)
    }

    private var scoreColor: Color {
        guard insight.automatable else { return .secondary.opacity(0.5) } // not a candidate → muted
        switch pattern.automationScore {
        case 75...: return .green
        case 50..<75: return .orange
        default: return .secondary.opacity(0.5)
        }
    }
}

// Make WorkflowInsight identifiable for .sheet(item:).
extension WorkflowInsight: Identifiable {
    var id: String { pattern.id }
}
