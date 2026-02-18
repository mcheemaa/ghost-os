// main.swift — Ghost OS CLI tool
// Usage:
//   ghost daemon start          Start the daemon (foreground)
//   ghost daemon status         Check if daemon is running
//   ghost state                 Print full screen state (JSON)
//   ghost state --summary       Compact text summary
//   ghost state --app Chrome    State for specific app
//   ghost tree                  Dump element tree of frontmost app
//   ghost tree --app Chrome     Dump tree for specific app
//   ghost tree --depth 8        Limit depth (default 5)
//   ghost find "Search"         Find elements matching query
//   ghost find --role button    Filter by role
//   ghost click "Compose"       Smart click — fuzzy find + click
//   ghost click --at 680,52     Click at coordinates
//   ghost type "Hello world"    Type text
//   ghost press return          Press a key
//   ghost hotkey cmd,s           Key combo
//   ghost focus Chrome           Focus an app
//   ghost diff                   Show what changed since last check
//   ghost watch                  Continuous state change monitoring
//   ghost context                Where am I? URL, focused element, actions
//   ghost describe               Natural language screen description
//   ghost permissions            Check accessibility permissions

import Foundation
import GhostOS

@MainActor
func main() async {
    let args = Array(CommandLine.arguments.dropFirst())

    guard !args.isEmpty else {
        printUsage()
        return
    }

    let command = args[0]
    let subArgs = Array(args.dropFirst())

    switch command {
    case "daemon":
        await handleDaemon(subArgs)
    case "state":
        await handleState(subArgs)
    case "tree":
        await handleTree(subArgs)
    case "find":
        await handleFind(subArgs)
    case "click":
        await handleClick(subArgs)
    case "type":
        await handleType(subArgs)
    case "press":
        await handlePress(subArgs)
    case "hotkey":
        await handleHotkey(subArgs)
    case "focus":
        await handleFocus(subArgs)
    case "wait":
        await handleWait(subArgs)
    case "scroll":
        await handleScroll(subArgs)
    case "diff":
        await handleDiff(subArgs)
    case "watch":
        await handleWatch(subArgs)
    case "read":
        await handleRead(subArgs)
    case "context":
        await handleContext(subArgs)
    case "describe":
        await handleDescribe(subArgs)
    case "permissions":
        await handlePermissions()
    case "help", "--help", "-h":
        printUsage()
    default:
        print("Unknown command: \(command)")
        printUsage()
    }
}

// MARK: - Command Handlers

@MainActor
func handleDaemon(_ args: [String]) async {
    let subcommand = args.first ?? "start"

    switch subcommand {
    case "start":
        let daemon = GhostDaemon()
        do {
            try daemon.start()
            // GhostDaemon installs its own signal handlers for graceful shutdown.
            // Block forever — daemon runs until SIGINT/SIGTERM.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in
                // Never resumes
            }
        } catch {
            print("Error: \(error)")
            exit(1)
        }

    case "status":
        if GhostDaemon.isDaemonRunning() {
            print("Ghost daemon is running")
            if let pid = GhostDaemon.existingDaemonPID() {
                print("PID: \(pid)")
            }
            print("Socket: \(IPCServer.defaultSocketPath())")
        } else {
            print("Ghost daemon is NOT running")
            exit(1)
        }

    case "stop":
        if let pid = GhostDaemon.existingDaemonPID() {
            kill(pid, SIGTERM)
            print("Sent SIGTERM to daemon (PID \(pid))")
        } else {
            print("Ghost daemon is not running")
            exit(1)
        }

    default:
        print("Usage: ghost daemon [start|stop|status]")
    }
}

@MainActor
func handleState(_ args: [String]) async {
    let useSummary = args.contains("--summary") || args.contains("-s")
    let appName = flagValue(args, flag: "--app")

    // Try daemon first, fall back to direct mode
    if let response = trySendToDaemon(method: "getState", params: RPCParams(app: appName)) {
        if useSummary, case let .state(state) = response.result {
            print(state.summary())
        } else {
            printJSON(response)
        }
        return
    }

    // Direct mode (no daemon)
    let daemon = directDaemon()
    let state = daemon.getState()

    if let app = appName {
        if let appInfo = state.apps.first(where: { $0.name.localizedCaseInsensitiveContains(app) }) {
            printJSON(appInfo)
        } else {
            print("App '\(app)' not found")
        }
    } else if useSummary {
        print(state.summary())
    } else {
        printJSON(state)
    }
}

