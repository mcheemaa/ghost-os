// MCPServer.swift — Model Context Protocol server for Ghost OS
//
// Speaks MCP JSON-RPC over stdin/stdout with Content-Length framing.
// Routes tool calls through RPCHandler. Action tools are wrapped in
// focus-restore so the caller's app stays frontmost.
//
// Usage: ghost mcp (spawned by Claude Desktop or Claude Code)

import ApplicationServices
import Foundation

@MainActor
public final class MCPServer {
    private let stateManager: StateManager
    private let actionExecutor: ActionExecutor
    private let rpcHandler: RPCHandler
    private let instructions: String

    /// Tools that switch focus to other apps — wrapped in focus-restore.
    private static let actionTools: Set<String> = [
        "ghost_click", "ghost_type", "ghost_press", "ghost_hotkey",
        "ghost_scroll", "ghost_focus", "ghost_run",
    ]

    public init() {
        self.stateManager = StateManager()
        self.actionExecutor = ActionExecutor(stateManager: stateManager)
        self.rpcHandler = RPCHandler(stateManager: stateManager, actionExecutor: actionExecutor)
        self.instructions = Self.loadInstructions()
    }

    /// Check accessibility permission without creating the full server stack.
    public static func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Main Loop

    /// Run the MCP server. Blocks forever reading stdin, dispatching tool calls,
    /// and writing responses to stdout. Exits when stdin closes.
    public func run() {
        log("Ghost OS MCP server starting")

        stateManager.refresh()
        let state = stateManager.getState()
        log("Ready: \(state.apps.count) apps")

        while let message = readMessage() {
            guard let method = message["method"] as? String else {
                if let id = message["id"] {
                    writeError(id: id, code: -32600, message: "Invalid request: missing method")
                }
                continue
            }

            let id = message["id"]
            let params = message["params"] as? [String: Any] ?? [:]

            switch method {
            case "initialize":
                if let id = id {
                    writeResponse(id: id, result: handleInitialize(params))
                }

            case "notifications/initialized":
                log("Client initialized")

            case "tools/list":
                if let id = id {
                    writeResponse(id: id, result: ["tools": Self.toolDefinitions()])
                }

            case "tools/call":
                if let id = id {
                    writeResponse(id: id, result: handleToolsCall(params))
                }

            case "ping":
                if let id = id {
                    writeResponse(id: id, result: [:] as [String: Any])
                }

            default:
                if let id = id {
                    writeError(id: id, code: -32601, message: "Method not found: \(method)")
                }
            }
        }

        log("stdin closed, shutting down")
    }

    // MARK: - MCP Handlers

    private func handleInitialize(_ params: [String: Any]) -> [String: Any] {
        [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": "ghost-os", "version": "1.0.0"],
            "instructions": instructions,
        ]
    }

