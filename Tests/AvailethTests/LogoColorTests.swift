import AppKit
import XCTest
@testable import Availeth

/// Bars and dots take their colour from the app's own mark.
final class LogoColorTests: XCTestCase {

    private func mark(_ draw: (NSRect) -> Void) -> NSImage {
        let img = NSImage(size: NSSize(width: 64, height: 64))
        img.lockFocus()
        draw(NSRect(x: 0, y: 0, width: 64, height: 64))
        img.unlockFocus()
        return img
    }

    private func hsb(_ c: NSColor) -> (h: CGFloat, s: CGFloat, b: CGFloat) {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.usingColorSpace(.deviceRGB)!.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s, b)
    }

    func testVividMarkYieldsItsHue() {
        // Claude-ish terracotta on a white tile with a grey border.
        let img = mark { r in
            NSColor.white.setFill(); r.fill()
            NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1).setFill(); r.insetBy(dx: 12, dy: 12).fill()
            NSColor.gray.setStroke(); NSBezierPath(rect: r.insetBy(dx: 1, dy: 1)).stroke()
        }
        let c = LogoProvider.dominantColor(of: img)!
        let (h, s, b) = hsb(c)
        XCTAssertEqual(h, 15.0 / 360, accuracy: 0.05, "orange hue")
        XCTAssertGreaterThan(s, 0.4)
        XCTAssertLessThanOrEqual(b, 0.82, "clamped so it reads on a light panel")
    }

    func testPaleMarkIsDeepenedAndBlackMarkIsDarkGrey() {
        let pale = mark { r in NSColor(red: 1.0, green: 0.95, blue: 0.6, alpha: 1).setFill(); r.fill() }
        let (_, s, b) = hsb(LogoProvider.dominantColor(of: pale)!)
        XCTAssertGreaterThanOrEqual(s, 0.44, "saturation lifted to the floor")
        XCTAssertLessThanOrEqual(b, 0.821)

        let black = mark { r in NSColor.black.setFill(); r.insetBy(dx: 16, dy: 16).fill() }
        let (_, sb, bb) = hsb(LogoProvider.dominantColor(of: black)!)
        XCTAssertLessThan(sb, 0.05)
        XCTAssertLessThan(bb, 0.35, "a black glyph becomes a dark grey bar")

        let empty = NSImage(size: NSSize(width: 8, height: 8))
        XCTAssertNil(LogoProvider.dominantColor(of: empty))
    }

    /// Multi-colour brands get a decided colour, not the biggest arc.
    func testChromeIsGoogleBlueByRule() {
        for (unit, bundle) in [("Chrome", "com.google.Chrome"), ("Chrome", nil), ("Google Chrome", nil)] {
            let c = LogoProvider.shared.color(unit: unit, bundleID: bundle)
            XCTAssertNotNil(c, "\(unit)/\(bundle ?? "-")")
            let (h, s, _) = hsb(c!)
            XCTAssertEqual(h, 217.0 / 360, accuracy: 0.03, "Google blue for \(unit)")
            XCTAssertGreaterThan(s, 0.5)
        }
    }

    func testHourlyFoldKeepsTopAppsAndFoldsTheRest() {
        var rows: [HourlyActivity] = []
        for i in 0..<20 { rows.append(HourlyActivity(hour: 9, appName: "App \(i)", duration: Double(20 - i) * 60)) }
        rows.append(HourlyActivity(hour: 10, appName: "App 19", duration: 30))
        let (folded, apps) = OverviewView.foldHourly(rows)
        XCTAssertEqual(apps.count, 12, "eleven apps plus Other — twelve entries in all")
        XCTAssertEqual(apps.first, "App 0")
        XCTAssertEqual(apps[10], "App 10")
        XCTAssertEqual(apps.last, "Other")
        let other9 = folded.first { $0.appName == "Other" && $0.hour == 9 }
        XCTAssertEqual(other9?.duration, (1...9).reduce(0) { $0 + Double($1) * 60 }, "the nine smallest fold into Other")
        XCTAssertEqual(folded.first { $0.appName == "Other" && $0.hour == 10 }?.duration, 30)
        XCTAssertFalse(folded.contains { $0.appName == "App 11" })

        let (few, fewApps) = OverviewView.foldHourly(Array(rows.prefix(3)))
        XCTAssertEqual(few.count, 3)
        XCTAssertEqual(fewApps, ["App 0", "App 1", "App 2"], "no Other when everything fits")

        let (twelve, twelveApps) = OverviewView.foldHourly(Array(rows.prefix(12)))
        XCTAssertEqual(twelve.count, 12)
        XCTAssertFalse(twelveApps.contains("Other"), "exactly twelve apps need no Other")
    }
}
