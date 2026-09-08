import AppKit
import Foundation
import SwiftUI

enum Format {
    /// "3h 24m", "48m", "35s"
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 {
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(m)m"
    }

    /// "7m 18s" — used where sub-minute precision matters (median workflow duration).
    static func preciseDuration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 {
            let sec = s % 60
            return sec > 0 ? "\(s / 60)m \(sec)s" : "\(s / 60)m"
        }
        return duration(seconds)
    }

    /// "$29,400"
    static func money(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? "$\(Int(value))"
    }

    /// "Microsoft Excel" → "Excel", "Google Chrome" → "Chrome"
    static func shortApp(_ name: String) -> String {
        name.replacingOccurrences(of: "Microsoft ", with: "")
            .replacingOccurrences(of: "Google ", with: "")
    }

    /// "1,240 hrs"
    static func hours(_ hours: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = hours < 10 ? 1 : 0
        let n = f.string(from: NSNumber(value: hours)) ?? "\(Int(hours))"
        return "\(n) hrs"
    }
}

/// Stable, appearance-adaptive color per app name for charts and lists.
/// Each hue ships as a light/dark pair: darkened for text on light cards,
/// brightened for dark mode, so chip labels and annotations keep contrast.
enum AppPalette {
    private struct Hue {
        let light: NSColor
        let dark: NSColor
    }

    // Dark variants are a cohesive, slightly-desaturated "console" set — they sit
    // calmly on the near-black canvas and never fight the single blue accent.
    // (Light variants are retained for completeness though the app runs dark.)
    private static let hues: [Hue] = [
        Hue(light: NSColor(red: 0.29, green: 0.33, blue: 0.85, alpha: 1), dark: NSColor(red: 0.43, green: 0.54, blue: 0.90, alpha: 1)), // blue
        Hue(light: NSColor(red: 0.00, green: 0.48, blue: 0.43, alpha: 1), dark: NSColor(red: 0.33, green: 0.72, blue: 0.57, alpha: 1)), // green
        Hue(light: NSColor(red: 0.78, green: 0.38, blue: 0.08, alpha: 1), dark: NSColor(red: 0.85, green: 0.54, blue: 0.36, alpha: 1)), // orange
        Hue(light: NSColor(red: 0.74, green: 0.18, blue: 0.42, alpha: 1), dark: NSColor(red: 0.78, green: 0.49, blue: 0.73, alpha: 1)), // pink
        Hue(light: NSColor(red: 0.44, green: 0.30, blue: 0.85, alpha: 1), dark: NSColor(red: 0.56, green: 0.49, blue: 0.88, alpha: 1)), // violet
        Hue(light: NSColor(red: 0.08, green: 0.44, blue: 0.72, alpha: 1), dark: NSColor(red: 0.40, green: 0.66, blue: 0.90, alpha: 1)), // sky
        Hue(light: NSColor(red: 0.28, green: 0.52, blue: 0.13, alpha: 1), dark: NSColor(red: 0.55, green: 0.72, blue: 0.42, alpha: 1)), // moss
        Hue(light: NSColor(red: 0.66, green: 0.46, blue: 0.02, alpha: 1), dark: NSColor(red: 0.88, green: 0.64, blue: 0.30, alpha: 1)), // amber
        Hue(light: NSColor(red: 0.54, green: 0.23, blue: 0.68, alpha: 1), dark: NSColor(red: 0.69, green: 0.49, blue: 0.84, alpha: 1)), // purple
        Hue(light: NSColor(red: 0.72, green: 0.22, blue: 0.18, alpha: 1), dark: NSColor(red: 0.87, green: 0.47, blue: 0.42, alpha: 1)), // red
    ]

    static func color(for name: String) -> Color {
        // FNV-1a for a stable hash across launches (Hashable is seeded per-process).
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let hue = hues[Int(hash % UInt64(hues.count))]
        let dynamic = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? hue.dark : hue.light
        }
        return Color(nsColor: dynamic)
    }
}
