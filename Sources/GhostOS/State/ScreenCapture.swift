// ScreenCapture.swift — Window screenshot capture via ScreenCaptureKit
//
// Ghost OS Layer 3 perception: when the AX tree can't see the content
// (canvas apps, PDFs, poorly coded UIs), capture the window as an image.
// Used for autonomous debugging — agent sends screenshot to a vision model
// to understand what went wrong when AX reports "element not found".
//
// This is NOT a replacement for AX — it's the escape hatch for when AX fails.

import AppKit
import Foundation
import ScreenCaptureKit

/// Captures screenshots of specific windows using ScreenCaptureKit.
/// Resizes to max 1280px width to keep base64 payload reasonable (~0.3-0.5MB).
///
/// Requires Screen Recording permission (System Settings > Privacy & Security > Screen Recording).
public enum ScreenCapture {

    /// Capture a specific window as a PNG image.
    /// Returns ScreenshotResult with base64-encoded PNG, or nil if capture fails.
    ///
    /// Uses ScreenCaptureKit — async, works for any on-screen window.
    /// Requires Screen Recording permission.
    public static func captureWindow(
        pid: pid_t,
        windowTitle: String? = nil
    ) async -> ScreenshotResult? {
        // 1. Get shareable content (ScreenCaptureKit's window list)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            fputs("[screenshot] Failed to get shareable content: \(error)\n", stderr)
            return nil
        }

        // 2. Find the target window — match by PID, optionally by title
        let pidWindows = content.windows.filter { $0.owningApplication?.processID == pid }

        let window: SCWindow?
        if let title = windowTitle {
            // Match by title
            window = pidWindows.first { $0.title?.localizedCaseInsensitiveContains(title) == true }
        } else {
            // No title specified — pick the largest window (main browser/app window)
            window = pidWindows
                .filter { $0.frame.width > 100 && $0.frame.height > 100 }
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
        }
        guard let window = window else { return nil }

        // 3. Configure capture — resize to max 1280px width, keep aspect ratio
        let maxWidth = 1280
        let config = SCStreamConfiguration()
        let aspect = window.frame.height / window.frame.width
        let captureWidth = min(maxWidth, Int(window.frame.width))
        config.width = captureWidth
        config.height = Int(CGFloat(captureWidth) * aspect)
        config.showsCursor = false

        // 4. Capture the window
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config
            )
        } catch {
            fputs("[screenshot] Capture failed: \(error)\n", stderr)
            return nil
        }

        // 5. Convert to PNG data
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else { return nil }

        return ScreenshotResult(
            base64PNG: pngData.base64EncodedString(),
            width: cgImage.width,
            height: cgImage.height,
            windowTitle: window.title
        )
    }

    /// Save a screenshot directly to a file. Returns the path on success.
    public static func captureWindowToFile(
        pid: pid_t,
        windowTitle: String? = nil,
        outputPath: String
    ) async -> String? {
        guard let result = await captureWindow(pid: pid, windowTitle: windowTitle),
              let data = Data(base64Encoded: result.base64PNG) else { return nil }

        do {
            try data.write(to: URL(fileURLWithPath: outputPath))
            return outputPath
        } catch {
            return nil
        }
    }
}