@MainActor
func handleTree(_ args: [String]) async {
    let appName = flagValue(args, flag: "--app")
    let depthStr = flagValue(args, flag: "--depth")
    let depth = depthStr.flatMap(Int.init) ?? 5
    let useJSON = args.contains("--json")

    // Try daemon first
    if let response = trySendToDaemon(
        method: "getTree",
        params: RPCParams(app: appName, depth: depth)
    ) {
        if !useJSON, case let .tree(tree) = response.result {
            print(tree.renderTree())
        } else {
            printJSON(response)
        }
        return
    }

    // Direct mode
    let daemon = directDaemon()
    guard let tree = daemon.getTree(app: appName, depth: depth) else {
        print("No app found\(appName.map { " matching '\($0)'" } ?? "")")
        return
    }

    if useJSON {
        printJSON(tree)
    } else {
        print(tree.renderTree())
    }
}

@MainActor
func handleFind(_ args: [String]) async {
    let role = flagValue(args, flag: "--role")
    let appName = flagValue(args, flag: "--app")
    let limitStr = flagValue(args, flag: "--limit")
    let limit = limitStr.flatMap(Int.init) ?? 20
    let useSmart = args.contains("--smart")
    let useDeep = args.contains("--deep")

    // Collect flag values so we can exclude them from the query
    let flagValues: Set<String> = Set(
        ["--role", "--app", "--limit"].compactMap { flagValue(args, flag: $0) }
    )
    let query = args.first(where: { !$0.hasPrefix("-") && !flagValues.contains($0) }) ?? ""

    guard !query.isEmpty || role != nil else {
        print("Usage: ghost find <query> [--role button] [--app Chrome] [--smart] [--deep] [--limit 20]")
        return
    }

    // Deep mode: skip menus, search from content root with depth 15
    if useDeep {
        let daemon = directDaemon()
        let elements = daemon.findElementsDeep(query: query, role: role, app: appName)
        if elements.isEmpty {
            print("No elements found (deep search)")
        } else {
            print("Found \(elements.count) elements:")
            for el in elements.prefix(limit) {
                let label = el.label ?? el.id
                let pos = el.position.map { " at (\(Int($0.x)),\(Int($0.y)))" } ?? ""
                let val = el.value.map { " = \($0)" } ?? ""
                print("  \(el.role) \"\(label)\"\(val)\(pos)")
            }
        }
        return
    }

    // Smart mode uses SmartResolver for fuzzy, scored matching
    // Strategy: search content tree first, then full app tree, merge results preferring content
    if useSmart {
        let daemon = directDaemon()
        let resolver = SmartResolver()
        var allMatches: [ResolvedElement] = []

        // Search content tree first (in-page elements get priority)
        if let contentTree = daemon.getContentTree(app: appName, depth: 15) {
            let contentMatches = resolver.resolve(
                query: query.isEmpty ? "" : query,
                role: role,
                in: contentTree,
                limit: limit
            )
            allMatches.append(contentsOf: contentMatches)
        }

        // Also search full app tree (menus, toolbar) — but only add if we need more results
        if allMatches.count < limit {
            if let fullTree = daemon.getTree(app: appName, depth: 8) {
                let fullMatches = resolver.resolve(
                    query: query.isEmpty ? "" : query,
                    role: role,
                    in: fullTree,
                    limit: limit
                )
                // Only add matches from full tree that aren't duplicates of content matches
                let contentLabels = Set(allMatches.map { $0.node.label ?? $0.node.id })
                for match in fullMatches {
                    let label = match.node.label ?? match.node.id
                    if !contentLabels.contains(label) {
                        allMatches.append(match)
                    }
                }
            }
        }

        // Sort: content matches first (higher score from deeper tree), then full tree
        allMatches.sort { $0.score > $1.score }
        let topMatches = Array(allMatches.prefix(limit))

        if topMatches.isEmpty {
            print("No matches found")
        } else {
            for (i, match) in topMatches.enumerated() {
                let label = match.node.label ?? match.node.id
                let pos = match.node.position.map {
                    " at (\(Int($0.x)),\(Int($0.y)))"
                } ?? ""
                print("  \(i + 1). [\(match.score)] \(match.node.role) \"\(label)\"\(pos) — \(match.matchReason)")
            }
        }
        return
    }

    if let response = trySendToDaemon(
        method: "findElements",
        params: RPCParams(query: query.isEmpty ? nil : query, role: role, app: appName)
    ) {
        printJSON(response)
        return
    }

    // Direct mode
    let daemon = directDaemon()
    let elements = daemon.findElements(query: query, role: role, app: appName)
    if elements.isEmpty {
        print("No elements found")
    } else {
        printJSON(elements)
    }
}

