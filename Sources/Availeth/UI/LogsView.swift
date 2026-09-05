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

                if !narratives.isEmpty || !idles.isEmpty {
                    storylineCard
                }

                if !shots.isEmpty {
                    screenshotsCard
                }

                Card(title: "Captured records", subtitle: subtitleText) {
                    TextField("Filter by app, title, or bundle ID…", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 340)

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
        .background(Color(nsColor: .underPageBackgroundColor))
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
        idles = state.store.idleSessions(from: from, to: to, demo: state.showDemo)
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

    private var storylineCard: some View {
        let entries = Array(timeline.prefix(80))
        return Card(title: "Storyline", subtitle: "What a local vision model saw you doing, with away-from-keyboard time marked. Images are kept locally, auto-deleted after 24h; the model is told to avoid specifics and a local scrub strips emails, amounts, and ID numbers.") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    switch entry {
                    case .moment(let n): momentRow(n)
                    case .idle(let s): idleRow(s)
                    }
                    if index < entries.count - 1 { Divider() }
                }
            }
        }
    }

    private func momentRow(_ n: SceneNarrative) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(n.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            sceneThumbnail(for: n)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").font(.caption2).foregroundStyle(.purple)
                    if !n.trigger.isEmpty {
                        Text(n.trigger)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.indigo.opacity(0.15)))
                            .foregroundStyle(.indigo)
                    }
                    Text(n.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if !n.appName.isEmpty {
                    Text(n.windowTitle.isEmpty ? n.appName : "\(n.appName) — \(n.windowTitle)")
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private func idleRow(_ s: IdleSession) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(s.start.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Image(systemName: "moon.zzz.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 132)
            Text("Away from keyboard · \(Format.duration(s.duration))")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.25)))
    }

    @ViewBuilder
    private func sceneThumbnail(for n: SceneNarrative) -> some View {
        if !n.imagePath.isEmpty, let image = NSImage(contentsOfFile: n.imagePath) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 132, height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(0.4))
                .frame(width: 132, height: 82)
                .overlay(
                    VStack(spacing: 2) {
                        Image(systemName: "photo").foregroundStyle(.tertiary)
                        Text("image expired").font(.system(size: 8)).foregroundStyle(.tertiary)
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
        Card(title: "What one activity record contains", subtitle: "Each activity record holds the fields below. Storyline mode additionally stores one-line scene descriptions, shown in the Storyline card above.") {
            VStack(alignment: .leading, spacing: 8) {
                schemaRow("clock", "Start & end time", "When the window came to the front and when you left it. Idle time is cut off — away-from-keyboard never counts.")
                schemaRow("app.badge", "App name & bundle ID", "Which application was in front, e.g. Google Chrome (com.google.Chrome). Captured with no special permissions.")
                schemaRow("macwindow", "Window title", "The focused window's title bar text — only if you granted Accessibility. Empty otherwise. This is the only content-adjacent field.")
                schemaRow("keyboard", "Keyboard & mouse activity (if enabled)", "Shortcuts used, keys/clicks counted, and which field was typed into — the structure of the work, never the characters typed.")
                schemaRow("doc.text.magnifyingglass", "Document (if enabled)", "The name/path of the file open in the window — its identity, never its contents.")
                schemaRow("tag", "Source flag", "Whether the record belongs to the demo dataset or your live capture. The two are never mixed.")
            }
            Divider()
            Label {
                Text("Never in any record: the characters you typed, file contents, clipboard, microphone/camera, or anything from excluded apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.green)
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
                                .font(.caption2.monospacedDigit())
                            Text(shot.appName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
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
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.4))
                .frame(width: 200, height: 125)
                .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
        }
    }

    private func schemaRow(_ icon: String, _ name: String, _ explanation: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout.weight(.medium))
                Text(explanation).font(.caption).foregroundStyle(.secondary)
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
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 10)
            }
        }
    }

    private func dayHeader(_ day: Date, spans: [ActivitySpan]) -> some View {
        let total = spans.reduce(0.0) { $0 + $1.duration }
        return HStack {
            Text(day.formatted(date: .abbreviated, time: .omitted))
                .font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(spans.count) records · \(Format.duration(total))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func recordRow(_ span: ActivitySpan) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(span.start.formatted(date: .omitted, time: .standard)) → \(span.end.formatted(date: .omitted, time: .standard))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)

            Text(Format.preciseDuration(span.duration))
                .font(.caption.monospacedDigit())
                .frame(width: 56, alignment: .trailing)

            HStack(spacing: 6) {
                Circle()
                    .fill(AppPalette.color(for: span.appName))
                    .frame(width: 7, height: 7)
                Text(span.appName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .frame(width: 140, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                if span.windowTitle.isEmpty {
                    Text("no title — Accessibility not granted")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .italic()
                } else {
                    Text(span.windowTitle)
                        .font(.caption)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    Text(span.bundleID)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if span.keystrokes > 0 || span.clicks > 0 {
                        Label("\(span.keystrokes) keys · \(span.clicks) clicks", systemImage: "keyboard")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    if !span.documentPath.isEmpty {
                        Label(URL(fileURLWithPath: span.documentPath).lastPathComponent, systemImage: "doc")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if !span.shortcuts.isEmpty {
                    Label(span.shortcuts, systemImage: "command")
                        .font(.system(size: 9))
                        .foregroundStyle(.indigo)
                        .lineLimit(1)
                }
                if !span.fields.isEmpty {
                    Label(span.fields, systemImage: "character.cursor.ibeam")
                        .font(.system(size: 9))
                        .foregroundStyle(.teal)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
