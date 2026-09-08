import SwiftUI

/// Raw record inspector: every field Availeth stores, one row per record,
/// newest first. This is the app's full data surface — there is nothing
/// captured that this view does not show.
struct LogsView: View {
    @EnvironmentObject private var state: AppState
    var range: TimeRange

    @State private var spans: [ActivitySpan] = []
    @State private var shots: [Screenshot] = []
    @State private var narratives: [SceneNarrative] = []
    @State private var idles: [IdleSession] = []
    @State private var transfers: [Transfer] = []
    @State private var search = ""

    private static let displayCap = 300

    private var filtered: [ActivitySpan] {
        guard !search.isEmpty else { return spans }
        return spans.filter {
            $0.appName.localizedCaseInsensitiveContains(search)
                || $0.windowTitle.localizedCaseInsensitiveContains(search)
                || $0.bundleID.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                schemaCard

                if !transfers.isEmpty {
                    transfersCard
                }

                if !narratives.isEmpty || !idles.isEmpty {
                    storylineCard
                }

                if !shots.isEmpty {
                    screenshotsCard
                }

                Card(title: "Captured records", subtitle: subtitleText) {
                    searchField

                    if filtered.isEmpty {
                        EmptyState(
                            icon: "text.alignleft",
                            title: "No records in this range",
                            message: state.showDemo
                                ? "The demo dataset has no records here — try a longer range."
                                : "Records appear a few seconds after you switch apps or windows. Work normally and check back."
                        )
                    } else {
                        recordList
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
        spans = state.spans(in: range).sorted { $0.start > $1.start }
        let from = range.startDate()
        let to = Date().addingTimeInterval(60)
        shots = state.store.screenshots(from: from, to: to, demo: state.showDemo)
        narratives = state.store.narratives(from: from, to: to, demo: state.showDemo)
        transfers = state.store.transfers(from: from, to: to, demo: state.showDemo).reversed()
        idles = state.store.idleSessions(from: from, to: to, demo: state.showDemo)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink3)
            TextField("Filter by app, title, or bundle ID…", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: 340)
        .panelSkin(Theme.panelHi, border: Theme.line, radius: 8)
    }

    // MARK: - Storyline

    /// A time-ordered entry in the storyline: either a captured moment or an
    /// away-from-keyboard stretch.
    private enum TimelineEntry: Identifiable {
        case moment(SceneNarrative)
        case idle(IdleSession)
        var id: String {
            switch self {
            case .moment(let n): return "m\(n.id)"
            case .idle(let s): return "i\(s.id)"
            }
        }
        var time: Date {
            switch self {
            case .moment(let n): return n.timestamp
            case .idle(let s): return s.start
            }
        }
    }

    private var timeline: [TimelineEntry] {
        let merged = narratives.map(TimelineEntry.moment) + idles.map(TimelineEntry.idle)
        return merged.sorted { $0.time > $1.time }
    }

    /// Every movement of data between two contexts. This is the evidence the
    /// Workflows tab reasons from, so it belongs in the record the person can
    /// read: the tab promises the complete raw data, and for a while this was
    /// captured and shown nowhere.
    private var transfersCard: some View {
        let entries = Array(transfers.prefix(120))
        return Card(title: "Data movements",
                    subtitle: "\(transfers.count) time\(transfers.count == 1 ? "" : "s") something was copied in one place and pasted in another. Availeth records where it left and where it landed, never what was copied.") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, t in
                    transferRow(t)
                    if index < entries.count - 1 { Rectangle().fill(Theme.line).frame(height: 1) }
                }
            }
        }
    }

    private func transferRow(_ t: Transfer) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(t.at.formatted(date: .omitted, time: .standard))
                .font(.system(size: 10.5, design: .monospaced)).numeric()
                .foregroundStyle(Theme.ink3).frame(width: 74, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(t.fromUnit).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
                    Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(Theme.accent)
                    Text(t.toUnit).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
                }
                HStack(spacing: 8) {
                    if !t.toField.isEmpty {
                        Text("into \(t.toField)").font(.caption2).foregroundStyle(Theme.ink2)
                    }
                    Text("\(Int(t.gapSeconds))s between copy and paste")
                        .font(.caption2).foregroundStyle(Theme.ink3)
                }
            }
            Spacer()
        }
        .padding(.vertical, 7)
    }

    private var storylineCard: some View {
        let entries = Array(timeline.prefix(80))
        return Card(title: "Storyline", subtitle: "What a local vision model saw you doing. Time away from the keyboard is marked. Images stay on this Mac and are deleted after 24 hours. The model is told to avoid specifics, and a local scrub strips emails, amounts and ID numbers.") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    switch entry {
                    case .moment(let n): momentRow(n)
                    case .idle(let s): idleRow(s)
                    }
                    if index < entries.count - 1 {
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                }
            }
        }
    }

    private func momentRow(_ n: SceneNarrative) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption).numeric()
                .foregroundStyle(Theme.ink3)
                .frame(width: 58, alignment: .leading)
            sceneThumbnail(for: n)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").font(.caption2).foregroundStyle(Theme.accent)
                    if !n.trigger.isEmpty {
                        Text(n.trigger)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accentDim))
                            .foregroundStyle(Theme.accent)
                    }
                    Text(n.text).font(.callout).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                }
                if !n.appName.isEmpty {
                    Text(n.windowTitle.isEmpty ? n.appName : "\(n.appName) — \(n.windowTitle)")
                        .font(.caption2).foregroundStyle(Theme.ink3).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private func idleRow(_ s: IdleSession) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(s.start.formatted(date: .omitted, time: .shortened))
                .font(.caption).numeric()
                .foregroundStyle(Theme.ink3)
                .frame(width: 58, alignment: .leading)
            Image(systemName: "moon.zzz.fill")
                .font(.callout)
                .foregroundStyle(Theme.ink3)
                .frame(width: 132)
            Text("Away from keyboard · \(Format.duration(s.duration))")
                .font(.callout.weight(.medium)).numeric()
                .foregroundStyle(Theme.ink2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.panelHi))
    }

    @ViewBuilder
    private func sceneThumbnail(for n: SceneNarrative) -> some View {
        if !n.imagePath.isEmpty, let image = NSImage(contentsOfFile: n.imagePath) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 132, height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Theme.panelHi)
                .frame(width: 132, height: 82)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                .overlay(
                    VStack(spacing: 2) {
                        Image(systemName: "photo").foregroundStyle(Theme.ink3)
                        Text("image expired").font(.system(size: 8)).foregroundStyle(Theme.ink3)
                    }
                )
        }
    }

    private var subtitleText: String {
        let source = state.showDemo ? "demo dataset" : "live capture on this Mac"
        return "\(spans.count) records from the \(source), newest first — this is the complete raw data"
    }

    // MARK: - Schema explainer

    private var schemaCard: some View {
        Card(title: "What one activity record contains", subtitle: "Each activity record holds the fields below. Screen capture also stores the one-line descriptions shown in the card above.") {
            VStack(alignment: .leading, spacing: 8) {
                schemaRow("clock", "Start & end time", "When the window came to the front and when you left it. Idle time is cut off. Time away from the keyboard never counts.")
                schemaRow("app.badge", "App name & bundle ID", "Which app was in front, for example Google Chrome. This needs no permission at all.")
                schemaRow("macwindow", "Window title", "The title bar text of the window you were in. Filled in only if you granted Accessibility, and empty otherwise. This is the one field that comes close to your content.")
                schemaRow("keyboard", "Keyboard & mouse activity (if enabled)", "Shortcuts used, keys and clicks counted, and which field was typed into. The shape of the work, never the characters.")
                schemaRow("doc.text.magnifyingglass", "Document (if enabled)", "The name/path of the file open in the window — its identity, never its contents.")
                schemaRow("tag", "Source flag", "Whether the record belongs to the demo dataset or your live capture. The two are never mixed.")
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            Label {
                Text("A data movement additionally records which window the data left, which window and field it landed in, and how long the two were apart. Never the thing that was copied.")
                    .font(.caption).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Never in any record: the characters you typed, file contents, clipboard, microphone/camera, or anything from excluded apps.")
                    .font(.caption)
                    .foregroundStyle(Theme.ink2)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(Theme.good)
            }
        }
    }

    // MARK: - Screenshots gallery

    private var screenshotsCard: some View {
        Card(title: "Redacted screenshots", subtitle: "\(shots.count) captures — each downscaled and blurred locally before storage, auto-deleted after 24h") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(shots.prefix(40)) { shot in
                        VStack(alignment: .leading, spacing: 4) {
                            thumbnail(for: shot)
                            Text(shot.timestamp.formatted(date: .omitted, time: .shortened))
                                .font(.caption2).numeric()
                                .foregroundStyle(Theme.ink2)
                            Text(shot.appName)
                                .font(.caption2)
                                .foregroundStyle(Theme.ink3)
                                .lineLimit(1)
                        }
                        .frame(width: 200)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func thumbnail(for shot: Screenshot) -> some View {
        if let image = NSImage(contentsOfFile: shot.path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 200, height: 125)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.panelHi)
                .frame(width: 200, height: 125)
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
                .overlay(Image(systemName: "photo").foregroundStyle(Theme.ink3))
        }
    }

    private func schemaRow(_ icon: String, _ name: String, _ explanation: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(Theme.ink2)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout.weight(.medium)).foregroundStyle(Theme.ink)
                Text(explanation).font(.caption).foregroundStyle(Theme.ink2)
            }
        }
    }

    // MARK: - Record list

    private var recordList: some View {
        let visible = Array(filtered.prefix(Self.displayCap))
        let byDay = Dictionary(grouping: visible) { Calendar.current.startOfDay(for: $0.start) }
        let days = byDay.keys.sorted(by: >)

        return VStack(alignment: .leading, spacing: 4) {
            ForEach(days, id: \.self) { day in
                let daySpans = byDay[day] ?? []
                dayHeader(day, spans: daySpans)
                ForEach(daySpans) { span in
                    recordRow(span)
                }
            }

            if filtered.count > Self.displayCap {
                Text("Showing the newest \(Self.displayCap) of \(filtered.count) records — filter to narrow down.")
                    .font(.caption).numeric()
                    .foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 10)
            }
        }
    }

    private func dayHeader(_ day: Date, spans: [ActivitySpan]) -> some View {
        let total = spans.reduce(0.0) { $0 + $1.duration }
        return HStack {
            Text(day.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Spacer()
            Text("\(spans.count) records · \(Format.duration(total))")
                .font(.caption).numeric()
                .foregroundStyle(Theme.ink3)
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func recordRow(_ span: ActivitySpan) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(span.start.formatted(date: .omitted, time: .standard)) → \(span.end.formatted(date: .omitted, time: .standard))")
                .font(.caption).numeric()
                .foregroundStyle(Theme.ink2)
                .frame(width: 150, alignment: .leading)

            Text(Format.preciseDuration(span.duration))
                .font(.caption).numeric()
                .foregroundStyle(Theme.ink)
                .frame(width: 56, alignment: .trailing)

            HStack(spacing: 6) {
                Circle()
                    .fill(AppPalette.color(for: span.appName))
                    .frame(width: 7, height: 7)
                Text(span.appName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            .frame(width: 140, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                if span.windowTitle.isEmpty {
                    Text("no title — Accessibility not granted")
                        .font(.caption)
                        .foregroundStyle(Theme.ink3)
                        .italic()
                } else {
                    Text(span.windowTitle)
                        .font(.caption)
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(span.bundleID)
                        .font(.system(size: 9)).numeric()
                        .foregroundStyle(Theme.ink3)
                    if span.keystrokes > 0 || span.clicks > 0 {
                        Label("\(span.keystrokes) keys · \(span.clicks) clicks", systemImage: "keyboard")
                            .font(.system(size: 9)).numeric()
                            .foregroundStyle(Theme.ink2)
                    }
                    if !span.documentPath.isEmpty {
                        Label(URL(fileURLWithPath: span.documentPath).lastPathComponent, systemImage: "doc")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(1)
                    }
                }
                if !span.shortcuts.isEmpty {
                    Label(span.shortcuts, systemImage: "command")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
                if !span.fields.isEmpty {
                    Label(span.fields, systemImage: "character.cursor.ibeam")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
