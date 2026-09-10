import SwiftUI

/// The drill-down for one detected workflow: a clear map of what the person did,
/// with the captured screenshots and their narratives, and what could be automated.
struct WorkflowDetailView: View {
    @Environment(\.dismiss) private var dismiss
    var insight: WorkflowInsight
    var hourlyRate: Double
    /// What the app can and cannot see, so an empty walkthrough gives the real
    /// reason instead of telling people to turn on something already on.
    var coverage: CoverageStatus = CoverageStatus()

    private var pattern: WorkflowPattern { insight.pattern }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCard
                    stepMapCard
                    if !insight.moments.isEmpty {
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
            Rectangle().fill(Theme.line).frame(height: 1)
            section("Can this be automated?", icon: insight.automatable ? "wand.and.stars" : "person.fill.questionmark", tint: insight.automatable ? Theme.accent : Theme.ink2) {
                Text(insight.whatToAutomate)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if insight.automatable && pattern.projectionIsReliable {
                    Text("Potential saving: ~\(Format.money(pattern.estimatedYearlySaving(hourlyRate: hourlyRate)))/yr")
                        .font(.system(size: 13, weight: .semibold)).numeric()
                        .foregroundStyle(Theme.accent).padding(.top, 2)
                }
                evidenceRow
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
                        ZStack {
                            Circle().fill(AppPalette.color(for: step.app).opacity(0.18)).frame(width: 26, height: 26)
                            Text("\(step.id + 1)")
                                .font(.system(size: 11, weight: .bold)).numeric()
                                .foregroundStyle(AppPalette.color(for: step.app))
                        }
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
                                Text(coverage.noScreenDetailShort)
                                    .font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 7)
                    if step.id < insight.steps.count - 1 {
                        HStack { Rectangle().fill(Theme.line2).frame(width: 1, height: 12).padding(.leading, 12); Spacer() }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSkin()
    }

    // MARK: - Walkthrough (screenshots + narratives)

    private var walkthroughCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("What happened, moment by moment", systemImage: "sparkles.rectangle.stack")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text("One real run of this workflow. Each frame is what a local vision model saw. The images are deleted after 24 hours.")
                .font(.system(size: 11)).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(insight.moments.enumerated()), id: \.element.id) { index, moment in
                    HStack(alignment: .top, spacing: 12) {
                        Text(moment.timestamp.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 10.5)).numeric()
                            .foregroundStyle(Theme.ink3).frame(width: 52, alignment: .leading)
                        thumbnail(for: moment)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(moment.text)
                                .font(.system(size: 13)).foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            if !moment.appName.isEmpty {
                                Text(moment.windowTitle.isEmpty ? moment.appName : "\(moment.appName) — \(moment.windowTitle)")
                                    .font(.system(size: 10.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    if index < insight.moments.count - 1 {
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSkin()
    }

    private var noStorylineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if coverage.screenReadingWorking {
                Label("No screen detail for these runs yet", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("Screen capture is on, but no captures are attached to these runs of the workflow. Either they happened before you turned it on, or they were too brief to sample. It fills in as the workflow recurs from here.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("No screen detail was recorded", systemImage: "camera.viewfinder")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("This workflow was found from app and window activity alone. " + coverage.noScreenDetailReason)
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
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 150, height: 94).clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: 6).fill(Theme.panelHi).frame(width: 150, height: 94)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
                .overlay(Image(systemName: "photo").foregroundStyle(Theme.ink3))
        }
    }

    // MARK: - Helpers

    /// The countable facts behind the verdict, so a finding can be checked
    /// rather than taken on trust. This is what a customer is being asked to
    /// believe before they hand the work to Availeth.
    @ViewBuilder
    private var evidenceRow: some View {
        let v = pattern.verdict
        HStack(alignment: .top, spacing: 24) {
            evidenceItem("\(pattern.occurrences)", "runs seen")
            evidenceItem("\(pattern.daysObserved)", pattern.daysObserved == 1 ? "day" : "separate days")
            if pattern.transferCount > 0 { evidenceItem("\(pattern.transferCount)", "data movements") }
            if !pattern.fields.isEmpty { evidenceItem("\(pattern.fields.count)", "fields each run") }
            Spacer()
        }
        .padding(.top, 8)
        if !pattern.fields.isEmpty {
            Text("Fields: " + pattern.fields.prefix(6).joined(separator: ", "))
                .font(.caption).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let caveats = v?.caveats, !caveats.isEmpty {
            Text("Worth knowing: " + caveats.joined(separator: ", and ") + ".")
                .font(.caption).foregroundStyle(Theme.amber)
                .fixedSize(horizontal: false, vertical: true)
        }
        if v?.level == .insufficient {
            Text("Availeth needs \(Verdict.minOccurrences) runs across \(Verdict.minDays) separate days before judging this, so a busy hour is never mistaken for a routine.")
                .font(.caption).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func evidenceItem(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 17, weight: .bold)).numeric().foregroundStyle(Theme.ink)
            Text(label).font(.system(size: 10)).textCase(.uppercase).tracking(0.6).foregroundStyle(Theme.ink3)
        }
    }

    private func section<Content: View>(_ title: String, icon: String, tint: Color = Theme.ink, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint)
            content()
        }
    }
}
