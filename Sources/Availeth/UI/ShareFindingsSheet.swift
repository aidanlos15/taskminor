import AppKit
import SwiftUI

/// The handover. Availeth's offer is that it builds the first automation it finds
/// for free, and this is where the customer claims it: the person reads the exact
/// text that will leave their Mac, then saves it and sends it themselves. The app
/// uploads nothing, so the promise that activity stays local survives the one
/// moment the business needs something out.
struct ShareFindingsSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let report: FindingsReport
    @State private var saved: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(report.findings.isEmpty
                         ? "Nothing is ready to send yet. Availeth waits until the same work has been seen \(Verdict.minOccurrences) times across \(Verdict.minDays) separate days, so a busy hour is never mistaken for a routine."
                         : "This is everything that will leave this Mac. Read it, then save it and send it to Availeth however you like. The app uploads nothing on its own.")
                        .font(.caption).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(report.text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Theme.panelHi, in: RoundedRectangle(cornerRadius: 8))

                    excluded
                }
                .padding(20)
            }
            .scrollContentBackground(.hidden)
            Rectangle().fill(Theme.line).frame(height: 1)
            footer
        }
        .frame(width: 620, height: 660)
        .appCanvas()
        .tint(Theme.accent)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "paperplane.fill").font(.system(size: 16)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Send findings to Availeth").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                Text("Availeth builds the first automation it finds for you, free")
                    .font(.caption).foregroundStyle(Theme.ink2)
            }
            Spacer()
        }
        .padding(20)
    }

    private var excluded: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Not in this file").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink)
            ForEach(["Window titles and file names, so no customer or document is named",
                     "Screenshots and anything a local model described",
                     "Anything you typed. Field names are the labels on the form, never their contents",
                     "Your minute-by-minute story and every raw activity record"], id: \.self) { line in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "xmark.circle.fill").font(.caption2).foregroundStyle(Theme.ink3).padding(.top, 2)
                    Text(line).font(.caption2).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if let saved {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                    .controlSize(.small)
            }
            Spacer()
            Button("Close") { dismiss() }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report.text, forType: .string)
            } label: { Text("Copy") }
            Button {
                save()
            } label: { Text("Save file…").frame(minWidth: 90) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(report.findings.isEmpty)
        }
        .padding(20)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Availeth findings.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report.text.write(to: url, atomically: true, encoding: .utf8)
        saved = url
    }
}
