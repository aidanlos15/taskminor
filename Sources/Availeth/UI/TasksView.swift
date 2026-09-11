import SwiftUI

/// Every distinct piece of work as one row — the app's real logo, what the task
/// was, how much time it took — with the captured detail one click away.
struct TasksView: View {
    @EnvironmentObject private var state: AppState
    var range: TimeRange

    @State private var tasks: [DetailedTask] = []
    @State private var bundles: [String: String] = [:]
    @State private var sites: [String: String] = [:]
    @State private var search = ""
    @State private var expanded: Set<String> = []
    @State private var reloadTask: Task<Void, Never>?

    private var filtered: [DetailedTask] {
        guard !search.isEmpty else { return tasks }
        return tasks.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || $0.appUnit.localizedCaseInsensitiveContains(search)
                || $0.variants.contains { $0.localizedCaseInsensitiveContains(search) }
                || $0.moments.contains { $0.text.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                panel
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

    /// Queries, grouping and the logo prewarm all run off the main thread
    /// (detached — `View` is @MainActor, so a plain Task would inherit it), and
    /// the rows only appear once the logo cache is warm, so first paint is a blit.
    private func reload() {
        reloadTask?.cancel()
        let range = self.range
        let demo = state.showDemo
        let store = state.store
        reloadTask = Task.detached(priority: .userInitiated) {
            let to = Date().addingTimeInterval(60)
            let spans = store.spans(from: range.startDate(), to: to, demo: demo)
            let narratives = store.narratives(from: range.startDate(), to: to, demo: demo)
            let labels = store.spanLabels(from: range.startDate(), to: to, demo: demo)
            if Task.isCancelled { return }
            let built = Analytics.detailedTasks(spans, narratives: narratives, labels: labels)
            let bundleMap = LogoProvider.bundleMap(spans)
            let siteMap = LogoProvider.siteMap(spans)
            LogoProvider.shared.prewarm(units: Array(Set(built.map(\.appUnit))), bundles: bundleMap, sites: siteMap)
            // Sites seen before their icon existed catch up here.
            if !demo { SiteIconStore.shared.requestMissing(hosts: LogoProvider.hosts(spans)) }
            if Task.isCancelled { return }
            await MainActor.run {
                if Task.isCancelled { return }
                self.tasks = built; self.bundles = bundleMap; self.sites = siteMap
            }
        }
    }

    // MARK: - Panel

    private var panel: some View {
        let filtered = self.filtered            // computed once per body, not per use
        let shown = Array(filtered.prefix(80))
        return VStack(spacing: 0) {
            // Header
            HStack(alignment: .center, spacing: 12) {
                Text("Tasks")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                searchField
                HeaderBadge(text: "\(filtered.count) task\(filtered.count == 1 ? "" : "s") \u{00B7} \(state.showDemo ? "demo data" : "\(range.rawValue) \u{00B7} your Mac")")
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            hairline

            if shown.isEmpty {
                EmptyState(
                    icon: "list.bullet.rectangle",
                    title: "No tasks here yet",
                    message: search.isEmpty
                        ? "Tasks appear once Availeth has observed some work. Turn on Screen capture in the Privacy tab and the local model names each task from what was on screen."
                        : "Nothing matches \u{201C}\(search)\u{201D}."
                )
                .padding(.horizontal, 18)
            } else {
                ForEach(shown, id: \.id) { task in
                    row(task)
                    hairline
                }
                HStack {
                    Text(filtered.count > 80
                         ? "Showing the top 80 of \(filtered.count) tasks \u{2014} search to narrow down."
                         : "Click a task to see its sittings and what was captured.")
                        .font(.system(size: 12)).numeric()
                        .foregroundStyle(Theme.ink3)
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
        }
        .panelSkin()
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.ink3)
            TextField("Search tasks, apps or content", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(width: 260)
        .background(Capsule().fill(Theme.panelHi))
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(_ task: DetailedTask) -> some View {
        let isOpen = expanded.contains(task.id)
        let hasDetail = !task.moments.isEmpty || task.runs.count > 1 || task.variants.count > 1
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard hasDetail else { return }
                if isOpen { expanded.remove(task.id) } else { expanded.insert(task.id) }
            } label: {
                HStack(alignment: .center, spacing: 14) {
                    // The app's — or the site's — real logo in a soft tile.
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panelHi)
                        AppLogoView(unit: task.appUnit, bundleID: bundles[task.appUnit], site: sites[task.appUnit], size: 24)
                    }
                    .frame(width: 40, height: 40)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(task.title)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Text(task.appUnit).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink2)
                            Text("\u{00B7}").foregroundStyle(Theme.ink3)
                            Text("\(task.sessions) sitting\(task.sessions == 1 ? "" : "s")")
                                .font(.system(size: 12)).numeric().foregroundStyle(Theme.ink3)
                            if !task.moments.isEmpty {
                                Text("\u{00B7}").foregroundStyle(Theme.ink3)
                                Text("\(task.moments.count) captured")
                                    .font(.system(size: 12, weight: .semibold)).numeric()
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        if !task.preview.isEmpty && !isOpen {
                            Text(task.preview)
                                .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 12)

                    VStack(alignment: .trailing, spacing: 3) {
                        Text(Format.duration(task.duration))
                            .font(.system(size: 17, weight: .bold)).numeric()
                            .foregroundStyle(Theme.ink)
                        Text("total").microLabel()
                    }
                    if hasDetail {
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.ink3)
                            .frame(width: 14)
                    } else {
                        Color.clear.frame(width: 14)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen { detail(task).padding(.horizontal, 18).padding(.bottom, 14) }
        }
    }

    /// The sittings that make up the task (so a merge is always auditable),
    /// then the captured moments in time order.
    private func detail(_ task: DetailedTask) -> some View {
        let seenAs = task.variants.filter {
            LabelKey.canonKey($0) != LabelKey.canonKey(task.title) && LabelKey.canonKey($0) != LabelKey.canonKey(task.appUnit)
        }
        return VStack(alignment: .leading, spacing: 12) {
            if task.source == .model {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                    Text(state.showDemo ? "Example title \u{2014} demo data" : "Named by the local model from what was on screen")
                }
                .font(.system(size: 11)).foregroundStyle(Theme.ink3)
            }
            if !seenAs.isEmpty {
                Text("Seen as: " + seenAs.prefix(4).joined(separator: ", ") + (seenAs.count > 4 ? ", \u{2026}" : ""))
                    .font(.system(size: 11)).foregroundStyle(Theme.ink3)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if task.runs.count > 1 || task.variants.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sittings").microLabel(Theme.ink3)
                    ForEach(Array(task.runs.suffix(8).enumerated()), id: \.offset) { _, run in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(run.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                                .font(.system(size: 11)).numeric().foregroundStyle(Theme.ink3)
                                .frame(width: 84, alignment: .leading)
                            Text("\(run.start.formatted(date: .omitted, time: .shortened))\u{2013}\(run.end.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 11)).numeric().foregroundStyle(Theme.ink2)
                            Text(Format.duration(run.duration))
                                .font(.system(size: 11, weight: .semibold)).numeric().foregroundStyle(Theme.ink)
                            if LabelKey.canonKey(run.windowTitle) != LabelKey.canonKey(task.title),
                               LabelKey.canonKey(run.windowTitle) != LabelKey.canonKey(task.appUnit) {
                                Text(run.windowTitle).font(.system(size: 11)).foregroundStyle(Theme.ink3).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    if task.runs.count > 8 {
                        Text("and \(task.runs.count - 8) earlier").font(.system(size: 11)).numeric().foregroundStyle(Theme.ink3)
                    }
                }
            }
            if !task.moments.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("What happened, in detail").microLabel(Theme.ink3)
                    ForEach(Array(task.moments.prefix(80).enumerated()), id: \.element.id) { _, m in
                        HStack(alignment: .top, spacing: 10) {
                            Text(m.timestamp.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 10.5)).numeric()
                                .foregroundStyle(Theme.ink3)
                                .frame(width: 52, alignment: .leading)
                            Text(m.text)
                                .font(.system(size: 12)).foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSkin(Theme.panel2, border: Theme.line, radius: 10)
        .padding(.leading, 54)
    }

    private var hairline: some View { Rectangle().fill(Theme.line).frame(height: 1) }
}
