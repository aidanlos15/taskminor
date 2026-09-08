import SwiftUI

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case story = "Story"
    case tasks = "Tasks"
    case workflows = "Workflows"
    case logs = "Logs"
    case privacy = "Privacy"

    var id: String { rawValue }

    /// Thin outline glyphs — lighter and more precise than filled symbols.
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .story: return "text.alignleft"
        case .tasks: return "checklist"
        case .workflows: return "arrow.triangle.branch"
        case .logs: return "line.3.horizontal"
        case .privacy: return "lock.shield"
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    @State private var section: DashboardSection = .overview
    @State private var range: TimeRange = .week
    @State private var showWelcome = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            detailStack
        }
        .frame(minWidth: 1040, minHeight: 680)
        .appCanvas()
        .tint(Theme.accent)
        .background(WindowConfigurator())
        .onAppear {
            if !UserDefaults.standard.bool(forKey: WelcomeSheet.onboardedKey) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showWelcome = true }
            }
        }
        .onChange(of: state.welcomeRequested) {
            if state.welcomeRequested { showWelcome = true; state.welcomeRequested = false }
        }
        .sheet(isPresented: $showWelcome) { WelcomeSheet() }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                LogoMark(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Availeth").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("Process Discovery").microLabel().font(.system(size: 9))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 18)

            Text("Workspace").microLabel().padding(.horizontal, 14).padding(.bottom, 8)

            VStack(spacing: 2) {
                ForEach(DashboardSection.allCases) { item in
                    navRow(item)
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            captureStatusFooter.padding(12)
        }
        .padding(.top, 18)
        .frame(width: 224, alignment: .top)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

    private func navRow(_ item: DashboardSection) -> some View {
        let on = section == item
        return Button {
            section = item
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: on ? .semibold : .regular))
                    .frame(width: 17)
                    .foregroundStyle(on ? Theme.accent : Theme.ink2)
                Text(item.rawValue)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(on ? Theme.ink : Theme.ink2)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(on ? Theme.panelHi : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Theme.line : Color.clear, lineWidth: 1))
            )
            .overlay(alignment: .leading) {
                if on {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.accent)
                        .frame(width: 2, height: 15).offset(x: -6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var captureStatusFooter: some View {
        let paused = state.engine.isPaused
        let active = state.engine.isObserving
        let color = paused ? Theme.amber : (active ? Theme.good : Theme.ink3)
        return HStack(spacing: 8) {
            StatusDot(color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(paused ? "Paused" : (active ? "Discovery active" : "Stopped"))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).fixedSize()
                Text("\(Format.duration(state.engine.observedTodaySeconds)) today")
                    .font(.system(size: 10)).numeric().foregroundStyle(Theme.ink3)
            }
            Spacer(minLength: 6)
            themeToggle
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .panelSkin()
    }

    /// Light / Dark appearance switch, sat beside the discovery status.
    private var themeToggle: some View {
        HStack(spacing: 2) {
            themeButton(.light, "sun.max.fill")
            themeButton(.dark, "moon.fill")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.panelHi))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }

    private func themeButton(_ mode: ThemeMode, _ icon: String) -> some View {
        let on = state.themeMode == mode
        return Button {
            state.themeMode = mode
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(on ? Theme.accent : Theme.ink3)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(on ? Theme.accentDim : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode == .light ? "Light theme" : "Dark theme")
    }

    // MARK: - Detail

    private var detailStack: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Theme.line).frame(height: 1)
            detail
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            CornerTick().frame(width: 12, height: 12)
            Text(section.rawValue)
                .font(.system(size: 13, weight: .bold)).tracking(1.8)
                .textCase(.uppercase).foregroundStyle(Theme.ink)
            Spacer()
            if section != .privacy {
                SegControl(items: [("My activity", false), ("Demo", true)],
                           selection: $state.showDemo, accent: true)
                SegControl(items: TimeRange.allCases.map { ($0.rawValue, $0) },
                           selection: $range)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 52)
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
}

/// The logo's corner-bracket motif (top-left L), reused as the page-title tick.
struct LShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

struct CornerTick: View {
    var color: Color = Theme.ink4
    var body: some View {
        LShape().stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .square))
    }
}
