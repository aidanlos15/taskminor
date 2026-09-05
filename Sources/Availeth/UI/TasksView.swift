import SwiftUI

struct TasksView: View {
    @EnvironmentObject private var state: AppState
    var range: TimeRange

    @State private var tasks: [TaskGroup] = []
    @State private var search = ""

    private var filtered: [TaskGroup] {
        guard !search.isEmpty else { return tasks }
        return tasks.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || $0.appName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card(title: "Tasks", subtitle: "Every distinct piece of work, grouped by window title, with the time it consumed") {
                    TextField("Search tasks or apps…", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)

                    if filtered.isEmpty {
                        EmptyState(
                            icon: "list.bullet.rectangle",
                            title: "No tasks here yet",
                            message: search.isEmpty
                                ? "Tasks appear once Availeth has observed some work. Window-level grouping is richest when window-title capture is enabled in the Privacy tab."
                                : "Nothing matches “\(search)”."
                        )
                    } else {
                        taskList
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onAppear(perform: reload)
        .onChange(of: range) { reload() }
        .onChange(of: state.showDemo) { reload() }
        .onChange(of: state.dataVersion) { reload() }
    }

    private func reload() {
        tasks = Analytics.taskGroups(state.spans(in: range))
    }

    private var taskList: some View {
        let maxDuration = filtered.first?.duration ?? 1
        return VStack(spacing: 0) {
            ForEach(Array(filtered.prefix(60).enumerated()), id: \.element.id) { index, task in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 24, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.title)
                            .font(.body)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            AppChip(name: task.appName)
                            Text("\(task.sessions) session\(task.sessions == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(Format.duration(task.duration))
                            .font(.callout.monospacedDigit().weight(.medium))
                        GeometryReader { geo in
                            HStack {
                                Spacer()
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(AppPalette.color(for: task.appName).opacity(0.4))
                                    .frame(width: max(4, geo.size.width * task.duration / maxDuration), height: 4)
                            }
                        }
                        .frame(width: 120, height: 4)
                    }
                }
                .padding(.vertical, 10)

                if index < min(filtered.count, 60) - 1 {
                    Divider()
                }
            }

            if filtered.count > 60 {
                Text("Showing the top 60 of \(filtered.count) tasks — search to narrow down.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 10)
            }
        }
    }
}