    private func handleToolsCall(_ params: [String: Any]) -> [String: Any] {
        guard let toolName = params["name"] as? String else {
            return errorContent("Missing tool name")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        log("Tool call: \(toolName)")

        guard let (method, rpcParams) = mapToolToRPC(name: toolName, arguments: arguments) else {
            return errorContent("Unknown tool: \(toolName)")
        }

        let response: RPCResponse
        if Self.actionTools.contains(toolName) {
            response = withFocusRestore {
                let request = RPCRequest(method: method, params: rpcParams, id: 0)
                return self.rpcHandler.dispatch(request)
            }
        } else {
            let request = RPCRequest(method: method, params: rpcParams, id: 0)
            response = rpcHandler.dispatch(request)
        }

        return formatResponse(response)
    }

    // MARK: - Focus Restore

    /// Capture the frontmost app before an action, restore it after.
    private func withFocusRestore(_ block: () -> RPCResponse) -> RPCResponse {
        stateManager.refresh()
        let callingApp = stateManager.getState().frontmostApp?.name
        let response = block()
        if let callingApp = callingApp {
            _ = try? actionExecutor.focus(appName: callingApp)
        }
        return response
    }

    // MARK: - Tool to RPC Mapping

    private func mapToolToRPC(name: String, arguments: [String: Any]) -> (String, RPCParams)? {
        switch name {
        // -- Perception --
        case "ghost_context":
            return ("getContext", RPCParams(app: str(arguments, "app")))

        case "ghost_state":
            return ("getState", RPCParams(app: str(arguments, "app")))

        case "ghost_read":
            return ("readContent", RPCParams(app: str(arguments, "app"), depth: int(arguments, "limit")))

        case "ghost_find":
            let deep = bool(arguments, "deep") ?? false
            return (
                deep ? "findDeep" : "findElements",
                RPCParams(
                    query: str(arguments, "query"),
                    role: str(arguments, "role"),
                    app: str(arguments, "app"),
                    depth: int(arguments, "depth")
                )
            )

        case "ghost_tree":
            return (
                "getTree",
                RPCParams(app: str(arguments, "app"), depth: int(arguments, "depth"))
            )

        case "ghost_describe":
            return (
                "describe",
                RPCParams(app: str(arguments, "app"), depth: int(arguments, "depth"))
            )

        case "ghost_diff":
            return ("getDiff", RPCParams())

        case "ghost_screenshot":
            return (
                "screenshot",
                RPCParams(
                    target: str(arguments, "window"),
                    app: str(arguments, "app"),
                    fullResolution: bool(arguments, "full_resolution")
                )
            )

        // -- Actions --
        case "ghost_click":
            let x = dbl(arguments, "x")
            let y = dbl(arguments, "y")

            if let x = x, let y = y {
                return ("click", RPCParams(app: str(arguments, "app"), x: x, y: y))
            }

            let isDouble = bool(arguments, "double") ?? false
            let isRight = bool(arguments, "right") ?? false
            let method =
                isDouble ? "smartDoubleClick" : isRight ? "smartRightClick" : "smartClick"

            return (
                method,
                RPCParams(
                    role: str(arguments, "role"),
                    target: str(arguments, "target"),
                    app: str(arguments, "app")
                )
            )

        case "ghost_type":
            return (
                "type",
                RPCParams(
                    target: str(arguments, "into"),
                    text: str(arguments, "text"),
                    app: str(arguments, "app")
                )
            )

        case "ghost_press":
            return ("press", RPCParams(key: str(arguments, "key")))

        case "ghost_hotkey":
            let keysStr = str(arguments, "keys") ?? ""
            let keys = keysStr.split(separator: ",").map {
                String($0.trimmingCharacters(in: .whitespaces))
            }
            return ("hotkey", RPCParams(keys: keys))

        case "ghost_scroll":
            return (
                "scroll",
                RPCParams(
                    x: dbl(arguments, "x"),
                    y: dbl(arguments, "y"),
                    direction: str(arguments, "direction"),
                    amount: dbl(arguments, "amount")
                )
            )

        case "ghost_focus":
            return ("focus", RPCParams(app: str(arguments, "app")))

        case "ghost_wait":
            return (
                "wait",
                RPCParams(
                    app: str(arguments, "app"),
                    condition: str(arguments, "condition"),
                    value: str(arguments, "value"),
                    timeout: dbl(arguments, "timeout"),
                    interval: dbl(arguments, "interval")
                )
            )

        // -- Recipes --
        case "ghost_run":
            let recipeName = str(arguments, "recipe")
            var paramsJSON: String? = nil
            if let p = arguments["params"] as? [String: Any], !p.isEmpty {
                var stringParams: [String: String] = [:]
                for (k, v) in p { stringParams[k] = "\(v)" }
                if let data = try? JSONSerialization.data(withJSONObject: stringParams),
                    let s = String(data: data, encoding: .utf8)
                {
                    paramsJSON = s
                }
            }
            return ("run", RPCParams(query: recipeName, text: paramsJSON))

        case "ghost_recipes":
            return ("recipeList", RPCParams())

        case "ghost_recipe_show":
            return ("recipeShow", RPCParams(value: str(arguments, "name")))

        case "ghost_recipe_save":
            return ("recipeSave", RPCParams(text: str(arguments, "recipe_json")))

        case "ghost_recipe_delete":
            return ("recipeDelete", RPCParams(value: str(arguments, "name")))

        // -- Recording --
        case "ghost_record_start":
            return ("recordStart", RPCParams(value: str(arguments, "name")))

        case "ghost_record_stop":
            return ("recordStop", RPCParams())

        case "ghost_record_status":
            return ("recordStatus", RPCParams())

        case "ghost_recordings":
            return ("recordingList", RPCParams())

        case "ghost_recording_show":
            return ("recordingShow", RPCParams(value: str(arguments, "name")))

        // -- Utility --
        case "ghost_refresh":
            return ("refresh", RPCParams())

        case "ghost_ping":
            return ("ping", RPCParams())

        default:
            return nil
        }
    }

    // MARK: - Argument Helpers

    private func str(_ args: [String: Any], _ key: String) -> String? {
        args[key] as? String
    }

    private func int(_ args: [String: Any], _ key: String) -> Int? {
        if let i = args[key] as? Int { return i }
        if let d = args[key] as? Double { return Int(d) }
        return nil
    }

    private func dbl(_ args: [String: Any], _ key: String) -> Double? {
        if let d = args[key] as? Double { return d }
        if let i = args[key] as? Int { return Double(i) }
        return nil
    }

    private func bool(_ args: [String: Any], _ key: String) -> Bool? {
        args[key] as? Bool
    }

    // MARK: - Response Formatting

    private func formatResponse(_ response: RPCResponse) -> [String: Any] {
        if let error = response.error {
            return errorContent(error.message)
        }

        guard let result = response.result else {
            return textContent("(no result)")
        }

        switch result {
        case .message(let msg):
            return textContent(msg)

        case .bool(let val):
            return textContent(val ? "true" : "false")

        case .actionResult(let ar):
            var text = ar.success ? ar.description : "Error: \(ar.description)"
            if let ctx = ar.context {
                text += "\n\n" + ctx.summary()
            }
            if let screenshot = ar.screenshot {
                return [
                    "content": [
                        ["type": "image", "data": screenshot.base64PNG, "mimeType": "image/png"],
                        ["type": "text", "text": text],
                    ] as [[String: Any]],
                    "isError": !ar.success,
                ]
            }
            return ar.success ? textContent(text) : errorContent(text)

        case .context(let ctx):
            return textContent(ctx.summary())

        case .state(let state):
            return textContent(state.summary())

        case .elements(let elements):
            if elements.isEmpty { return textContent("No elements found") }
            var lines = ["Found \(elements.count) elements:"]
            for el in elements.prefix(50) {
                let label = el.label ?? el.id
                let pos = el.position.map { " at (\(Int($0.x)),\(Int($0.y)))" } ?? ""
                let val = el.value.map { " = \($0)" } ?? ""
                lines.append("  \(el.role) \"\(label)\"\(val)\(pos)")
            }
            if elements.count > 50 { lines.append("  ... (\(elements.count - 50) more)") }
            return textContent(lines.joined(separator: "\n"))

        case .tree(let tree):
            return textContent(tree.renderTree())

        case .diff(let diff):
            return textContent(diff.changes.isEmpty ? "No changes detected" : diff.summary())

        case .content(let items):
            if items.isEmpty { return textContent("No readable content found") }
            let lines = items.compactMap { item -> String? in
                let text = item.render()
                return text.isEmpty ? nil : text
            }
            return textContent(lines.joined(separator: "\n"))

        case .screenshot(let result):
            var text = "Screenshot: \(result.width)x\(result.height)"
            if let title = result.windowTitle { text += " — \(title)" }
            return [
                "content": [
                    ["type": "image", "data": result.base64PNG, "mimeType": "image/png"],
                    ["type": "text", "text": text],
                ] as [[String: Any]]
            ]

        case .app(let app):
            return textContent(encodeJSON(app))

        case .runResult(let result):
            return result.success
                ? textContent(formatRunResult(result))
                : errorContent(formatRunResult(result))

        case .recipeList(let recipes):
            return textContent(formatRecipeList(recipes))

        case .recipe(let recipe):
            return textContent(encodeJSON(recipe))
        }
    }

    private func formatRunResult(_ result: RunResult) -> String {
        var lines: [String] = []
        let status = result.success ? "SUCCESS" : "FAILED"
        lines.append(
            "Recipe: \(result.recipe) — \(status)"
        )
        lines.append(
            "Steps: \(result.stepsCompleted)/\(result.stepsTotal) (\(String(format: "%.1f", result.duration))s)"
        )
        for step in result.stepResults {
            let icon = step.success ? "+" : "x"
            let desc = step.description.map { " — \($0)" } ?? ""
            lines.append(
                "[\(icon)] Step \(step.id): \(step.action)\(desc) (\(String(format: "%.1f", step.duration))s)"
            )
        }
        if let fail = result.failedStep {
            lines.append("")
            lines.append("Failed at step \(fail.id) (\(fail.action)): \(fail.error)")
            if let ctx = fail.context {
                lines.append("Context: \(ctx.summary())")
            }
        }
        if let ctx = result.finalContext {
            lines.append("")
            lines.append(ctx.summary())
        }
        return lines.joined(separator: "\n")
    }

    private func formatRecipeList(_ recipes: [RecipeSummary]) -> String {
        if recipes.isEmpty { return "No recipes found" }
        return recipes.map { r in
            let params = r.params.isEmpty ? "" : " (\(r.params.joined(separator: ", ")))"
            let desc = r.description ?? "No description"
            return "\(r.name) — \(desc) [\(r.stepCount) steps]\(params)"
        }.joined(separator: "\n")
    }

    // MARK: - Content Helpers

    private func textContent(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text] as [String: Any]]]
    }

    private func errorContent(_ text: String) -> [String: Any] {
        [
            "content": [["type": "text", "text": text] as [String: Any]],
            "isError": true,
        ]
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value),
            let str = String(data: data, encoding: .utf8)
        {
            return str
        }
        return "(encoding failed)"
    }

    // MARK: - Stdin/Stdout (Content-Length framing)

    private func readMessage() -> [String: Any]? {
        var contentLength = 0

        // Read headers until empty line
        while let line = readHeaderLine() {
            if line.isEmpty { break }
            if line.lowercased().hasPrefix("content-length:") {
                let value = line.dropFirst(15).trimmingCharacters(in: .whitespaces)
                contentLength = Int(value) ?? 0
            }
        }

        guard contentLength > 0 else { return nil }

        // Read body
        guard let body = readBytes(count: contentLength) else { return nil }

        // Parse JSON
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            log("Failed to parse JSON message")
            return nil
        }

        return json
    }

    private func writeResponse(id: Any, result: [String: Any]) {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": result,
        ]
        writeMessage(response)
    }

    private func writeError(id: Any?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message],
        ]
        if let id = id {
            response["id"] = id
        }
        writeMessage(response)
    }

    private func writeMessage(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else {
            log("Failed to serialize response")
            return
        }
        let header = "Content-Length: \(data.count)\r\n\r\n"
        FileHandle.standardOutput.write(Data(header.utf8))
        FileHandle.standardOutput.write(data)
    }

    // MARK: - Low-level IO

    private func readHeaderLine() -> String? {
        var line = ""
        while true {
            var byte: UInt8 = 0
            let read = fread(&byte, 1, 1, stdin)
            guard read == 1 else { return nil }
            if byte == 0x0A {  // \n
                if line.hasSuffix("\r") { line = String(line.dropLast()) }
                return line
            }
            line.append(Character(UnicodeScalar(byte)))
        }
    }

    private func readBytes(count: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        var totalRead = 0
        while totalRead < count {
            let read = fread(&buffer[totalRead], 1, count - totalRead, stdin)
            guard read > 0 else { return nil }
            totalRead += read
        }
        return Data(buffer)
    }

    // MARK: - Logging (stderr only — stdout is the protocol channel)

    private func log(_ message: String) {
        let msg = "[ghost-mcp] \(message)\n"
        FileHandle.standardError.write(Data(msg.utf8))
    }

    // MARK: - Instructions

    private static func loadInstructions() -> String {
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [
            // Development: .build/debug/ghost → 3 levels up to repo root
            execURL.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("GHOST.md"),
            // Development: .build/arm64-apple-macosx/debug/ghost → 4 levels up
            execURL.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("GHOST.md"),
            // Next to executable (installed)
            execURL.deletingLastPathComponent()
                .appendingPathComponent("GHOST.md"),
            // User config
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ghost-os/GHOST.md"),
        ]

        for url in candidates {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                return content
            }
        }

        // Minimal fallback if GHOST.md not found
        return """
            Ghost OS — accessibility-first computer perception for macOS.

            Call ghost_recipes first to check for pre-built workflows.
            Call ghost_context to orient yourself before acting.
            Use ghost_click, ghost_type, ghost_press, ghost_hotkey to interact.
            Use ghost_wait instead of sleep for timing.
            """
    }

    // MARK: - Tool Definitions

    private static func toolDefinitions() -> [[String: Any]] {
        [
            // ── Perception ──────────────────────────────────────────────
            [
                "name": "ghost_context",
                "description":
                    "Orient yourself: see the current app, window, URL (for browsers), focused element, and available actions. Call this before doing anything. Web apps readable from background; native apps may need focus first.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "app": [
                            "type": "string",
                            "description": "App name (default: frontmost). Examples: Chrome, Messages, Finder",
                        ]
                    ],
                ] as [String: Any],
            ],
            [
                "name": "ghost_state",
                "description":
                    "Overview of all running apps and windows. Shows app names, window titles, and frontmost app.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "app": [
                            "type": "string",
                            "description": "Get state for a specific app only",
                        ]
                    ],
                ] as [String: Any],
            ],
            [
                "name": "ghost_read",
                "description":
                    "Read all text content from an app — page text, labels, headings, links. Output can be large; use limit for manageable results. Web apps readable from background.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "app": [
                            "type": "string",
                            "description": "App to read from (default: frontmost)",
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Max content items to return (default: 500)",
                        ],
                    ],
                ] as [String: Any],
            ],
            [
                "name": "ghost_find",
                "description":
                    "Search for UI elements by text, label, or role. Use deep mode for web content (tunnels through CSS wrapper elements). Returns elements with roles, positions, and values.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Text to search for in element labels, titles, values",
                        ],
                        "role": [
                            "type": "string",
                            "description": "Filter by role: button, textfield, link, checkbox, etc.",
                        ],
                        "app": [
                            "type": "string",
                            "description": "App to search in (default: frontmost)",
                        ],
                        "deep": [
                            "type": "boolean",
                            "description":
                                "Deep search: skip menus, tunnel through CSS wrappers (default: false)",
                        ],
                        "depth": [
                            "type": "integer",
                            "description": "Max search depth (default: 15 for deep, 5 for normal)",
                        ],
                    ],
                    "required": ["query"],
                ] as [String: Any],
            ],
            [
                "name": "ghost_tree",
                "description":
                    "Dump the raw accessibility element tree. Use ghost_context for quick orientation; use this for detailed structural debugging.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "app": [
                            "type": "string",
                            "description": "App to dump tree for (default: frontmost)",
                        ],
                        "depth": [
                            "type": "integer",
                            "description": "Max depth (default: 5)",
                        ],
                    ],
                ] as [String: Any],
            ],
            [
                "name": "ghost_describe",
                "description":
                    "Natural language description of the screen: app list, frontmost app, optional element tree.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "app": [
                            "type": "string",
                            "description": "Include element tree for this app",
                        ],
                        "depth": [
                            "type": "integer",
                            "description": "Tree depth (default: 3)",
                        ],
                    ],
                ] as [String: Any],
            ],
            [
                "name": "ghost_diff",
                "description":
                    "Show what changed on screen since the last state check. Useful for verifying an action worked.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                ] as [String: Any],
            ],
            [
                "name": "ghost_screenshot",
                "description":
                    "Capture a window screenshot as PNG. Returns the image for visual inspection. Use when the accessibility tree is unclear. Requires Screen Recording permission.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "app": [
                            "type": "string",
                            "description": "App to screenshot (default: frontmost)",
                        ],
                        "window": [
                            "type": "string",
                            "description": "Match specific window by title",
                        ],
                        "full_resolution": [
                            "type": "boolean",
                            "description": "Native resolution instead of 1280px resize",
                        ],
                    ],
                ] as [String: Any],
            ],

            // ── Actions ─────────────────────────────────────────────────
            [
                "name": "ghost_click",
                "description":
                    "Click a UI element by label or at coordinates. Tries AX-native click first, falls back to synthetic. Returns post-action context. Focus the target app first with ghost_focus.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "target": [
                            "type": "string",
                            "description":
                                "Element label or text to click (fuzzy matched)",
                        ],
                        "app": [
                            "type": "string",
                            "description": "App containing the element",
                        ],
                        "role": [
                            "type": "string",
                            "description": "Filter: button, link, menuitem, etc.",
                        ],
                        "x": [
                            "type": "number",
                            "description": "X coordinate (use with y for coordinate click)",
                        ],
                        "y": [
                            "type": "number",
                            "description": "Y coordinate (use with x for coordinate click)",
                        ],
                        "double": [
                            "type": "boolean",
                            "description": "Double-click (open files, select words)",
                        ],
                        "right": [
                            "type": "boolean",
                            "description": "Right-click (context menus)",
                        ],
                    ],
                ] as [String: Any],
            ],
            [
                "name": "ghost_type",
                "description":
                    "Type text into the focused element or a specific field. Tries AX-native setValue first (instant), falls back to character-by-character. Returns post-action context.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "text": [
                            "type": "string",
                            "description": "Text to type",
                        ],
                        "into": [
                            "type": "string",
                            "description":
                                "Target field label (e.g. 'To', 'Subject', 'Search')",
                        ],
                        "app": [
                            "type": "string",
                            "description": "App containing the field",
                        ],
                    ],
                    "required": ["text"],
                ] as [String: Any],
            ],
            [
                "name": "ghost_press",
                "description":
                    "Press a single key: return, tab, escape, space, delete, up, down, left, right, f1-f12.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "key": [
                            "type": "string",
                            "description": "Key name: return, tab, escape, space, delete, up, down, left, right",
                        ]
                    ],
                    "required": ["key"],
                ] as [String: Any],
            ],
            [
                "name": "ghost_hotkey",
                "description":
                    "Press a key combination. Modifier keys auto-cleared afterward (no stuck keys). Examples: cmd,s (save), cmd,l (address bar), cmd,return (send in Gmail).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "keys": [
                            "type": "string",
                            "description":
                                "Comma-separated combo: cmd,s or cmd,shift,n or cmd,return",
                        ]
                    ],
                    "required": ["keys"],
                ] as [String: Any],
            ],
            [
                "name": "ghost_scroll",
                "description":
                    "Scroll in a direction at the current mouse position or at specific coordinates.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "direction": [
                            "type": "string",
                            "description": "up, down, left, right (default: down)",
                            "enum": ["up", "down", "left", "right"],
                        ],
                        "amount": [
                            "type": "number",
                            "description": "Lines to scroll (default: 3)",
                        ],
                        "x": [
                            "type": "number",
                            "description": "X coordinate to scroll at",
                        ],
                        "y": [
                            "type": "number",
                            "description": "Y coordinate to scroll at",
                        ],
                    ],
                ] as [String: Any],
            ],
            [
                "name": "ghost_focus",
                "description":
                    "Bring an app to the foreground. You MUST focus an app before clicking or typing in it — all input goes to the frontmost app.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "app": [
                            "type": "string",
                            "description": "App name: Chrome, Messages, Finder, etc.",
                        ]
                    ],
                    "required": ["app"],
                ] as [String: Any],
            ],
            [
                "name": "ghost_wait",
                "description":
                    "Wait for a condition instead of using fixed delays. Polls at intervals until true or timeout.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "condition": [
                            "type": "string",
                            "description": "What to wait for",
                            "enum": [
                                "urlContains", "titleContains", "elementExists",
                                "elementGone", "urlChanged", "titleChanged",
                            ],
                        ],
                        "value": [
                            "type": "string",
                            "description":
                                "Match value (required for urlContains, titleContains, elementExists, elementGone)",
                        ],
                        "timeout": [
                            "type": "number",
                            "description": "Max seconds to wait (default: 10)",
                        ],
                        "interval": [
                            "type": "number",
                            "description": "Poll interval in seconds (default: 0.5)",
                        ],
                        "app": [
                            "type": "string",
                            "description": "App to check condition against",
                        ],
                    ],
                    "required": ["condition"],
                ] as [String: Any],
            ],

            // ── Recipes ─────────────────────────────────────────────────
            [
                "name": "ghost_run",
                "description":
                    "Execute a recipe — a pre-built, tested multi-step workflow. Handles timing, element finding, wait conditions, and failure detection. Focus auto-restores to your app afterward. ALWAYS check ghost_recipes first.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "recipe": [
                            "type": "string",
                            "description": "Recipe name (from ghost_recipes)",
                        ],
                        "params": [
                            "type": "object",
                            "description": "Recipe parameters as key-value pairs",
                            "additionalProperties": ["type": "string"],
                        ],
                    ],
                    "required": ["recipe"],
                ] as [String: Any],
            ],
            [
                "name": "ghost_recipes",
                "description":
                    "List all available recipes. ALWAYS call this first for multi-step tasks — a recipe may already exist. Do NOT read recipe files from disk.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                ] as [String: Any],
            ],
            [
                "name": "ghost_recipe_show",
                "description":
                    "View full details of a recipe: steps, parameters, wait conditions.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "Recipe name",
                        ]
                    ],
                    "required": ["name"],
                ] as [String: Any],
            ],
            [
                "name": "ghost_recipe_save",
                "description":
                    "Install a new recipe from JSON. See instructions for the recipe JSON format.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "recipe_json": [
                            "type": "string",
                            "description": "Complete recipe JSON as a string",
                        ]
                    ],
                    "required": ["recipe_json"],
                ] as [String: Any],
            ],
            [
                "name": "ghost_recipe_delete",
                "description": "Delete a user recipe.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "Recipe name to delete",
                        ]
                    ],
                    "required": ["name"],
                ] as [String: Any],
            ],

            // ── Recording ───────────────────────────────────────────────
            [
                "name": "ghost_record_start",
                "description":
                    "Start recording Ghost OS commands. Records all actions as timestamped steps for later analysis.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "Recording session name",
                        ]
                    ],
                    "required": ["name"],
                ] as [String: Any],
            ],
            [
                "name": "ghost_record_stop",
                "description": "Stop recording and save to disk.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                ] as [String: Any],
            ],
            [
                "name": "ghost_record_status",
                "description": "Check if a recording session is active.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                ] as [String: Any],
            ],
            [
                "name": "ghost_recordings",
                "description": "List all saved recordings.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                ] as [String: Any],
            ],
            [
                "name": "ghost_recording_show",
                "description": "View a saved recording's full step log.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "Recording name",
                        ]
                    ],
                    "required": ["name"],
                ] as [String: Any],
            ],

            // ── Utility ─────────────────────────────────────────────────
            [
                "name": "ghost_refresh",
                "description":
                    "Force refresh the screen state cache. Usually not needed — state refreshes automatically.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                ] as [String: Any],
            ],
            [
                "name": "ghost_ping",
                "description": "Health check — returns 'pong' if Ghost OS is working.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                ] as [String: Any],
            ],
        ]
    }
}
