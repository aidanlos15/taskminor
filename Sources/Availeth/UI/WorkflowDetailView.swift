import SwiftUI

/// The drill-down for one detected workflow: a clear map of what the person did,
/// with the captured screenshots and their narratives, and what could be automated.
struct WorkflowDetailView: View {
    @Environment(\.dismiss) private var dismiss
    var insight: WorkflowInsight
    var hourlyRate: Double

    private var pattern: WorkflowPattern { insight.pattern }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
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
        }
        .frame(width: 720, height: 720)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(insight.title).font(.title2.weight(.bold))
                Text("Repeated \(pattern.occurrences)× · median \(Format.preciseDuration(pattern.medianDuration)) · \(Format.duration(pattern.totalDuration)) observed")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            scorePill
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    private var scorePill: some View {
        let color: Color = !insight.automatable ? .secondary
            : (pattern.automationScore >= 75 ? .green : (pattern.automationScore >= 50 ? .orange : .secondary))
        return VStack(spacing: 0) {
            Text("\(pattern.automationScore)").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text("score").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.12)))
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("What this is", icon: "doc.text.magnifyingglass") {
                Text(insight.whatItIs).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            section("Can this be automated?", icon: insight.automatable ? "wand.and.stars" : "person.fill.questionmark", tint: insight.automatable ? .purple : .secondary) {
                Text(insight.whatToAutomate).font(.callout).fixedSize(horizontal: false, vertical: true)
                if insight.automatable && pattern.projectionIsReliable {
                    Text("Potential saving: ~\(Format.money(pattern.estimatedYearlySaving(hourlyRate: hourlyRate)))/yr")
                        .font(.callout.weight(.semibold)).foregroundStyle(.purple).padding(.top, 2)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Step map

    private var stepMapCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("The steps, in order", systemImage: "list.number").font(.headline)
            Text("The same sequence Availeth saw repeat each time:")
                .font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(insight.steps) { step in
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle().fill(AppPalette.color(for: step.app).opacity(0.18)).frame(width: 26, height: 26)
                            Text("\(step.id + 1)").font(.caption.weight(.bold)).foregroundStyle(AppPalette.color(for: step.app))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(step.app).font(.callout.weight(.medium))
                            if !step.detail.isEmpty {
                                Text(step.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            } else {
                                Text("(no window title captured)").font(.caption).foregroundStyle(.tertiary).italic()
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 7)
                    if step.id < insight.steps.count - 1 {
                        HStack { Rectangle().fill(.quaternary).frame(width: 1, height: 12).padding(.leading, 12); Spacer() }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: - Walkthrough (screenshots + narratives)

    private var walkthroughCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("What happened, moment by moment", systemImage: "sparkles.rectangle.stack").font(.headline)
            Text("One real run of this workflow — each frame is what a local vision model saw; the images auto-delete after 24h.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(insight.moments.enumerated()), id: \.element.id) { index, moment in
                    HStack(alignment: .top, spacing: 12) {
                        Text(moment.timestamp.formatted(date: .omitted, time: .shortened))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        thumbnail(for: moment)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(moment.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                            if !moment.appName.isEmpty {
                                Text(moment.windowTitle.isEmpty ? moment.appName : "\(moment.appName) — \(moment.windowTitle)")
                                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    if index < insight.moments.count - 1 { Divider() }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var noStorylineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Turn on Storyline for screenshots", systemImage: "camera.viewfinder").font(.headline)
            Text("This workflow was detected from app and window activity. Enable Storyline in the Privacy tab (local vision model, images auto-deleted) and the next occurrences will include a screenshot-by-screenshot walkthrough of exactly what happened.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.3)))
    }

    @ViewBuilder
    private func thumbnail(for moment: SceneNarrative) -> some View {
        if !moment.imagePath.isEmpty, let image = NSImage(contentsOfFile: moment.imagePath) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 150, height: 94).clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        } else {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)).frame(width: 150, height: 94)
                .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func section<Content: View>(_ title: String, icon: String, tint: Color = .indigo, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            content()
        }
    }
}
