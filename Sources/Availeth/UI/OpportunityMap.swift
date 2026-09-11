import AppKit
import SwiftUI

// The visual language of the Automation Opportunity Map: real app logos in
// chips, animated flow connectors between them, and automatable/needs-a-person
// pills. Shared by the Workflows and Tasks screens.

/// Resolves a logo for a workflow unit, in order of fidelity:
/// 1. the real icon of an installed app (when the unit is an app we saw a bundle id for),
/// 2. a bundled brand mark for a known web service (Resources/Logos/<key>.svg),
///    by unit name or by the site's domain,
/// 3. the site's own favicon, from the browser's cache on this Mac (SiteIconStore),
/// 4. nil — callers draw a lettermark.
///
/// Every result is rasterised ONCE, off the main thread, into a small bitmap and
/// cached, so drawing a row is a blit — never a LaunchServices lookup, an icns
/// decode or an SVG parse. `cached(...)` is the only call a view body may make.
/// `generation` ticks when a site's icon arrives so rows already on screen repaint.
final class LogoProvider: ObservableObject, @unchecked Sendable {
    static let shared = LogoProvider()

    enum Lookup { case unknown, resolved(NSImage?) }

    @Published private(set) var generation = 0

    private var cache: [String: NSImage?] = [:]
    private let lock = NSLock()

    /// Marks that ship near-black: rendered as templates and tinted with the ink
    /// colour so they read on both light and dark panels.
    private static let templateKeys: Set<String> = ["chatgpt", "github", "notion", "confluence", "zendesk"]

