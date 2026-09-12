import SwiftUI

/// The drill-down for one detected workflow: a clear map of what the person did,
/// with the captured screenshots and their narratives, and what could be automated.
struct WorkflowDetailView: View {
    @Environment(\.dismiss) private var dismiss
    var insight: WorkflowInsight
    var hourlyRate: Double
    /// Whether Storyline capture is currently enabled — so an empty walkthrough
    /// shows the right message (it's on but nothing landed yet, vs. it's off).
    var storylineOn: Bool = false
    /// unit → bundle id / page host, for the real app and site logos.
    var bundles: [String: String] = [:]
    var sites: [String: String] = [:]
    /// Recording segments covering the range, for the moment-by-moment clips.
    var segments: [RecordingSegment] = []
    /// The local model's judgement, when it has made one.
    var opportunity: Opportunity? = nil

    private var kind: Opportunity.Kind { opportunity?.kind ?? (insight.automatable ? .integration : .manual) }
    private var priced: Bool { kind == .integration || kind == .customApp }

    /// The captured frame being viewed at full size, if any.
    @State private var zoomed: SceneNarrative?

    /// Computed once per segment set, not per body pass.
    @State private var windows: [Recordings.Window] = []
    private var runRecorded: Bool { windows.contains { $0.recorded } }

    private func rebuildWindows() {
        guard let w = insight.representativeWindow else { windows = []; return }
        windows = Recordings.walkthroughWindows(occurrence: w, moments: insight.moments, segments: segments)
    }