@MainActor
func handleClick(_ args: [String]) async {
    // Coordinate mode: ghost click --at x,y
    if let coordStr = flagValue(args, flag: "--at") {
        let parts = coordStr.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else {
            print("Usage: ghost click --at x,y (e.g., --at 680,52)")
            return
        }
        let params = RPCParams(x: parts[0], y: parts[1])
        if let response = trySendToDaemon(method: "click", params: params) {
            printResult(response)
        } else {
            let daemon = directDaemon()
            let result = daemon.execute(action: "click", params: params)
            printResult(result)
        }
        return
    }

    // Label mode: ghost click "Compose" --app Chrome
    let appName = flagValue(args, flag: "--app")
    let flagValues: Set<String> = Set(
        ["--app"].compactMap { flagValue(args, flag: $0) }
    )
    let target = args.first(where: { !$0.hasPrefix("-") && !flagValues.contains($0) }) ?? ""
    guard !target.isEmpty else {
        print("Usage: ghost click <label> [--app name] or ghost click --at x,y")
        return
    }

    // Try daemon first
    if let response = trySendToDaemon(
        method: "smartClick",
        params: RPCParams(target: target, app: appName)
    ) {
        printResult(response)
        return
    }

    // Direct mode: smart click with AX-native first strategy
    let daemon = directDaemon()
    let result = daemon.smartClick(query: target, app: appName)
    printActionResult(result)
}

@MainActor
func handleType(_ args: [String]) async {
    let appName = flagValue(args, flag: "--app")
    let target = flagValue(args, flag: "--into")

    // Remove flags from text
    let flagKeys: Set<String> = ["--app", "--into", "--delay"]
    let flagVals: Set<String> = Set(
        flagKeys.compactMap { flagValue(args, flag: $0) }
    )
    let text = args.filter { !$0.hasPrefix("-") && !flagVals.contains($0) }.joined(separator: " ")
    guard !text.isEmpty else {
        print("Usage: ghost type <text> [--into <field>] [--app <name>]")
        return
    }

    // Smart type — handles --into and --app with AX-native first strategy
    if target != nil || appName != nil {
        // Try daemon first
        if let response = trySendToDaemon(
            method: "smartType",
            params: RPCParams(target: target, text: text, app: appName)
        ) {
            printResult(response)
            return
        }
        // Direct mode
        let daemon = directDaemon()
        let result = daemon.smartType(text: text, target: target, app: appName)
        printActionResult(result)
        return
    }

    // Simple type at current focus (no target, no app)
    let params = RPCParams(text: text)
    if let response = trySendToDaemon(method: "type", params: params) {
        printResult(response)
    } else {
        let daemon = directDaemon()
        let result = daemon.smartType(text: text)
        printActionResult(result)
    }
}

@MainActor
func handlePress(_ args: [String]) async {
    guard let key = args.first else {
        print("Usage: ghost press <key> (return, tab, escape, space, delete, up, down, left, right)")
        return
    }
    let params = RPCParams(key: key)
    if let response = trySendToDaemon(method: "press", params: params) {
        printResult(response)
    } else {
        let daemon = directDaemon()
        let result = daemon.execute(action: "press", params: params)
        printResult(result)
    }
}

@MainActor
func handleHotkey(_ args: [String]) async {
    guard let keysStr = args.first else {
        print("Usage: ghost hotkey cmd,s (comma-separated modifiers and key)")
        return
    }
    let keys = keysStr.split(separator: ",").map { String($0) }
    let params = RPCParams(keys: keys)
    if let response = trySendToDaemon(method: "hotkey", params: params) {
        printResult(response)
    } else {
        let daemon = directDaemon()
        let result = daemon.execute(action: "hotkey", params: params)
        printResult(result)
    }
}

