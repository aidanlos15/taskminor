import SwiftUI

/// The synthesized story: raw signals fused into task-level narratives, each with
/// a read on what could be automated. This is the "what can be automated" view.
struct StoryView: View {
    @EnvironmentObject private var state: AppState
    var range: TimeRange

    @State private var tasks: [TaskSummary] = []
    @State private var minutesByTask: [Int64: [MinuteSummary]] = [:]
    @State private var idleSeconds: TimeInterval = 0
    @State private var expanded: Set<Int64> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard

                if tasks.isEmpty {
                    Card {
                        EmptyState(
                            icon: "book.closed",
                            title: "No story yet",
                            message: state.showDemo
                                ? "The demo story is empty — reset the demo data in the Privacy tab."
                                : "Availeth fuses your captured signals into task summaries every minute or two. Work normally for a few minutes (Storyline mode + the local model give the richest results), or switch to Demo data to see the finished shape."
                        )
                    }
                } else {
                    ForEach(tasks) { task in
                        TaskCard(task: task, isExpanded: expanded.contains(task.id), minutes: minutesByTask[task.id] ?? []) {
                            if expanded.contains(task.id) { expanded.remove(task.id) } else { expanded.insert(task.id) }
                        }
                    }
                    disclaimer
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
        tasks = state.taskSummaries(in: range)
        // Fetch each task's minutes once here, not in the ForEach body on every render.
        var byTask: [Int64: [MinuteSummary]] = [:]
        for task in tasks { byTask[task.id] = state.minutes(forTask: task.id) }
        minutesByTask = byTask
        idleSeconds = state.store.idleSeconds(from: range.startDate(), to: Date().addingTimeInterval(60), demo: state.showDemo)
    }

    private var headerCard: some View {
        let high = tasks.filter { $0.automatable.hasPrefix("High") }.count
        let medium = tasks.filter { $0.automatable.hasPrefix("Medium") }.count
        return Card(title: "Work Story", subtitle: "signals → narrative") {
            HStack(alignment: .center, spacing: 20) {
                Text("Your captured signals — screens, apps, keystrokes, shortcuts, fields — fused into what you actually did, and what a bot could do instead.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 12) {
                        stat("\(tasks.count)", "tasks")
                        stat("\(high)", "high-automatable", Theme.good)
                        stat("\(medium)", "medium", Theme.amber)
                    }
                    if idleSeconds > 60 {
                        Text("\(Format.duration(idleSeconds)) away from keyboard (excluded)")
                            .font(.system(size: 10)).numeric().foregroundStyle(Theme.ink3)
                    }
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String, _ color: Color = Theme.ink) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(value)
                .font(.system(size: 20, weight: .bold)).numeric()
                .foregroundStyle(color)
            Text(label).microLabel()
        }
    }

    private var disclaimer: some View {
        Text("Task stories and automation reads are generated locally from observed signals and are candidates for a human to validate — not a measure of how productive anyone is. Away-from-keyboard time is excluded.")
            .font(.system(size: 11)).foregroundStyle(Theme.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

struct TaskCard: View {
    var task: TaskSummary
    var isExpanded: Bool
    var minutes: [MinuteSummary]
    var toggle: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text("\(task.start.formatted(date: .abbreviated, time: .shortened)) · \(Format.duration(task.duration)) · \(task.minuteCount) min")
                            .font(.system(size: 11)).numeric()
                            .foregroundStyle(Theme.ink3)
                    }
                    Spacer()
                    automatableBadge
                }

                Text(task.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if !task.apps.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(task.apps.components(separatedBy: ", ").prefix(6), id: \.self) { app in
                            AppChip(name: app)
                        }
                    }
                }

                Button(action: toggle) {
                    Label(isExpanded ? "Hide the minute-by-minute" : "Show the minute-by-minute (\(minutes.count))",
                          systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Rectangle().fill(Theme.line).frame(height: 1)
                            .padding(.bottom, 2)
                        ForEach(minutes) { m in
                            HStack(alignment: .top, spacing: 10) {
                                Text(m.minuteStart.formatted(date: .omitted, time: .shortened))
                                    .font(.system(size: 10.5)).numeric().foregroundStyle(Theme.ink2)
                                    .frame(width: 52, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(m.text).font(.system(size: 11)).foregroundStyle(Theme.ink)
                                    if !m.shortcuts.isEmpty || !m.fields.isEmpty {
                                        Text([m.shortcuts, m.fields].filter { !$0.isEmpty }.joined(separator: "  ·  "))
                                            .font(.system(size: 9)).foregroundStyle(Theme.ink3).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.leading, 6)
                    .padding(.top, 2)
                }
            }
        }
    }

    private var automatableBadge: some View {
        let level = task.automatable.components(separatedBy: " — ").first ?? "Low"
        let color: Color = level == "High" ? Theme.good : (level == "Medium" ? Theme.amber : Theme.ink3)
        return VStack(alignment: .trailing, spacing: 3) {
            Text(level)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(color)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.16)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(color.opacity(0.30), lineWidth: 1))
            Text("automatable").microLabel()
        }
    }
}
