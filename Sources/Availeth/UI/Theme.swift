import AppKit
import SwiftUI

/// Availeth's design system — a dark, operator-grade ("command console") look:
/// near-black surfaces layered by hairline borders (not shadows), one restrained
/// blue accent used only for signal, uppercase tracked micro-labels, and clean
/// tabular figures for every number. All screens compose from these tokens and
/// primitives so the language stays coherent.
enum Theme {
    /// A token that resolves to its light or dark value from the current
    /// appearance — so the whole design system re-themes when the app appearance
    /// flips (driven by the user's Light/Dark choice via NSApp.appearance).
    private static func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { ap in
            ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    // Surfaces (light canvas + white panels · dark near-black + raised panels).
    static let bgNS      = dyn(NSColor(hex: 0xF5F6F8), NSColor(hex: 0x0A0C11))
    static let bg        = Color(nsColor: bgNS)                                    // app canvas
    static let sidebarNS = dyn(NSColor(hex: 0xFFFFFF), NSColor(hex: 0x0C0F15))
    static let sidebar   = Color(nsColor: sidebarNS)                              // sidebar surface
    static let panel     = Color(nsColor: dyn(NSColor(hex: 0xFFFFFF), NSColor(hex: 0x10141B)))
    static let panelHi   = Color(nsColor: dyn(NSColor(hex: 0xEEF0F3), NSColor(hex: 0x171D27))) // raised / selected / track
    static let panel2    = Color(nsColor: dyn(NSColor(hex: 0xFAFBFC), NSColor(hex: 0x141922)))

    // Hairlines (dark ink on light, light ink on dark).
    static let line  = Color(nsColor: dyn(NSColor(white: 0, alpha: 0.09), NSColor(white: 1, alpha: 0.07)))
    static let line2 = Color(nsColor: dyn(NSColor(white: 0, alpha: 0.15), NSColor(white: 1, alpha: 0.12)))

    // Ink.
    static let ink  = Color(nsColor: dyn(NSColor(hex: 0x1A1D23), NSColor(hex: 0xE7EBF1)))   // primary
    static let ink2 = Color(nsColor: dyn(NSColor(hex: 0x59626F), NSColor(hex: 0x98A2B1)))   // secondary
    static let ink3 = Color(nsColor: dyn(NSColor(hex: 0x8A93A1), NSColor(hex: 0x5D6775)))   // tertiary / micro-labels
    static let ink4 = Color(nsColor: dyn(NSColor(hex: 0xC3C9D1), NSColor(hex: 0x3C444F)))   // faint marks / ticks

    // Accent (brand blue), used ONLY for signal.
    static let accent     = Color(nsColor: dyn(NSColor(hex: 0x2E6BE0), NSColor(hex: 0x4C8CFF)))
    static let accentDim  = Color(nsColor: dyn(NSColor(hex: 0x2E6BE0, alpha: 0.10), NSColor(hex: 0x4C8CFF, alpha: 0.16)))
    static let accentLine = Color(nsColor: dyn(NSColor(hex: 0x2E6BE0, alpha: 0.40), NSColor(hex: 0x4C8CFF, alpha: 0.35)))

    // Status.
    static let good   = Color(nsColor: dyn(NSColor(hex: 0x1F9D57), NSColor(hex: 0x3FB950)))
    static let amber  = Color(nsColor: dyn(NSColor(hex: 0xB57816), NSColor(hex: 0xE3B341)))
    static let danger = Color(nsColor: dyn(NSColor(hex: 0xCE3B33), NSColor(hex: 0xE5534B)))

    // Geometry.
    static let radius: CGFloat = 10
    static let panelPadding: CGFloat = 16
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension NSColor {
    convenience init(hex: UInt, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

// MARK: - Number + label styling

extension View {
    /// Clean, tabular figures (proportional SF face with monospaced digits) — the
    /// legible "instrument" number style; NOT a typewriter monospace.
    func numeric() -> some View { self.monospacedDigit() }

    /// An uppercase, tracked micro-label — the operator-console caption style.
    func microLabel(_ color: Color = Theme.ink3) -> some View {
        self.font(.system(size: 10, weight: .semibold))
            .tracking(1.1)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }

    /// Panel surface + hairline border + radius, the standard container skin.
    func panelSkin(_ fill: Color = Theme.panel, border: Color = Theme.line, radius: CGFloat = Theme.radius) -> some View {
        self.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(border, lineWidth: 1))
    }
}

// MARK: - Primitives

/// The standard content container: optional header (title left, uppercase caption
/// right), hairline border, no drop shadow.
struct Panel<Content: View>: View {
    var title: String? = nil
    var caption: String? = nil
    var padding: CGFloat = Theme.panelPadding
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || caption != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                    }
                    Spacer(minLength: 8)
                    if let caption {
                        Text(caption).microLabel()
                    }
                }
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSkin()
    }
}

