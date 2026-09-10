import SwiftUI

struct TasksView: View {
    @EnvironmentObject private var state: AppState
    var range: TimeRange

    @State private var tasks: [DetailedTask] = []
    @State private var search = ""
    @State private var expanded: Set<String> = []

    private var filtered: [DetailedTask] {
        guard !search.isEmpty else { return tasks }
        return tasks.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || $0.appUnit.localizedCaseInsensitiveContains(search)
                || $0.moments.contains { $0.text.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card(title: "Tasks", subtitle: "detail") {
                    Text("Every distinct piece of work. Click one to see exactly what happened: prompts, answers, what was on screen. Richest with screen capture on.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ink3)
                        TextField("Search tasks, apps, or content…", text: $search)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.ink)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: 340)
                    .panelSkin(Theme.panelHi, border: Theme.line, radius: 8)

                    if filtered.isEmpty {
                        EmptyState(
                            icon: "list.bullet.rectangle",
                            title: "No tasks here yet",
                            message: search.isEmpty
                                ? "Tasks appear once Availeth has watched you work for a while. Turn on screen capture in the Privacy tab for a full account of what each task was."
                                : "Nothing matches “\(search)”."
                        )
                    } else {
                        taskList
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
        let spans = state.spans(in: range)
        let narratives = state.store.narratives(from: range.startDate(), to: Date().addingTimeInterval(60), demo: state.showDemo)
        tasks = Analytics.detailedTasks(spans, narratives: narratives)
    }

    private var taskList: some View {
        let maxDuration = filtered.first?.duration ?? 1
        let shown = Array(filtered.prefix(80))
        return VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, task in
                row(index: index, task: task, maxDuration: maxDuration)
                if index < shown.count - 1 {
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
            }
            if filtered.count > 80 {
                Text("Showing the top 80 of \(filtered.count) tasks — search to narrow down.")
                    .font(.system(size: 11)).numeric()
                    .foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.top, 10)
            }
        }
    }

    @ViewBuilder
    private func row(index: Int, task: DetailedTask, maxDuration: TimeInterval) -> some View {
        let isOpen = expanded.contains(task.id)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard !task.moments.isEmpty else { return }
                if isOpen { expanded.remove(task.id) } else { expanded.insert(task.id) }
            } label: {
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.system(size: 11)).numeric()
                        .foregroundStyle(Theme.ink3)
                        .frame(width: 24, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title)
                            .font(.system(size: 13)).foregroundStyle(Theme.ink)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            AppChip(name: task.appUnit)
                            Text("\(task.sessions) session\(task.sessions == 1 ? "" : "s")")
                                .font(.system(size: 10.5)).numeric()
                                .foregroundStyle(Theme.ink3)
                            if !task.moments.isEmpty {
                                Label("\(task.moments.count) captured", systemImage: isOpen ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        // Content preview so the row says what it was, not just the app.
                        if !task.preview.isEmpty && !isOpen {
                            Text(task.preview)
                                .font(.system(size: 11.5)).foregroundStyle(Theme.ink2)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 5) {
                        Text(Format.duration(task.duration))
                            .font(.system(size: 12.5, weight: .medium)).numeric()
                            .foregroundStyle(Theme.ink2)
                        ZStack(alignment: .trailing) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.panelHi)
                                .frame(width: 120, height: 4)
                            GeometryReader { geo in
                                HStack {
                                    Spacer()
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(AppPalette.color(for: task.appUnit))
                                        .frame(width: max(4, geo.size.width * task.duration / maxDuration), height: 4)
                                }
                            }
                            .frame(width: 120, height: 4)
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            if isOpen { momentTimeline(task) }
        }
        .padding(.vertical, 10)
    }

    private func momentTimeline(_ task: DetailedTask) -> some View {
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
            if task.moments.isEmpty {
                // The reason has to be the real one. This used to say "turn on
                // screen capture" to people who already had it on.
                Text(state.coverage.noScreenDetailReason)
                    .font(.system(size: 11)).foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSkin(Theme.panel2, border: Theme.line, radius: 8)
        .padding(.leading, 36)
    }
}