@MainActor
func handleScroll(_ args: [String]) async {
    let direction = args.first(where: { !$0.hasPrefix("-") }) ?? "down"
    let amountStr = flagValue(args, flag: "--amount")
    let amount = amountStr.flatMap(Double.init) ?? 3.0
    let params = RPCParams(direction: direction, amount: amount)
    if let response = trySendToDaemon(method: "scroll", params: params) {
        printResult(response)
    } else {
        let daemon = directDaemon()
        let result = daemon.execute(action: "scroll", params: params)
        printResult(result)
    }
}

@MainActor
func handleWait(_ args: [String]) async {
    // ghost wait urlContains "amazon.com" --timeout 15 --app Chrome
    // ghost wait elementExists "Add to Cart" --timeout 10
    // ghost wait titleChanged --timeout 5

    guard let condition = args.first(where: { !$0.hasPrefix("-") }) else {
        print("""
        Usage: ghost wait <condition> [value] [--timeout n] [--interval n] [--app name]

        Conditions:
          urlContains <text>     Wait until URL contains text
          titleContains <text>   Wait until window title contains text
          elementExists <text>   Wait until element with text appears
          elementGone <text>     Wait until element with text disappears
          urlChanged             Wait until URL changes from current
          titleChanged           Wait until window title changes
        """)
        return
    }

    let appName = flagValue(args, flag: "--app")
    let timeoutStr = flagValue(args, flag: "--timeout")
    let intervalStr = flagValue(args, flag: "--interval")
    let timeout = timeoutStr.flatMap(Double.init) ?? 10.0
    let interval = intervalStr.flatMap(Double.init) ?? 0.5

    // Value is the second non-flag argument (if present)
    let flagKeys: Set<String> = ["--app", "--timeout", "--interval"]
    let flagVals: Set<String> = Set(flagKeys.compactMap { flagValue(args, flag: $0) })
    let nonFlags = args.filter { !$0.hasPrefix("-") && !flagVals.contains($0) }
    let value = nonFlags.count > 1 ? nonFlags[1] : nil

    // Try daemon first
    if let response = trySendToDaemon(
        method: "wait",
        params: RPCParams(
            app: appName,
            condition: condition,
            value: value,
            timeout: timeout,
            interval: interval
        )
    ) {
        printResult(response)
        return
    }

    // Direct mode
    let daemon = directDaemon()
    let result = daemon.wait(
        condition: condition,
        value: value,
        timeout: timeout,
        interval: interval,
        app: appName
    )
    printActionResult(result)
}

@MainActor
func handleFocus(_ args: [String]) async {
    guard let appName = args.first else {
        print("Usage: ghost focus <app name>")
        return
    }
    let params = RPCParams(app: appName)
    if let response = trySendToDaemon(method: "focus", params: params) {
        printResult(response)
    } else {
        let daemon = directDaemon()
        let result = daemon.execute(action: "focus", params: params)
        printResult(result)
    }
}

@MainActor
func handleDiff(_ args: [String]) async {
    // Diff needs two refreshes — the first establishes baseline, second computes diff
    if let response = trySendToDaemon(method: "getDiff") {
        if case let .diff(diff) = response.result {
            if diff.changes.isEmpty {
                print("No changes detected")
            } else {
                print(diff.summary())
            }
        } else {
            printResult(response)
        }
        return
    }

    // Direct mode: do two refreshes to get a diff
    let daemon = directDaemon()
    // First call builds baseline
    _ = daemon.getState()
    // Small delay for things to settle
    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
    // Second call computes diff
    _ = daemon.getState()
    let response = daemon.execute(action: "getDiff", params: RPCParams())
    printResult(response)
}