    private var pattern: WorkflowPattern { insight.pattern }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
                    stepMapCard
                    if !insight.moments.isEmpty || runRecorded {
                        walkthroughCard
                    } else {
                        noStorylineCard
                    }
                }
                .padding(22)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(width: 720, height: 720)
        .appCanvas()
        .tint(Theme.accent)
        .sheet(item: $zoomed) { moment in FrameLightbox(moment: moment) }
        .onAppear(perform: rebuildWindows)
        .onChange(of: segments) { rebuildWindows() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(insight.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text("Repeated \(pattern.occurrences)× · median \(Format.preciseDuration(pattern.medianDuration)) · \(Format.duration(pattern.totalDuration)) observed")
                    .font(.system(size: 11.5)).numeric()
                    .foregroundStyle(Theme.ink2)
            }
            Spacer()
            OpportunityPill(kind: kind)
            scorePill
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .tint(Theme.accent)
        }
        .padding(20)
    }

    private var scorePill: some View {
        let color: Color = !insight.automatable ? Theme.ink3
            : (pattern.automationScore >= 75 ? Theme.good : (pattern.automationScore >= 50 ? Theme.amber : Theme.ink3))
        return VStack(spacing: 1) {
            Text("\(pattern.automationScore)")
                .font(.system(size: 18, weight: .bold)).numeric()
                .foregroundStyle(color)
            Text("score").microLabel()
            if kind == .customApp, pattern.automationScore < Opportunity.customAppFloorScore {
                Text("priced at \(Opportunity.customAppFloorScore)").font(.system(size: 8.5)).numeric().foregroundStyle(Theme.ink3)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(color.opacity(0.30), lineWidth: 1))
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("What this is", icon: "doc.text.magnifyingglass") {
                Text(insight.whatItIs)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let opp = opportunity {
                Rectangle().fill(Theme.line).frame(height: 1)
                section(opp.kind == .customApp ? "What we'd build" : "What to do about it",
                        icon: opp.kind == .customApp ? "hammer.fill" : (opp.kind == .integration ? "wand.and.stars" : "arrow.triangle.branch"),
                        tint: opp.kind == .manual ? Theme.ink2 : Theme.accent) {
                    Text(opp.headline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if !opp.rationale.isEmpty {
                        Text(opp.rationale)
                            .font(.system(size: 13)).foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !opp.entities.isEmpty { EntityChips(entities: opp.entities).padding(.top, 2) }
                    Text("\(opp.kind.title) \u{00B7} \(opp.confidence) confidence \u{00B7} judged by the local model")
                        .font(.system(size: 11)).foregroundStyle(Theme.ink3)
                }
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            section("Can this be automated?", icon: insight.automatable ? "wand.and.stars" : "person.fill.questionmark", tint: insight.automatable ? Theme.accent : Theme.ink2) {
                Text(insight.whatToAutomate)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if priced {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Potential saving: ~\(Format.money(pattern.estimatedYearlySaving(hourlyRate: hourlyRate, minimumScore: kind == .customApp ? Opportunity.customAppFloorScore : 0)))/yr")
                            .font(.system(size: 13, weight: .semibold)).numeric()
                            .foregroundStyle(Theme.accent)
                        Text(pattern.projectionBasis)
                            .font(.system(size: 11)).numeric().foregroundStyle(Theme.ink3)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSkin()
    }

    // MARK: - Step map

    private var stepMapCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("The steps, in order", systemImage: "list.number")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text("The same sequence Availeth saw repeat each time:")
                .font(.system(size: 11)).foregroundStyle(Theme.ink2)
            VStack(spacing: 0) {
                ForEach(insight.steps) { step in
                    HStack(alignment: .top, spacing: 12) {
                        // Plain step number, then the app's (or site's) real logo.
                        Text("\(step.id + 1)")
                            .font(.system(size: 12.5, weight: .semibold)).numeric()
                            .foregroundStyle(Theme.ink)
                            .frame(width: 16, alignment: .trailing)
                            .padding(.top, 6)
                        ZStack {
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.panelHi)
                            AppLogoView(unit: step.app, bundleID: bundles[step.app], site: sites[step.app], size: 17)
                        }
                        .frame(width: 28, height: 28)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.app)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.ink)
                            if !step.detail.isEmpty {
                                Text(step.detail)
                                    .font(.system(size: 11)).foregroundStyle(Theme.ink2).lineLimit(1)
                            }
                            // The vivid, captured account of what happened here.
                            if !step.content.isEmpty {
                                Text(step.content)
                                    .font(.system(size: 11.5)).foregroundStyle(Theme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                    .padding(.top, 1)
                            } else {
                                Text("(no screen detail captured for this step)")
                                    .font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 7)
                    if step.id < insight.steps.count - 1 {
                        HStack { Rectangle().fill(Theme.line2).frame(width: 1, height: 12).padding(.leading, 41.5); Spacer() }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSkin()
    }

    // MARK: - Walkthrough (screenshots + narratives)

    /// One real run in 30-second stretches: the recording of that stretch and
    /// every description the local model wrote during it.
    private var walkthroughCard: some View {
        let wins = windows
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Label("What happened, moment by moment", systemImage: "sparkles.rectangle.stack")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if runRecorded, let w = insight.representativeWindow {
                    Button {
                        RecordingWindow.present(title: insight.title, subtitle: runSubtitle(w), interval: w.padded,
                                                moments: insight.moments.map(RecordingMoment.init), segments: segments)
                    } label: {
                        Label("Play the whole run", systemImage: "play.rectangle.fill")
                    }
                    .controlSize(.small)
                }
            }
            Text(runRecorded
                 ? "One real run of this workflow, in 30-second stretches \u{2014} play any stretch, or the whole run at up to 4\u{00D7}. The text is what a local vision model saw at each moment."
                 : "One real run of this workflow \u{2014} each frame is what a local vision model saw; click a frame to see it full size. Images auto-delete after 24h.")
                .font(.system(size: 11)).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            LazyVStack(spacing: 0) {
                ForEach(wins) { win in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(win.interval.start.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 10.5, weight: .semibold)).numeric()
                                .foregroundStyle(Theme.ink2)
                            Text("30 s").font(.system(size: 9.5)).numeric().foregroundStyle(Theme.ink3)
                        }
                        .frame(width: 52, alignment: .leading)
                        poster(for: win)
                        VStack(alignment: .leading, spacing: 8) {
                            if win.moments.isEmpty {
                                Text("Recorded, but the model wrote nothing for these 30 seconds.")
                                    .font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                            }
                            ForEach(win.moments) { moment in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(moment.timestamp.formatted(date: .omitted, time: .standard))
                                            .font(.system(size: 10.5, weight: .semibold)).numeric().foregroundStyle(Theme.ink3)
                                        Text(moment.windowTitle.isEmpty ? moment.appName : "\(moment.appName) \u{2014} \(moment.windowTitle)")
                                            .font(.system(size: 10.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                                    }
                                    Text(moment.text)
                                        .font(.system(size: 12.5)).foregroundStyle(Theme.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    if win.id != wins.last?.id {
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSkin()
    }

    private func runSubtitle(_ w: DateInterval) -> String {
        "\(w.start.formatted(date: .abbreviated, time: .shortened)) \u{2013} \(w.end.formatted(date: .omitted, time: .shortened)) \u{00B7} \(Format.preciseDuration(w.duration))"
    }

    /// The stretch's clip when it was recorded, else its first captured frame.
    @ViewBuilder
    private func poster(for win: Recordings.Window) -> some View {
        if let part = win.part {
            ClipPoster(part: part) {
                RecordingWindow.present(title: insight.title, subtitle: runSubtitle(win.interval), interval: win.interval,
                                        moments: win.moments.map(RecordingMoment.init), segments: segments)
            }
        } else if let first = win.moments.first {
            thumbnail(for: first)
        } else {
            RoundedRectangle(cornerRadius: 6).fill(Theme.panelHi).frame(width: 150, height: 94)
        }
    }

    private var noStorylineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if storylineOn {
                Label("No screen detail for these runs yet", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Screen capture is on, but nothing captured is attached to this workflow's specific occurrences — these runs happened before screen capture was keeping text for them, or they were too brief to sample. It fills in as the workflow recurs from here.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Turn on Storyline for screenshots", systemImage: "camera.viewfinder")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("This workflow was detected from app and window activity. Enable Storyline in the Privacy tab (local vision model, images auto-deleted) and the next occurrences will include a screenshot-by-screenshot walkthrough of exactly what happened.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSkin(Theme.panel2, border: Theme.line)
    }

    @ViewBuilder
    private func thumbnail(for moment: SceneNarrative) -> some View {
        if !moment.imagePath.isEmpty, let image = NSImage(contentsOfFile: moment.imagePath) {
            Button { zoomed = moment } label: {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 150, height: 94).clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Circle().fill(.black.opacity(0.45)))
                            .padding(5)
                    }
            }
            .buttonStyle(.plain)
            .help("View this frame full size")
        } else {
            RoundedRectangle(cornerRadius: 6).fill(Theme.panelHi).frame(width: 150, height: 94)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
                .overlay(Image(systemName: "photo").foregroundStyle(Theme.ink3))
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func section<Content: View>(_ title: String, icon: String, tint: Color = Theme.ink, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint)
            content()
        }
    }
}

/// A captured frame at full size, with the narrative the model wrote for it.
struct FrameLightbox: View {
    @Environment(\.dismiss) private var dismiss
    var moment: SceneNarrative

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(moment.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 14, weight: .semibold)).numeric().foregroundStyle(Theme.ink)
                    Text(moment.windowTitle.isEmpty ? moment.appName : "\(moment.appName) \u{2014} \(moment.windowTitle)")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .tint(Theme.accent)
            }
            .padding(16)
            Rectangle().fill(Theme.line).frame(height: 1)
            if let image = NSImage(contentsOfFile: moment.imagePath) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyState(icon: "photo", title: "Image no longer on disk", message: "Frames are deleted after 24 hours; the description below is kept.")
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                Text(moment.text)
                    .font(.system(size: 12.5)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(maxHeight: 130)
        }
        .frame(minWidth: 960, idealWidth: 1100, minHeight: 700, idealHeight: 820)
        .appCanvas()
    }
}
