import SwiftUI

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case story = "Story"
    case tasks = "Tasks"
    case workflows = "Workflows"
    case logs = "Logs"
    case privacy = "Privacy"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .story: return "book.pages.fill"
        case .tasks: return "list.bullet.rectangle.fill"
        case .workflows: return "arrow.triangle.branch"
        case .logs: return "text.alignleft"
        case .privacy: return "lock.shield.fill"
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    @State private var section: DashboardSection = .overview
    @State private var range: TimeRange = .week
    @State private var showWelcome = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .toolbar { toolbarContent }
        }
        .navigationTitle("")
        .onAppear {
            // First-run welcome: ask for all permissions and choices up front.
            if !UserDefaults.standard.bool(forKey: WelcomeSheet.onboardedKey) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showWelcome = true }
            }
        }
        .onChange(of: state.welcomeRequested) {
            if state.welcomeRequested { showWelcome = true; state.welcomeRequested = false }
        }
        .sheet(isPresented: $showWelcome) {
            WelcomeSheet()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                LogoMark(size: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Availeth")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Text("Process Discovery")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 18)

            List(DashboardSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .listStyle(.sidebar)

            Spacer()

            captureStatusFooter
                .padding(12)
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
    }

    private var captureStatusFooter: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(state.engine.isPaused ? Color.orange : (state.engine.isObserving ? Color.green : Color.secondary))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(state.engine.isPaused ? "Paused" : (state.engine.isObserving ? "Discovery active" : "Stopped"))
                    .font(.caption.weight(.medium))
                Text("\(Format.duration(state.engine.observedTodaySeconds)) today")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .overview: OverviewView(range: range)
        case .story: StoryView(range: range)
        case .tasks: TasksView(range: range)
        case .workflows: WorkflowsView(range: range)
        case .logs: LogsView(range: range)
        case .privacy: PrivacyView()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if section != .privacy {
                Picker("Data source", selection: $state.showDemo) {
                    Text("Demo data").tag(true)
                    Text("My activity").tag(false)
                }
                .pickerStyle(.segmented)
                .help("Demo data shows a sample two-week finance dataset. My activity shows what Availeth has observed on this Mac.")

                Picker("Range", selection: $range) {
                    ForEach(TimeRange.allCases) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }
}
