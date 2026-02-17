// main.swift — Ghost OS CLI tool
// Usage:
//   ghost daemon start          Start the daemon (foreground)
//   ghost state                 Print full screen state
//   ghost state --app Chrome    State for specific app
//   ghost state --summary       Compact text summary
//   ghost find "Search"         Find elements matching query
//   ghost find --role button    Filter by role
//   ghost click "Compose"       Click element by label
//   ghost click --at 680,52     Click at coordinates
//   ghost type "Hello world"    Type text
//   ghost press return          Press a key
//   ghost hotkey cmd,s           Key combo
//   ghost focus Chrome           Focus an app
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
            // Keep running until interrupted
            signal(SIGINT, SIG_IGN)
            let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            sigintSource.setEventHandler {
                daemon.stop()
                exit(0)
            }
            sigintSource.resume()
            // Block forever (can't use RunLoop.main.run() from async)
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in
                // Never resumes — daemon runs until SIGINT
            }
        } catch {
            print("Error: \(error)")
            exit(1)
        }

    case "status":
        // Check if daemon is running by trying to connect
        do {
            let response = try IPCServer.sendRequest(
                RPCRequest(method: "ping", id: 1)
            )
            if response.error == nil {
                print("Ghost daemon is running")
                print("Socket: \(IPCServer.defaultSocketPath())")
            }
        } catch {
            print("Ghost daemon is NOT running")
            exit(1)
        }

    default:
        print("Usage: ghost daemon [start|status]")
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
    let daemon = GhostDaemon()
    guard daemon.checkPermissions() else {
        print("Error: Accessibility permissions not granted")
        exit(1)
    }
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

    let daemon = GhostDaemon()
    guard daemon.checkPermissions() else {
        print("Error: Accessibility permissions not granted")
        exit(1)
    }

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
    // Collect flag values so we can exclude them from the query
    let flagValues: Set<String> = Set(
        ["--role", "--app"].compactMap { flagValue(args, flag: $0) }
    )
    let query = args.first(where: { !$0.hasPrefix("-") && !flagValues.contains($0) }) ?? ""

    guard !query.isEmpty || role != nil else {
        print("Usage: ghost find <query> [--role button] [--app Chrome]")
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
    let daemon = GhostDaemon()
    guard daemon.checkPermissions() else {
        print("Error: Accessibility permissions not granted")
        exit(1)
    }
    let elements = daemon.findElements(query: query, role: role, app: appName)
    printJSON(elements)
}

@MainActor
func handleClick(_ args: [String]) async {
    if let coordStr = flagValue(args, flag: "--at") {
        let parts = coordStr.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else {
            print("Usage: ghost click --at x,y (e.g., --at 680,52)")
            return
        }
        let params = RPCParams(x: parts[0], y: parts[1])
        if let response = trySendToDaemon(method: "click", params: params) {
            printJSON(response)
        } else {
            print("Daemon not running. Start with: ghost daemon start")
        }
        return
    }

    let target = args.first(where: { !$0.hasPrefix("-") }) ?? ""
    guard !target.isEmpty else {
        print("Usage: ghost click <label> or ghost click --at x,y")
        return
    }
    let appName = flagValue(args, flag: "--app")
    let params = RPCParams(target: target, app: appName)
    if let response = trySendToDaemon(method: "click", params: params) {
        printJSON(response)
    } else {
        print("Daemon not running. Start with: ghost daemon start")
    }
}

@MainActor
func handleType(_ args: [String]) async {
    let text = args.joined(separator: " ")
    guard !text.isEmpty else {
        print("Usage: ghost type <text>")
        return
    }
    let params = RPCParams(text: text)
    if let response = trySendToDaemon(method: "type", params: params) {
        printJSON(response)
    } else {
        print("Daemon not running. Start with: ghost daemon start")
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
        printJSON(response)
    } else {
        print("Daemon not running. Start with: ghost daemon start")
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
        printJSON(response)
    } else {
        print("Daemon not running. Start with: ghost daemon start")
    }
}

@MainActor
func handleFocus(_ args: [String]) async {
    guard let appName = args.first else {
        print("Usage: ghost focus <app name>")
        return
    }
    let params = RPCParams(app: appName)
    if let response = trySendToDaemon(method: "focus", params: params) {
        printJSON(response)
    } else {
        print("Daemon not running. Start with: ghost daemon start")
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

func printUsage() {
    print("""
    Ghost OS CLI — Accessibility-first computer perception

    USAGE:
      ghost daemon start          Start the daemon (foreground)
      ghost daemon status         Check if daemon is running
      ghost state                 Print full screen state (JSON)
      ghost state --summary       Compact text summary
      ghost state --app <name>    State for specific app
      ghost tree                  Dump element tree of frontmost app
      ghost tree --app <name>    Dump tree for specific app
      ghost tree --depth <n>     Limit depth (default 5)
      ghost tree --json          Output as JSON instead of text
      ghost find <query>          Find elements matching query
      ghost find --role <role>    Filter by role (button, textfield, etc.)
      ghost click <label>         Click element by label
      ghost click --at x,y        Click at coordinates
      ghost type <text>           Type text at current focus
      ghost press <key>           Press key (return, tab, escape, etc.)
      ghost hotkey <keys>         Key combo (cmd,s  cmd,shift,t)
      ghost focus <app>           Bring app to foreground
      ghost permissions           Check accessibility permissions

    EXAMPLES:
      ghost state --summary
      ghost tree --app Chrome
      ghost find "Send" --role button
      ghost click "Compose" --app Gmail
      ghost type "Hello world"
      ghost hotkey cmd,shift,n

    The CLI connects to a running daemon via Unix socket.
    If no daemon is running, 'state' and 'find' work in direct mode.
    Other commands require the daemon. Start it with: ghost daemon start
    """)
}

// Entry point
await main()
