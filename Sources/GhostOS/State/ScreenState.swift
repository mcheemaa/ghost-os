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
        let totalWindows = apps.reduce(0) { $0 + $1.windows.count }
        var lines: [String] = []
        lines.append("Screen State (\(apps.count) apps, \(totalWindows) windows)")
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
            let label = focused.label.flatMap({ $0.isEmpty ? nil : $0 })
            let labelStr = label != nil ? " \"\(label!)\"" : ""
            let appName = frontmostApp?.name
            let inApp = appName != nil ? " in \(appName!)" : ""
            lines.append("  Focused: \(focused.role)\(labelStr)\(inApp)")
        }
        let backgroundApps = apps.filter { $0.bundleId != frontmostApp?.bundleId }
        if !backgroundApps.isEmpty {
            let maxShown = 8
            let appDescs = backgroundApps.prefix(maxShown).map { app in
                app.windows.isEmpty ? app.name : "\(app.name) (\(app.windows.count)w)"
            }
            var bgLine = "  Background: \(appDescs.joined(separator: ", "))"
            if backgroundApps.count > maxShown {
                bgLine += ", ... +\(backgroundApps.count - maxShown) more"
            }
            lines.append(bgLine)
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

// MARK: - Context (Situational Awareness)

/// Rich context about the current app — everything an AI agent needs to understand
/// where it is and what it can do. One command, instant answer.
/// Works across all app types: web, native, Electron, terminal.
public struct ContextInfo: Codable, Sendable {
    public let app: String              // App name
    public let bundleId: String?        // Bundle identifier
    public let window: String?          // Active window title
    public let url: String?             // Page URL (web/Electron) or document path (native)
    public let pageTitle: String?       // Web page title or document name
    public let focused: FocusInfo?      // Currently focused element
    public let interactiveElements: [String]  // Nearby clickable/typeable things
    public let windowTabs: [String]     // Window titles (one per Chrome window, or tabs where available)

    public init(
        app: String,
        bundleId: String?,
        window: String?,
        url: String?,
        pageTitle: String?,
        focused: FocusInfo?,
        interactiveElements: [String],
        windowTabs: [String]
    ) {
        self.app = app
        self.bundleId = bundleId
        self.window = window
        self.url = url
        self.pageTitle = pageTitle
        self.focused = focused
        self.interactiveElements = interactiveElements
        self.windowTabs = windowTabs
    }

    /// Compact text summary for agent prompts
    public func summary() -> String {
        var lines: [String] = []
        lines.append("App: \(app)")
        if let window = window, !window.isEmpty {
            lines.append("Window: \(window)")
        }
        if let url = url {
            lines.append("URL: \(url)")
        }
        if let pageTitle = pageTitle, pageTitle != window {
            lines.append("Page: \(pageTitle)")
        }
        if let focused = focused {
            var focusDesc = focused.role
            if let label = focused.label, !label.isEmpty {
                focusDesc += " \"\(label)\""
            }
            if focused.isEditable {
                focusDesc += " [editable]"
            }
            if let val = focused.value, !val.isEmpty {
                focusDesc += " = \(val.prefix(50))"
            }
            lines.append("Focused: \(focusDesc)")
        }
        if !interactiveElements.isEmpty {
            let shown = interactiveElements.prefix(10)
            lines.append("Actions: \(shown.joined(separator: ", "))")
            if interactiveElements.count > 10 {
                lines.append("  ... +\(interactiveElements.count - 10) more")
            }
        }
        if windowTabs.count > 1 {
            lines.append("Windows/Tabs: \(windowTabs.count)")
            for (i, tab) in windowTabs.enumerated() {
                let marker = (tab == window) ? " *" : ""
                lines.append("  \(i + 1). \(tab)\(marker)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Info about the currently focused element
public struct FocusInfo: Codable, Sendable {
    public let role: String
    public let label: String?
    public let value: String?
    public let isEditable: Bool

    public init(role: String, label: String?, value: String?, isEditable: Bool) {
        self.role = role
        self.label = label
        self.value = value
        self.isEditable = isEditable
    }
}

// MARK: - Action Results

/// The result of any action command — includes what happened AND where we are now.
/// This is the key design: one command = action + verification.
public struct ActionResult: Codable, Sendable {
    public let success: Bool
    public let description: String    // "Pressed 'Compose' via AX-native"
    public let method: String         // "ax-native", "synthetic", "setValue", "typeText", "none"
    public let context: ContextInfo?  // post-action situational awareness
    public let screenshot: ScreenshotResult?  // optional visual capture (e.g. on failure for debugging)

    public init(success: Bool, description: String, method: String, context: ContextInfo?, screenshot: ScreenshotResult? = nil) {
        self.success = success
        self.description = description
        self.method = method
        self.context = context
        self.screenshot = screenshot
    }
}

// MARK: - Content Reading

/// A single piece of readable content extracted from the screen
public struct ContentItem: Codable, Sendable {
    public let type: String     // "heading", "text", "link", "button", "input", "image", "cell"
    public let text: String     // the actual readable text
    public let role: String     // AX role for context
    public let depth: Int       // nesting level (for indentation)

    public init(type: String, text: String, role: String, depth: Int) {
        self.type = type
        self.text = text
        self.role = role
        self.depth = depth
    }

    /// Render as a human-readable line
    public func render() -> String {
        let indent = String(repeating: "  ", count: min(depth, 4))
        switch type {
        case "heading":
            return "\(indent)# \(text)"
        case "link":
            return "\(indent)[\(text)]"
        case "button":
            return "\(indent)(\(text))"
        case "input":
            return "\(indent)[\(text)]"
        case "image":
            return "\(indent)[image: \(text)]"
        case "row":
            return "\(indent)> \(text)"
        case "control":
            return "\(indent)[\(text)]"
        case "list":
            return "\(indent)--- \(text) ---"
        default:
            return "\(indent)\(text)"
        }
    }
}

// MARK: - Screenshot

/// Result of a window screenshot capture.
/// Used for autonomous debugging: when AX fails, the agent sends this to a vision model.
public struct ScreenshotResult: Codable, Sendable {
    public let base64PNG: String     // Base64-encoded PNG image data
    public let width: Int            // Image width in pixels
    public let height: Int           // Image height in pixels
    public let windowTitle: String?  // Title of captured window

    public init(base64PNG: String, width: Int, height: Int, windowTitle: String?) {
        self.base64PNG = base64PNG
        self.width = width
        self.height = height
        self.windowTitle = windowTitle
    }
}

// MARK: - State Diffing

/// Represents changes between two screen states
public struct StateDiff: Codable, Sendable {
    public let timestamp: Date
    public let changes: [StateChange]

    public init(timestamp: Date = Date(), changes: [StateChange]) {
        self.timestamp = timestamp
        self.changes = changes
    }

    /// Is this a meaningful diff? (filters out noise)
    public var isSignificant: Bool {
        !changes.isEmpty
    }

    /// Human-readable summary of changes for agent prompts
    public func summary() -> String {
        guard !changes.isEmpty else { return "No changes" }
        var lines: [String] = ["Changes:"]
        for change in changes {
            lines.append("  \(change.description)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Individual state change between two snapshots
public enum StateChange: Sendable {
    case appActivated(name: String)
    case appLaunched(name: String)
    case appQuit(name: String)
    case windowOpened(app: String, title: String?)
    case windowClosed(app: String, title: String?)
    case windowTitleChanged(app: String, from: String?, to: String?)
    case focusChanged(app: String, element: String)

    var description: String {
        switch self {
        case .appActivated(let name):
            return "-> Switched to \(name)"
        case .appLaunched(let name):
            return "+ App launched: \(name)"
        case .appQuit(let name):
            return "- App quit: \(name)"
        case .windowOpened(let app, let title):
            let t = title ?? "(untitled)"
            return "+ Window opened: \"\(t)\" in \(app)"
        case .windowClosed(let app, let title):
            let t = title ?? "(untitled)"
            return "- Window closed: \"\(t)\" in \(app)"
        case .windowTitleChanged(let app, let from, let to):
            let f = from ?? "(untitled)"
            let t = to ?? "(untitled)"
            return "~ Window title: \"\(f)\" -> \"\(t)\" in \(app)"
        case .focusChanged(let app, let element):
            return "~ Focus: \(element) in \(app)"
        }
    }
}

// MARK: - StateChange Codable

extension StateChange: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, name, app, title, from, to, element
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "appActivated":
            let name = try container.decode(String.self, forKey: .name)
            self = .appActivated(name: name)
        case "appLaunched":
            let name = try container.decode(String.self, forKey: .name)
            self = .appLaunched(name: name)
        case "appQuit":
            let name = try container.decode(String.self, forKey: .name)
            self = .appQuit(name: name)
        case "windowOpened":
            let app = try container.decode(String.self, forKey: .app)
            let title = try container.decodeIfPresent(String.self, forKey: .title)
            self = .windowOpened(app: app, title: title)
        case "windowClosed":
            let app = try container.decode(String.self, forKey: .app)
            let title = try container.decodeIfPresent(String.self, forKey: .title)
            self = .windowClosed(app: app, title: title)
        case "windowTitleChanged":
            let app = try container.decode(String.self, forKey: .app)
            let from = try container.decodeIfPresent(String.self, forKey: .from)
            let to = try container.decodeIfPresent(String.self, forKey: .to)
            self = .windowTitleChanged(app: app, from: from, to: to)
        case "focusChanged":
            let app = try container.decode(String.self, forKey: .app)
            let element = try container.decode(String.self, forKey: .element)
            self = .focusChanged(app: app, element: element)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown StateChange type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .appActivated(let name):
            try container.encode("appActivated", forKey: .type)
            try container.encode(name, forKey: .name)
        case .appLaunched(let name):
            try container.encode("appLaunched", forKey: .type)
            try container.encode(name, forKey: .name)
        case .appQuit(let name):
            try container.encode("appQuit", forKey: .type)
            try container.encode(name, forKey: .name)
        case .windowOpened(let app, let title):
            try container.encode("windowOpened", forKey: .type)
            try container.encode(app, forKey: .app)
            try container.encodeIfPresent(title, forKey: .title)
        case .windowClosed(let app, let title):
            try container.encode("windowClosed", forKey: .type)
            try container.encode(app, forKey: .app)
            try container.encodeIfPresent(title, forKey: .title)
        case .windowTitleChanged(let app, let from, let to):
            try container.encode("windowTitleChanged", forKey: .type)
            try container.encode(app, forKey: .app)
            try container.encodeIfPresent(from, forKey: .from)
            try container.encodeIfPresent(to, forKey: .to)
        case .focusChanged(let app, let element):
            try container.encode("focusChanged", forKey: .type)
            try container.encode(app, forKey: .app)
            try container.encode(element, forKey: .element)
        }
    }
}