@MainActor
func handleWatch(_ args: [String]) async {
    let intervalStr = flagValue(args, flag: "--interval")
    let interval = intervalStr.flatMap(Double.init) ?? 1.0
    let appName = flagValue(args, flag: "--app")
    let useSummary = !args.contains("--verbose")

    print("Watching for screen changes (interval: \(interval)s, Ctrl+C to stop)...\n")

    let daemon = directDaemon()
    // Build initial state
    var previousSummary = ""

    while true {
        let state = daemon.getState()

        if useSummary {
            let summary = state.summary()
            if summary != previousSummary {
                if !previousSummary.isEmpty {
                    // Show timestamp for updates
                    let formatter = DateFormatter()
                    formatter.dateFormat = "HH:mm:ss"
                    print("--- \(formatter.string(from: Date())) ---")
                }
                print(summary)
                print("")
                previousSummary = summary
            }
        } else {
            // Verbose mode — show full diff
            let diff = daemon.execute(
                action: "getDiff",
                params: RPCParams(app: appName)
            )
            if case let .diff(d) = diff.result, d.isSignificant {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                print("[\(formatter.string(from: Date()))] \(d.summary())")
            }
        }

        // Sleep for the interval
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
}

@MainActor
func handleRead(_ args: [String]) async {
    let appName = flagValue(args, flag: "--app")
    let maxItemsStr = flagValue(args, flag: "--max-items")
    let maxItems = maxItemsStr.flatMap(Int.init) ?? 500
    let limitStr = flagValue(args, flag: "--limit")
    let limit = limitStr.flatMap(Int.init)
    let useJSON = args.contains("--json")

    // Try daemon first
    if let response = trySendToDaemon(
        method: "readContent",
        params: RPCParams(app: appName, depth: maxItems)
    ) {
        if !useJSON, case let .content(items) = response.result {
            let limited = limit != nil ? Array(items.prefix(limit!)) : items
            renderContent(limited)
            if let limit = limit, items.count > limit {
                print("\n... (\(items.count - limit) more items, use --limit to see more)")
            }
        } else {
            printJSON(response)
        }
        return
    }

    // Direct mode
    let daemon = directDaemon()
    let items = daemon.readContent(app: appName, maxItems: maxItems)
    if items.isEmpty {
        print("No readable content found")
        return
    }
    if useJSON {
        let limited = limit != nil ? Array(items.prefix(limit!)) : items
        printJSON(limited)
    } else {
        let limited = limit != nil ? Array(items.prefix(limit!)) : items
        renderContent(limited)
        if let limit = limit, items.count > limit {
            print("\n... (\(items.count - limit) more items, use --limit to see more)")
        }
    }
}

/// Render content items in a readable format
func renderContent(_ items: [ContentItem]) {
    var lastDepth = 0
    for item in items {
        let text = item.render()
        if text.isEmpty { continue }

        // Add blank line before headings for readability
        if item.type == "heading" && lastDepth >= 0 {
            print("")
        }
        print(text)
        lastDepth = item.depth
    }
}

@MainActor
func handleContext(_ args: [String]) async {
    let appName = flagValue(args, flag: "--app")
    let useJSON = args.contains("--json")

    // Try daemon first
    if let response = trySendToDaemon(
        method: "getContext",
        params: RPCParams(app: appName)
    ) {
        if !useJSON, case let .context(ctx) = response.result {
            print(ctx.summary())
        } else {
            printJSON(response)
        }
        return
    }

    // Direct mode
    let daemon = directDaemon()
    guard let ctx = daemon.getContext(app: appName) else {
        print("No app found\(appName.map { " matching '\($0)'" } ?? "")")
        return
    }

    if useJSON {
        printJSON(ctx)
    } else {
        print(ctx.summary())
    }
}

@MainActor
func handleDescribe(_ args: [String]) async {
    let appName = flagValue(args, flag: "--app")
    let depth = flagValue(args, flag: "--depth").flatMap(Int.init) ?? 3

    // Try daemon
    if let response = trySendToDaemon(
        method: "describe",
        params: RPCParams(app: appName, depth: depth)
    ) {
        if case let .message(msg) = response.result {
            print(msg)
        } else {
            printResult(response)
        }
        return
    }

    // Direct mode
    let daemon = directDaemon()
    let state = daemon.getState()
    print(state.summary())

    if let app = appName {
        if let tree = daemon.getTree(app: app, depth: depth) {
            print("\nElement tree for \(app):")
            print(tree.renderTree())
        }
    }
}

@MainActor
func handlePermissions() async {
    let daemon = GhostDaemon()
    if daemon.checkPermissions() {
        print("Accessibility permissions: GRANTED")
    } else {
        print("Accessibility permissions: DENIED")
        print("")
        print("To grant permissions:")
        print("  System Settings > Privacy & Security > Accessibility")
        print("  Add your terminal app to the list")
        exit(1)
    }
}

// MARK: - Helpers

/// Create a GhostDaemon for direct mode (no IPC, runs in-process)
@MainActor
func directDaemon() -> GhostDaemon {
    let daemon = GhostDaemon()
    guard daemon.checkPermissions() else {
        print("Error: Accessibility permissions not granted")
        print("Run: ghost permissions")
        exit(1)
    }
    return daemon
}

func trySendToDaemon(method: String, params: RPCParams? = nil) -> RPCResponse? {
    let request = RPCRequest(method: method, params: params, id: 1)
    return try? IPCServer.sendRequest(request)
}

func flagValue(_ args: [String], flag: String) -> String? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(value), let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

/// Print an ActionResult in a human-friendly way: action line + context
func printActionResult(_ result: ActionResult) {
    if result.success {
        print(result.description)
    } else {
        print("Error: \(result.description)")
    }
    if let ctx = result.context {
        print("")
        print(ctx.summary())
    }
    if !result.success {
        exit(1)
    }
}

/// Print an RPC response in a human-friendly way
func printResult(_ response: RPCResponse) {
    if let error = response.error {
        print("Error: \(error.message)")
        return
    }
    guard let result = response.result else {
        print("(no result)")
        return
    }
    switch result {
    case .message(let msg):
        print(msg)
    case .bool(let val):
        print(val ? "true" : "false")
    case .state(let state):
        printJSON(state)
    case .elements(let elements):
        printJSON(elements)
    case .tree(let tree):
        print(tree.renderTree())
    case .diff(let diff):
        print(diff.summary())
    case .content(let items):
        renderContent(items)
    case .actionResult(let result):
        printActionResult(result)
    case .context(let ctx):
        print(ctx.summary())
    case .app(let app):
        printJSON(app)
    }
}

func printUsage() {
    print("""
    Ghost OS CLI — Accessibility-first computer perception

    USAGE:
      ghost daemon start          Start the daemon (foreground)
      ghost daemon stop           Stop the running daemon
      ghost daemon status         Check if daemon is running
      ghost state                 Print full screen state (JSON)
      ghost state --summary       Compact text summary
      ghost state --app <name>    State for specific app
      ghost tree                  Dump element tree of frontmost app
      ghost tree --app <name>     Dump tree for specific app
      ghost tree --depth <n>      Limit depth (default 5)
      ghost tree --json           Output as JSON instead of text
      ghost find <query>          Find elements matching query
      ghost find --role <role>    Filter by role (button, textfield, etc.)
      ghost find --smart          Use fuzzy matching with confidence scores
      ghost find --deep           Skip menus, search deep into content
      ghost read                  Read text content from frontmost app
      ghost read --app <name>     Read content from specific app
      ghost read --limit <n>      Limit output to first n items (for AI agents)
      ghost click <label>         Smart click — find best match and click it
      ghost click --at x,y        Click at exact coordinates
      ghost type <text>           Type text at current focus
      ghost type <text> --into <field>  Find field first, then type
      ghost press <key>           Press key (return, tab, escape, etc.)
      ghost hotkey <keys>         Key combo (cmd,s  cmd,shift,t)
      ghost wait <condition> [value]  Wait for condition (replaces sleep)
        Conditions: urlContains, titleContains, elementExists,
                    elementGone, urlChanged, titleChanged
        Options: --timeout <s> (default 10) --interval <s> (default 0.5)
      ghost scroll [up|down]      Scroll (default: down)
      ghost focus <app>           Bring app to foreground
      ghost diff                  Show what changed since last state check
      ghost watch                 Live monitor — shows changes in real-time
      ghost context               Where am I? URL + focused element + actions
      ghost context --app <name>  Context for specific app
      ghost context --json        Output as JSON
      ghost describe              Natural language screen description
      ghost describe --app <name> Include element tree for specific app
      ghost permissions           Check accessibility permissions

    EXAMPLES:
      ghost state --summary
      ghost tree --app Chrome --depth 6
      ghost find "Send" --role button
      ghost find "Compose" --smart --app Chrome
      ghost click "Compose" --app Chrome
      ghost type "Hello world"
      ghost type "test" --into "Search" --app Chrome
      ghost hotkey cmd,shift,n
      ghost wait urlContains "amazon.com" --timeout 15 --app Chrome
      ghost wait elementExists "Add to Cart" --timeout 10 --app Chrome
      ghost wait titleChanged --timeout 5 --app Chrome
      ghost watch --interval 2
      ghost describe --app "System Settings"

    Most commands work in direct mode (no daemon needed).
    The daemon enables real-time change tracking via AX observers.
    Start it with: ghost daemon start
    """)
}

// Entry point
await main()
