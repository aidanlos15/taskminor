import SwiftUI

/// Content container (console panel): hairline border, no drop shadow, optional
/// header with the title left and an uppercase caption on the right.
struct Card<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        Panel(title: title, caption: subtitle) {
            content
        }
    }
}

/// Compact KPI tile for the overview header row. Thin wrapper over `StatTile`
/// (kept for call-site compatibility); `iconColor` is ignored — the console
/// palette uses neutral glyphs and promotes signal tiles via `accent`.
struct StatCard: View {
    var icon: String
    var iconColor: Color = Theme.ink2
    var value: String
    var label: String
    var detail: String? = nil
    var accent: Bool = false

    var body: some View {
        StatTile(label: label, systemImage: icon, value: value, detail: detail, accent: accent)
    }
}

/// Empty-state placeholder used when a view has no data yet.
struct EmptyState: View {
    var icon: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panelHi)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line, lineWidth: 1))
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(Theme.ink3)
            }
            .frame(width: 54, height: 54)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}
