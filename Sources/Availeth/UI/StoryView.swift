import SwiftUI

/// The synthesized story: raw signals fused into task-level narratives, each with
/// a read on what could be automated. Collapsed cards are one glance — logo,
/// title, a single line, a level — and open into a structured account.
struct StoryView: View {
    @EnvironmentObject private var state: AppState
    var range: TimeRange

    @State private var tasks: [TaskSummary] = []
    @State private var minutesByTask: [Int64: [MinuteSummary]] = [:]
    @State private var bundles: [String: String] = [:]
    @State private var sites: [String: String] = [:]
    @State private var segments: [RecordingSegment] = []
    @State private var opportunities: [String: Opportunity] = [:]
    @State private var idleSeconds: TimeInterval = 0
    @State private var expanded: Set<Int64> = []
    @State private var reloadTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                headerPanel
                if tasks.isEmpty {
                    EmptyState(
                        icon: "book.closed",
                        title: "No story yet",
                        message: state.showDemo
                            ? "The demo story is empty \u{2014} reset the demo data in the Privacy tab."
                            : "Availeth fuses your captured signals into task summaries every minute or two. Work normally for a few minutes (Screen capture on gives the richest results), or switch to Demo data to see the finished shape."
                    )
                    .panelSkin()
                } else {
                    ForEach(tasks) { task in
                        StoryCard(task: task,
                                  minutes: minutesByTask[task.id] ?? [],
                                  bundles: bundles,
                                  sites: sites,
                                  segments: segments,
                                  opportunity: opportunities["task:\(task.id)"],
                                  isExpanded: expanded.contains(task.id)) {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                if expanded.contains(task.id) { expanded.remove(task.id) } else { expanded.insert(task.id) }
                            }
                        }
                    }
                    disclaimer
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

    /// All queries (summaries, one minutes query per task, idle time, spans for
    /// the logo map) run off the main thread, then land in one state update.
    private func reload() {
        reloadTask?.cancel()
        let range = self.range, demo = state.showDemo, store = state.store
        reloadTask = Task.detached(priority: .userInitiated) {
            let to = Date().addingTimeInterval(60)
            let summaries = store.taskSummaries(from: range.startDate(), to: to, demo: demo)
            if Task.isCancelled { return }
            var byTask: [Int64: [MinuteSummary]] = [:]
            for t in summaries {
                if Task.isCancelled { return }
                byTask[t.id] = store.minutesForTask(t.id)
            }
            let idle = store.idleSeconds(from: range.startDate(), to: to, demo: demo)
            let spans = store.spans(from: range.startDate(), to: to, demo: demo)
            let map = LogoProvider.bundleMap(spans)
            let siteMap = LogoProvider.siteMap(spans)
            let units = Set(summaries.flatMap { StoryCard.units($0.apps) })
            LogoProvider.shared.prewarm(units: Array(units), bundles: map, sites: siteMap)
            let recs = demo ? [] : store.recordings(from: range.startDate(), to: to)
            let opps = store.opportunities(demo: demo)
            if Task.isCancelled { return }
            let minutes = byTask
            await MainActor.run {
                if Task.isCancelled { return }
                self.tasks = summaries; self.minutesByTask = minutes
                self.idleSeconds = idle; self.bundles = map; self.sites = siteMap; self.segments = recs; self.opportunities = opps
            }
        }
    }

    // MARK: - Header

    private var headerPanel: some View {
        let high = tasks.filter { $0.automatable.hasPrefix("High") }.count
        let medium = tasks.filter { $0.automatable.hasPrefix("Medium") }.count
        return HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    Text("Work Story").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    HeaderBadge(text: state.showDemo ? "Example \u{00B7} demo data" : "\(range.rawValue) \u{00B7} your Mac")
                }
                Text("What you actually did, task by task, and what a bot could do instead.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 18) {
                    stat("\(tasks.count)", "tasks")
                    stat("\(high)", "high", Theme.good)
                    stat("\(medium)", "medium", Theme.amber)
                }
                if idleSeconds > 60 {
                    Text("\(Format.duration(idleSeconds)) away from keyboard, excluded")
                        .font(.system(size: 10.5)).numeric().foregroundStyle(Theme.ink3)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .panelSkin()
    }