    /// "Google Sheets" → "googlesheets", "NetSuite" → "netsuite".
    static func key(for unit: String) -> String {
        String(unit.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func cacheKey(_ unit: String, _ bundleID: String?, _ site: String?) -> String {
        (bundleID ?? "") + "|" + (site ?? "") + "|" + key(for: unit)
    }

    /// Non-blocking: what the cache knows right now. Safe from any view body.
    func cached(unit: String, bundleID: String?, site: String? = nil) -> Lookup {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[Self.cacheKey(unit, bundleID, site)] { return .resolved(hit) }
        return .unknown
    }

    /// Resolves (and caches) a logo. Does disk/IPC work on a miss — call it off
    /// the main thread (`prewarm` / `load`), never from a view body. `site` is
    /// the registrable domain the unit was seen on (browser tabs only).
    func image(unit: String, bundleID: String?, site: String? = nil) -> NSImage? {
        let k = Self.cacheKey(unit, bundleID, site)
        lock.lock()
        if let hit = cache[k] { lock.unlock(); return hit }
        lock.unlock()

        var img: NSImage?
        if let b = bundleID, !b.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) {
            img = Self.bitmap(NSWorkspace.shared.icon(forFile: url.path))
        }
        if img == nil { img = Self.bundledMark(Self.key(for: unit)) }
        if img == nil, let site, let markKey = HostNormalizer.bundledMark(host: site) { img = Self.bundledMark(markKey) }
        if img == nil, let site, let disk = SiteIconStore.shared.cachedImage(domain: HostNormalizer.iconKey(host: site)) {
            img = Self.bitmap(disk)
        }
        lock.lock(); cache[k] = img; lock.unlock()
        return img
    }

    private var colors: [String: NSColor?] = [:]

    /// Brands whose mark is many colours at once, so "the primary colour" is a
    /// decision, not a measurement: Chrome is Google blue, not the yellow arc
    /// that happens to cover the most pixels. Keyed by bundle id and by unit key.
    private static let brandColors: [String: NSColor] = {
        func hex(_ v: UInt32) -> NSColor {
            NSColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        let blue = hex(0x4285F4)
        return [
            "com.google.Chrome": blue, "com.google.Chrome.canary": blue, "org.chromium.Chromium": blue, "chrome": blue, "chromium": blue,
            "com.apple.Safari": hex(0x006CFF), "safari": hex(0x006CFF),
            "com.tinyspeck.slackmacgap": hex(0x4A154B), "slack": hex(0x4A154B),
            "com.microsoft.Excel": hex(0x1D6F42), "excel": hex(0x1D6F42),
            "com.microsoft.Word": hex(0x2B579A), "word": hex(0x2B579A),
            "com.microsoft.Outlook": hex(0x0F6CBD), "outlook": hex(0x0F6CBD),
            "com.microsoft.teams2": hex(0x5B5FC7), "com.microsoft.teams": hex(0x5B5FC7), "teams": hex(0x5B5FC7),
            "com.microsoft.Powerpoint": hex(0xC43E1C),
            "com.apple.finder": hex(0x1E8CF0), "finder": hex(0x1E8CF0),
        ]
    }()

    /// The logo's primary colour — for bars and dots that stand for the app.
    /// A known brand's colour when we have one; otherwise derived from the
    /// rasterised mark: its most-present vivid hue, or a dark grey for a
    /// near-black mark. nil when there is no logo. Cached like images; call off
    /// the main thread (prewarm does).
    func color(unit: String, bundleID: String?, site: String? = nil) -> NSColor? {
        let k = Self.cacheKey(unit, bundleID, site)
        lock.lock()
        if let hit = colors[k] { lock.unlock(); return hit }
        lock.unlock()
        var c: NSColor?
        if let b = bundleID, let brand = Self.brandColors[b] { c = brand }
        else if let brand = Self.brandColors[Self.key(for: unit)] ?? Self.brandColors[Self.key(for: WorkflowUnit.shortApp(unit))] { c = brand }
        else if let img = image(unit: unit, bundleID: bundleID, site: site) {
            c = img.isTemplate ? NSColor(white: 0.28, alpha: 1) : Self.dominantColor(of: img)
        }
        lock.lock(); colors[k] = c; lock.unlock()
        return c
    }

    /// The most-present vivid hue in a mark, averaged and clamped to a shade
    /// that reads as a bar on a light panel; a dark grey for a mark that has
    /// no vivid pixels (a black glyph); nil for nothing but white/transparent.
    static func dominantColor(of image: NSImage, px: Int = 24) -> NSColor? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .sourceOver, fraction: 1)
        guard let data = rep.bitmapData else { return nil }
        let bpr = rep.bytesPerRow, spp = rep.samplesPerPixel

        var bins = [(w: Double, r: Double, g: Double, b: Double)](repeating: (0, 0, 0, 0), count: 24)
        var dark = (n: 0.0, r: 0.0, g: 0.0, b: 0.0)
        for y in 0..<px {
            for x in 0..<px {
                let p = y * bpr + x * spp
                let a = Double(data[p + 3]) / 255
                guard a > 0.5 else { continue }
                // Premultiplied alpha → straight colour.
                let r = min(1, Double(data[p]) / 255 / a), g = min(1, Double(data[p + 1]) / 255 / a), b = min(1, Double(data[p + 2]) / 255 / a)
                let hi = max(r, g, b), lo = min(r, g, b)
                let bri = hi, sat = hi > 0 ? (hi - lo) / hi : 0
                if bri < 0.12 { dark.n += 1; dark.r += r; dark.g += g; dark.b += b; continue }
                if sat < 0.25 || (bri > 0.97 && sat < 0.35) { continue }         // grey, white
                var hue: Double
                if hi == lo { hue = 0 }
                else if hi == r { hue = ((g - b) / (hi - lo)).truncatingRemainder(dividingBy: 6) }
                else if hi == g { hue = (b - r) / (hi - lo) + 2 }
                else { hue = (r - g) / (hi - lo) + 4 }
                if hue < 0 { hue += 6 }
                let bin = min(23, Int(hue / 6 * 24))
                let w = sat * (0.3 + 0.7 * bri)
                bins[bin].w += w; bins[bin].r += r * w; bins[bin].g += g * w; bins[bin].b += b * w
            }
        }
        if let best = bins.max(by: { $0.w < $1.w }), best.w > 3 {
            let c = NSColor(red: best.r / best.w, green: best.g / best.w, blue: best.b / best.w, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, al: CGFloat = 0
            c.getHue(&h, saturation: &s, brightness: &v, alpha: &al)
            return NSColor(hue: h, saturation: max(s, 0.45), brightness: min(max(v, 0.45), 0.82), alpha: 1)
        }
        if dark.n > 0 {
            return NSColor(red: 0.2 + dark.r / dark.n * 0.4, green: 0.2 + dark.g / dark.n * 0.4, blue: 0.2 + dark.b / dark.n * 0.4, alpha: 1)
        }
        return nil
    }

    /// Resources/Logos/<key>.svg, rasterised; near-black marks become templates.
    private static func bundledMark(_ key: String) -> NSImage? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Logos/\(key).svg"),
              FileManager.default.fileExists(atPath: url.path),
              let svg = NSImage(contentsOf: url) else { return nil }
        let img = bitmap(svg)
        if templateKeys.contains(key) { img?.isTemplate = true }
        return img
    }

