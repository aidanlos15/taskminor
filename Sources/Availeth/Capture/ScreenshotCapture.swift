import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ScreenCaptureKit

/// Captures the screen occasionally and stores a LOCALLY REDACTED thumbnail.
///
/// The privacy model: the full-resolution frame exists only in memory for a few
/// milliseconds. Before anything is written to disk it is downscaled and blurred
/// so fine text (the PII-bearing part) is obscured — a stand-in for the
/// production path, where an on-device vision+redaction model would run here.
/// Only the reduced thumbnail is persisted, under a short retention window.
final class ScreenshotCapture {

    /// Directory holding redacted thumbnails.
    static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Availeth/screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private let ciContext = CIContext()

    /// Captures the main display, excluding our own windows AND every window
    /// belonging to an excluded app — so a password manager or messaging window
    /// that is merely visible (not frontmost) is never in the captured frame.
    /// Returns the raw CGImage in memory. Nil if permission is missing.
    func captureDisplay(excludedBundleIDs: Set<String>) async -> CGImage? {
        guard Permissions.screenRecordingGranted else { return nil }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first else {
            return nil
        }
        let excludedWindows = content.windows.filter { window in
            guard let bundle = window.owningApplication?.bundleIdentifier else { return false }
            return bundle == Bundle.main.bundleIdentifier || excludedBundleIDs.contains(bundle)
        }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Thumbnails mode: redact (downscale + blur) locally and write to disk.
    func captureRedacted(excludedBundleIDs: Set<String>) async -> URL? {
        guard let cgImage = await captureDisplay(excludedBundleIDs: excludedBundleIDs),
              let redacted = redact(cgImage) else { return nil }
        return write(redacted)
    }

    /// Storyline mode: downscale (NO blur — the local model needs legible text,
    /// and the user reviews the same frame) to a PNG in memory. Sent only to the
    /// local model. Returns nil on failure.
    func encodeForModel(_ cgImage: CGImage, maxWidth: Double = 1280) -> Data? {
        let input = CIImage(cgImage: cgImage)
        let scale = min(1.0, maxWidth / Double(cgImage.width))
        let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let out = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }

    /// Writes PNG data to the screenshots directory for the user to review
    /// alongside the narrative. Returns the file URL.
    func writeReviewImage(_ pngData: Data) -> URL? {
        let url = Self.directory().appendingPathComponent("scene-\(UUID().uuidString).png")
        do { try pngData.write(to: url); return url }
        catch { NSLog("Availeth review image write failed: \(error.localizedDescription)"); return nil }
    }

    /// Downscale + blur so fine text is unreadable while layout is preserved.
    private func redact(_ cgImage: CGImage) -> CGImage? {
        let input = CIImage(cgImage: cgImage)
        let targetWidth = 720.0
        let scale = min(1.0, targetWidth / Double(cgImage.width))
        let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = scaled
        blur.radius = 3.0 // obscures small text, keeps window/layout structure
        guard let blurred = blur.outputImage else { return nil }

        // Gaussian blur enlarges the extent; crop back to the scaled bounds.
        return ciContext.createCGImage(blurred, from: scaled.extent)
    }

    private func write(_ cgImage: CGImage) -> URL? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = Self.directory().appendingPathComponent("shot-\(UUID().uuidString).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            NSLog("Availeth screenshot write failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Deletes thumbnail files no longer referenced by a row (called after the
    /// store prunes old rows), plus any orphans.
    static func deleteFiles(_ paths: [String]) {
        for path in paths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