/// A compact KPI tile: uppercase micro-label + glyph, a big tabular value, and a
/// small detail line. `accent` promotes it to the highlighted (signal) variant.
struct StatTile: View {
    var label: String
    var systemImage: String
    var value: String
    var detail: String? = nil
    var accent: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label).microLabel(accent ? Theme.accent.opacity(0.85) : Theme.ink3)
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.panelHi)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line, lineWidth: 1))
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent ? Theme.accent : Theme.ink2)
                }
                .frame(width: 26, height: 26)
            }
            Text(value)
                .font(.system(size: 27, weight: .bold)).numeric()
                .foregroundStyle(accent ? Theme.accent : Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
                .padding(.top, 13).padding(.bottom, 5)
            if let detail {
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.panel)
                .overlay(alignment: .top) {
                    if accent {
                        LinearGradient(colors: [Theme.accent.opacity(0.10), .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    }
                }
        )
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(accent ? Theme.accentLine : Theme.line, lineWidth: 1))
    }
}

/// A small custom segmented control matching the console look.
struct SegControl<T: Hashable>: View {
    var items: [(label: String, value: T)]
    @Binding var selection: T
    var accent: Bool = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                let on = item.value == selection
                Button {
                    selection = item.value
                } label: {
                    Text(item.label)
                        .font(.system(size: 11, weight: .semibold)).tracking(0.2)
                        .foregroundStyle(on ? (accent ? Theme.accent : Theme.ink) : Theme.ink2)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .frame(maxHeight: .infinity)
                        .background(on ? (accent ? Theme.accentDim : Theme.panelHi) : Color.clear)
                }
                .buttonStyle(.plain)
                if idx < items.count - 1 {
                    Rectangle().fill(Theme.line).frame(width: 1)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 28)
        .panelSkin(Theme.panel, border: Theme.line, radius: 8)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Small status pill: a colored dot (optionally with a soft halo) + text.
struct StatusDot: View {
    var color: Color
    var halo: Bool = true
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay(halo ? Circle().stroke(color.opacity(0.18), lineWidth: 3).scaleEffect(1.9) : nil)
    }
}

/// A left-title / uppercase-right-caption header for sections that aren't Panels.
struct PanelHeader: View {
    var title: String
    var caption: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            if let caption { Text(caption).microLabel() }
        }
    }
}

/// The app icon rendered as the sidebar mark — loads the bundled AppIcon so the
/// sidebar logo is byte-identical to the Dock icon (no drift, no overlap).
struct LogoMark: View {
    var size: CGFloat
    var body: some View {
        Group {
            if let icon = LogoMark.appIcon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(Color(hex: 0xF3F4F6))
                    .overlay(Text("A").font(.system(size: size * 0.58, weight: .heavy)).foregroundStyle(Color(hex: 0x23272E)))
            }
        }
        .frame(width: size, height: size)
    }

    static let appIcon: NSImage? = {
        if let u = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") { return NSImage(contentsOf: u) }
        return nil
    }()
}

/// Full-window dark canvas with the faint top-right accent bloom from the mockup.
struct AppCanvas: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            ZStack {
                Theme.bg
                RadialGradient(colors: [Theme.accent.opacity(0.05), .clear],
                               center: .init(x: 0.82, y: -0.05), startRadius: 0, endRadius: 620)
            }
            .ignoresSafeArea()
        )
    }
}

extension View {
    func appCanvas() -> some View { modifier(AppCanvas()) }
}

/// Configures the hosting NSWindow for the dark console look (transparent titlebar
/// that blends into the canvas, hidden title, dark background, sane min size).
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in
            guard let window = v?.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = Theme.bgNS
            window.isMovableByWindowBackground = false
            window.minSize = NSSize(width: 1040, height: 680)
            if let tb = window.toolbar { tb.isVisible = false }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