    private func stat(_ value: String, _ label: String, _ color: Color = Theme.ink) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value).font(.system(size: 20, weight: .bold)).numeric().foregroundStyle(color)
            Text(label).microLabel()
        }
    }

    private var disclaimer: some View {
        Text("Task stories and automation reads are generated locally from observed signals and are candidates for a human to validate \u{2014} not a measure of how productive anyone is. Away-from-keyboard time is excluded.")
            .font(.system(size: 11)).foregroundStyle(Theme.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

/// One task. Collapsed: logo tile, title, when/how long, a one-line summary,
/// the apps, and a level pill. Expanded: the structured story, the automation
/// read, and a numbered minute-by-minute.
struct StoryCard: View {
    var task: TaskSummary
    var minutes: [MinuteSummary]
    var bundles: [String: String]
    var sites: [String: String] = [:]
    var segments: [RecordingSegment] = []
    var opportunity: Opportunity? = nil
    var isExpanded: Bool

    private var taskInterval: DateInterval { DateInterval(start: task.start, end: max(task.start, task.end)) }
    private var recorded: Bool { Recordings.hasRecording(for: taskInterval, segments: segments) }
    var toggle: () -> Void

    /// "Google Chrome, Claude" → ["Chrome", "Claude"] — the same unit labels the
    /// logos are keyed by. Nonisolated: the reload calls it off the main actor.
    nonisolated static func units(_ apps: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for raw in apps.components(separatedBy: ",") {
            let u = WorkflowUnit.shortApp(raw.trimmingCharacters(in: .whitespaces))
            if !u.isEmpty, !seen.contains(u) { seen.insert(u); out.append(u) }
        }
        return out
    }

    private var units: [String] { Self.units(task.apps) }
    private var title: String { StoryFormat.plain(task.title) }
    private var summary: String { StoryFormat.summary(task.text) }
    private var read: (level: String, reason: String) { StoryFormat.level(task.automatable) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: 14) {
                    // The primary app's real logo.
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panelHi)
                        if let first = units.first {
                            AppLogoView(unit: first, bundleID: bundles[first], site: sites[first], size: 24)
                        } else {
                            Image(systemName: "book.closed").foregroundStyle(Theme.ink3)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(isExpanded ? nil : 1)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(task.start.formatted(date: .abbreviated, time: .shortened)) \u{00B7} \(Format.duration(task.duration))")
                            .font(.system(size: 11.5)).numeric()
                            .foregroundStyle(Theme.ink3)
                        if !summary.isEmpty {
                            Text(summary)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Theme.ink2)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !units.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(units.prefix(5), id: \.self) { u in
                                    LogoChip(unit: u, bundleID: bundles[u], site: sites[u])
                                }
                            }
                            .padding(.top, 2)
                        }
                    }

                    Spacer(minLength: 12)

                    VStack(alignment: .trailing, spacing: 6) {
                        if let opp = opportunity, opp.kind == .customApp {
                            OpportunityPill(kind: .customApp)
                        } else {
                            LevelPill(level: read.level)
                            Text("automatable").microLabel()
                        }
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                        .frame(width: 14)
                }
                .padding(.horizontal, 18).padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Rectangle().fill(Theme.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 14) {
                    if recorded {
                        Button {
                            RecordingWindow.present(
                                title: title,
                                subtitle: "\(task.start.formatted(date: .abbreviated, time: .shortened)) \u{2013} \(task.end.formatted(date: .omitted, time: .shortened)) \u{00B7} \(Format.duration(task.duration))",
                                interval: taskInterval.padded,
                                moments: minutes.filter { !$0.text.isEmpty && $0.text != "Away from keyboard" }.map(RecordingMoment.init),
                                segments: segments)
                        } label: {
                            Label("Watch this task", systemImage: "play.rectangle.fill")
                        }
                        .controlSize(.small)
                    }
                    StoryMarkdown(blocks: StoryFormat.blocks(task.text))

                    if let opp = opportunity {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(opp.kind == .customApp ? "\u{1F9E9} What we'd build" : "\u{1F9ED} What to do about it")
                                .font(.system(size: 12.5, weight: .bold)).foregroundStyle(Theme.ink)
                            HStack(alignment: .top, spacing: 8) {
                                OpportunityPill(kind: opp.kind)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(opp.headline).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if !opp.rationale.isEmpty {
                                        Text(opp.rationale).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    if !opp.entities.isEmpty { EntityChips(entities: opp.entities) }
                                }
                            }
                        }
                    }

                    // The automation read, plainly.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\u{1F916} Could a machine do this?").font(.system(size: 12.5, weight: .bold)).foregroundStyle(Theme.ink)
                        HStack(alignment: .top, spacing: 8) {
                            LevelPill(level: read.level)
                            if !read.reason.isEmpty {
                                Text(read.reason).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                                    .fixedSize(horizontal: false, vertical: true).padding(.top, 3)
                            }
                        }
                    }

                    if !minutes.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\u{23F1}\u{FE0F} Minute by minute").font(.system(size: 12.5, weight: .bold)).foregroundStyle(Theme.ink)
                            ForEach(Array(minutes.enumerated()), id: \.element.id) { i, m in
                                HStack(alignment: .top, spacing: 8) {
                                    ZStack {
                                        Circle().fill(Theme.panelHi)
                                        Text("\(i + 1)").font(.system(size: 9.5, weight: .bold)).numeric().foregroundStyle(Theme.ink2)
                                    }
                                    .frame(width: 18, height: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(m.minuteStart.formatted(date: .omitted, time: .shortened))
                                                .font(.system(size: 10.5, weight: .semibold)).numeric().foregroundStyle(Theme.ink3)
                                            Text(StoryFormat.clean(m.text)).font(.system(size: 12)).foregroundStyle(Theme.ink)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        if !m.shortcuts.isEmpty || !m.fields.isEmpty {
                                            Text([m.shortcuts, m.fields].filter { !$0.isEmpty }.joined(separator: "  \u{00B7}  "))
                                                .font(.system(size: 10)).foregroundStyle(Theme.ink3).lineLimit(1)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel2)
            }
        }
        .panelSkin()
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}