    /// Async resolve for a single logo a row discovered before the prewarm reached it.
    func load(unit: String, bundleID: String?, site: String? = nil) async -> NSImage? {
        await Task.detached(priority: .userInitiated) { self.image(unit: unit, bundleID: bundleID, site: site) }.value
    }

    /// Warms the cache for a set of units. Call off the main thread.
    func prewarm(units: [String], bundles: [String: String], sites: [String: String] = [:]) {
        for u in units { _ = image(unit: u, bundleID: bundles[u], site: sites[u]) }
    }

    /// Forgets every entry for a site (both maps) — see `invalidate(site:)` callers.
    private func dropEntries(where remove: (String) -> Bool) {
        cache = cache.filter { !remove($0.key) }
        colors = colors.filter { !remove($0.key) }
    }

    /// Forgets every entry whose site stores under this icon key, so a freshly
    /// stored icon is picked up, and ticks `generation` so rows on screen re-resolve.
    func invalidate(site iconKey: String) {
        lock.lock()
        dropEntries { key in
            let site = key.split(separator: "|", omittingEmptySubsequences: false)[1]
            return !site.isEmpty && HostNormalizer.iconKey(host: String(site)) == iconKey
        }
        lock.unlock()
        DispatchQueue.main.async { self.generation &+= 1 }
    }

    /// Forgets every site-keyed entry (after the icon files were deleted).
    func invalidateAllSites() {
        lock.lock()
        dropEntries { !$0.split(separator: "|", omittingEmptySubsequences: false)[1].isEmpty }
        lock.unlock()
        DispatchQueue.main.async { self.generation &+= 1 }
    }

    /// unit label → bundle id, from spans a screen has already loaded. Only for
    /// units that ARE an app; browser sites resolve to the bundled marks instead.
    static func bundleMap(_ spans: [ActivitySpan]) -> [String: String] {
        var m: [String: String] = [:]
        for s in spans {
            let unit = WorkflowUnit.label(app: s.appName, title: s.windowTitle)
            if unit == WorkflowUnit.shortApp(s.appName), m[unit] == nil { m[unit] = s.bundleID }
        }
        return m
    }

    /// unit label → page host, from browser spans that carried one. The
    /// most-seen host per unit wins, so one stray tab can't swap an icon. The
    /// full host is kept (docs.google.com, not google.com) so host-specific
    /// marks resolve; the icon key is derived where needed.
    static func siteMap(_ spans: [ActivitySpan]) -> [String: String] {
        var counts: [String: [String: Int]] = [:]
        for s in spans where !s.pageHost.isEmpty && WorkflowUnit.browsers.contains(s.appName) {
            let unit = WorkflowUnit.label(app: s.appName, title: s.windowTitle)
            counts[unit, default: [:]][s.pageHost, default: 0] += 1
        }
        return counts.compactMapValues { $0.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key }
    }

    /// Every page host in these spans — for a catch-up icon request.
    static func hosts(_ spans: [ActivitySpan]) -> Set<String> {
        Set(spans.map(\.pageHost).filter { !$0.isEmpty })
    }

    /// Rasterises any NSImage (icns, SVG, whatever) into a 128 px bitmap at a
    /// 64 pt logical size, aspect-fit and centred. Runs fine on a background
    /// thread: NSGraphicsContext.current is thread-local.
    private static func bitmap(_ src: NSImage, px: Int = 128, logical: CGFloat = 64) -> NSImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: logical, height: logical)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        let s = src.size
        let scale = min(logical / max(s.width, 1), logical / max(s.height, 1))
        let w = s.width * scale, h = s.height * scale
        src.draw(in: NSRect(x: (logical - w) / 2, y: (logical - h) / 2, width: w, height: h),
                 from: .zero, operation: .sourceOver, fraction: 1)
        let out = NSImage(size: NSSize(width: logical, height: logical))
        out.addRepresentation(rep)
        return out
    }
}

/// A unit's logo at a given size, with a coloured lettermark when no logo exists
/// (or until an uncached one loads). Never blocks the main thread.
struct AppLogoView: View {
    var unit: String
    var bundleID: String? = nil
    var site: String? = nil
    var size: CGFloat = 15

    @State private var loaded: NSImage?
    @ObservedObject private var provider = LogoProvider.shared

