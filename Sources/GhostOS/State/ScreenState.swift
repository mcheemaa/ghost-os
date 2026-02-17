// ScreenState.swift — The semantic screen model

import Foundation

/// The complete screen state at a point in time.
/// This is the core data structure that Ghost OS maintains continuously.
/// Agents query this instead of taking screenshots.
public struct ScreenState: Codable, Sendable {
    public let timestamp: Date
    public let frontmostApp: AppInfo?
    public let focusedElement: ElementNode?
    public let apps: [AppInfo]

    public init(
        timestamp: Date = Date(),
        frontmostApp: AppInfo?,
        focusedElement: ElementNode?,
        apps: [AppInfo]
    ) {
        self.timestamp = timestamp
        self.frontmostApp = frontmostApp
        self.focusedElement = focusedElement
        self.apps = apps
    }

    /// A compact text summary for injection into agent prompts
    public func summary() -> String {
        var lines: [String] = []
        lines.append("Screen State (\(apps.count) apps)")
        if let front = frontmostApp {
            lines.append("  Active: \(front.name)")
            for win in front.windows {
                var desc = win.title.flatMap({ $0.isEmpty ? nil : $0 }) ?? "(untitled)"
                if win.isMain { desc += " [main]" }
                if win.isFocused { desc += " [focused]" }
                if win.isMinimized { desc += " [minimized]" }
                lines.append("    Window: \"\(desc)\"")
            }
        }
        if let focused = focusedElement {
            lines.append("  Focused: \(focused.role) \"\(focused.label ?? "")\"")
        }
        let backgroundApps = apps.filter { $0.bundleId != frontmostApp?.bundleId }
        if !backgroundApps.isEmpty {
            let appDescs = backgroundApps.map { app in
                app.windows.isEmpty ? app.name : "\(app.name) (\(app.windows.count)w)"
            }
            lines.append("  Background: \(appDescs.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}

/// Information about a running application
public struct AppInfo: Codable, Sendable {
    public let name: String
    public let bundleId: String?
    public let pid: Int32
    public let isActive: Bool
    public let windows: [WindowInfo]

    public init(
        name: String,
        bundleId: String?,
        pid: Int32,
        isActive: Bool,
        windows: [WindowInfo]
    ) {
        self.name = name
        self.bundleId = bundleId
        self.pid = pid
        self.isActive = isActive
        self.windows = windows
    }
}

/// Information about a window
public struct WindowInfo: Codable, Sendable {
    public let title: String?
    public let position: CGPointCodable?
    public let size: CGSizeCodable?
    public let isMain: Bool
    public let isFocused: Bool
    public let isMinimized: Bool

    public init(
        title: String?,
        position: CGPointCodable?,
        size: CGSizeCodable?,
        isMain: Bool,
        isFocused: Bool,
        isMinimized: Bool
    ) {
        self.title = title
        self.position = position
        self.size = size
        self.isMain = isMain
        self.isFocused = isFocused
        self.isMinimized = isMinimized
    }
}