    private var resolved: NSImage? {
        if case .resolved(let img) = provider.cached(unit: unit, bundleID: bundleID, site: site) { return img }
        return loaded
    }

    var body: some View {
        Group {
            if let img = resolved {
                Image(nsImage: img)
                    .renderingMode(img.isTemplate ? .template : .original)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Theme.ink)
            } else {
                ZStack {
                    Circle().fill(AppPalette.color(for: unit).opacity(0.18))
                    Text(String(unit.prefix(1)).uppercased())
                        .font(.system(size: size * 0.58, weight: .bold))
                        .foregroundStyle(AppPalette.color(for: unit))
                }
            }
        }
        .frame(width: size, height: size)
        .task(id: "\(provider.generation)|\(bundleID ?? "")|\(site ?? "")|\(unit)") {
            if case .unknown = provider.cached(unit: unit, bundleID: bundleID, site: site) {
                loaded = await provider.load(unit: unit, bundleID: bundleID, site: site)
            }
        }
    }
}

/// Logo + name in a soft capsule — one step of a workflow.
struct LogoChip: View {
    var unit: String
    var bundleID: String? = nil
    var site: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            AppLogoView(unit: unit, bundleID: bundleID, site: site, size: 15)
            Text(unit)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
        .padding(.leading, 8).padding(.trailing, 10).padding(.vertical, 5)
        .background(Capsule().fill(Theme.panelHi))
        .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// The short line between two chips, with a dot flowing along it — data moving
/// from one app to the next. Driven by a shared clock (`phase`) so a whole row
/// costs one invalidation per frame; `delay` is a phase offset, so connectors
/// stay evenly staggered forever.
struct FlowConnector: View {
    var phase: TimeInterval
    var delay: Double = 0
    var animating: Bool = true

    private static let period = 3.2, travel = 1.9, ramp = 0.25

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.line2).frame(width: 30, height: 2)
            if animating {
                let raw = (phase - delay).truncatingRemainder(dividingBy: Self.period)
                let t = raw < 0 ? raw + Self.period : raw
                if t < Self.travel {
                    let k = t / Self.travel
                    let eased = k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2
                    let o = max(0, min(1, min(t / Self.ramp, (Self.travel - t) / Self.ramp)))
                    Circle().fill(Theme.accent)
                        .frame(width: 6, height: 6)
                        .offset(x: 24 * eased)
                        .opacity(o)
                }
            }
        }
        .frame(width: 30, height: 26)
    }
}

/// Chips joined by flow connectors, wrapping onto new lines when a workflow is
/// long. One TimelineView per chain; it pauses under Reduce Motion, while the
/// window is inactive, or when the caller says so (e.g. a sheet is up).
struct UnitChain: View {
    var units: [String]
    var bundles: [String: String]
    var sites: [String: String] = [:]
    var stagger: Double = 0
    var animating: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let live = animating && !reduceMotion && activeState != .inactive
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !live)) { ctx in
            let phase = ctx.date.timeIntervalSinceReferenceDate
            WrapLayout(hSpacing: 6, vSpacing: 6) {
                ForEach(Array(units.enumerated()), id: \.offset) { i, u in
                    if i > 0 { FlowConnector(phase: phase, delay: stagger + Double(i) * 0.18, animating: live) }
                    LogoChip(unit: u, bundleID: bundles[u], site: sites[u])
                }
            }
        }
    }
}

/// AUTOMATABLE (accent) or NEEDS A PERSON (muted).
struct AutomationPill: View {
    var automatable: Bool

    var body: some View {
        Text(automatable ? "AUTOMATABLE" : "NEEDS A PERSON")
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(automatable ? Theme.accent : Theme.ink3)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(automatable ? Theme.accentDim : Theme.panelHi))
    }
}

/// Minimal left-to-right wrapping layout. Items share a row height (chips and
/// connectors are both 26pt), so top alignment reads as centred.
struct WrapLayout: Layout {
    var hSpacing: CGFloat = 6
    var vSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { x = 0; y += rowH + vSpacing; rowH = 0 }
            x += sz.width + hSpacing
            rowH = max(rowH, sz.height)
            width = max(width, x - hSpacing)
        }
        return CGSize(width: maxW == .infinity ? width : min(width, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + vSpacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + hSpacing
            rowH = max(rowH, sz.height)
        }
    }
}

/// Small neutral capsule label used in panel headers ("Week · your Mac").
struct HeaderBadge: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(Theme.panelHi))
    }
}
