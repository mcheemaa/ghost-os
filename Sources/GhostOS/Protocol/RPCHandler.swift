// RPCHandler.swift — Routes JSON-RPC methods to StateManager/ActionExecutor

import Foundation

/// RPCHandler processes incoming JSON-RPC requests and dispatches them
/// to the appropriate StateManager or ActionExecutor method.
@MainActor
public final class RPCHandler {
    private let stateManager: StateManager
    private let actionExecutor: ActionExecutor
    public let recordingManager = RecordingManager()
    private var recipeEngine: RecipeEngine?

    public init(stateManager: StateManager, actionExecutor: ActionExecutor) {
        self.stateManager = stateManager
        self.actionExecutor = actionExecutor
        // RecipeEngine needs self (RPCHandler), so we set it up after init
        self.recipeEngine = RecipeEngine(rpcHandler: self, stateManager: stateManager)
    }

    /// Process a raw JSON request string and return a JSON response string
    public func handle(requestJSON: Data) -> Data {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        do {
            let request = try decoder.decode(RPCRequest.self, from: requestJSON)
            let response = dispatch(request)
            return (try? encoder.encode(response)) ?? Data()
        } catch {
            let errResponse = RPCResponse.failure(
                .invalidParams("Failed to parse request: \(error.localizedDescription)"),
                id: 0
            )
            return (try? encoder.encode(errResponse)) ?? Data()
        }
    }

    /// Dispatch a parsed request to the appropriate handler.
    /// Recording hook: every dispatch is logged when recording is active.
    public func dispatch(_ request: RPCRequest) -> RPCResponse {
        let response = dispatchInternal(request)
        // One hook captures all routes — RecordingManager filters out meta-commands internally
        recordingManager.log(method: request.method, params: request.params, response: response)
        return response
    }

    /// Internal dispatch — the actual routing logic.
    private func dispatchInternal(_ request: RPCRequest) -> RPCResponse {
        let params = request.params
        let id = request.id

        switch request.method {
        case "getState":
            return handleGetState(params: params, id: id)
        case "getAppState":
            return handleGetAppState(params: params, id: id)
        case "findElement", "findElements":
            return handleFindElements(params: params, id: id)
        case "click":
            return handleClick(params: params, id: id)
        case "type":
            return handleType(params: params, id: id)
        case "press":
            return handlePress(params: params, id: id)
        case "hotkey":
            return handleHotkey(params: params, id: id)
        case "scroll":
            return handleScroll(params: params, id: id)
        case "focus":
            return handleFocus(params: params, id: id)
        case "readContent":
            return handleReadContent(params: params, id: id)
        case "findDeep":
            return handleFindDeep(params: params, id: id)
        case "getTree":
            return handleGetTree(params: params, id: id)
        case "getDiff":
            return handleGetDiff(id: id)
        case "smartClick":
            return handleSmartClick(params: params, id: id)
        case "smartDoubleClick":
            return handleSmartDoubleClick(params: params, id: id)
        case "smartRightClick":
            return handleSmartRightClick(params: params, id: id)
        case "smartType":
            return handleSmartType(params: params, id: id)
        case "getContext":
            return handleGetContext(params: params, id: id)
        case "describe":
            return handleDescribe(params: params, id: id)
        case "refresh":
            return handleRefresh(id: id)
        case "wait":
            return handleWait(params: params, id: id)
        case "screenshot":
            return handleScreenshot(params: params, id: id)
        // Recording
        case "recordStart":
            return handleRecordStart(params: params, id: id)
        case "recordStop":
            return handleRecordStop(id: id)
        case "recordStatus":
            return handleRecordStatus(id: id)
        // Recipe execution
        case "run":
            return handleRun(params: params, id: id)
        // Recipe management
        case "recipeList":
            return handleRecipeList(id: id)
        case "recipeShow":
            return handleRecipeShow(params: params, id: id)
        case "recipeSave":
            return handleRecipeSave(params: params, id: id)
        case "recipeDelete":
            return handleRecipeDelete(params: params, id: id)
        // Recording management
        case "recordingList":
            return handleRecordingList(id: id)
        case "recordingShow":
            return handleRecordingShow(params: params, id: id)
        case "ping":
            return .success(.message("pong"), id: id)
        default:
            return .failure(.methodNotFound("Unknown method: \(request.method)"), id: id)
        }
    }

    // MARK: - Method Handlers

    private func handleGetState(params: RPCParams?, id: Int) -> RPCResponse {
        if let appName = params?.app {
            if let app = stateManager.getState(forApp: appName) {
                return .success(.app(app), id: id)
            }
            return .failure(.notFound("App '\(appName)' not found"), id: id)
        }
        stateManager.refresh()
        return .success(.state(stateManager.getState()), id: id)
    }

    private func handleGetAppState(params: RPCParams?, id: Int) -> RPCResponse {
        guard let appName = params?.app else {
            return .failure(.invalidParams("'app' parameter required"), id: id)
        }
        stateManager.refreshFocus()
        if let app = stateManager.getState(forApp: appName) {
            return .success(.app(app), id: id)
        }
        return .failure(.notFound("App '\(appName)' not found"), id: id)
    }

    private func handleFindElements(params: RPCParams?, id: Int) -> RPCResponse {
        guard let query = params?.query ?? params?.target else {
            return .failure(.invalidParams("'query' or 'target' parameter required"), id: id)
        }
        stateManager.refreshFocus()
        let elements = stateManager.findElements(
            query: query,
            role: params?.role,
            appName: params?.app
        )
        return .success(.elements(elements), id: id)
    }

    private func handleClick(params: RPCParams?, id: Int) -> RPCResponse {
        // Coordinate mode — stays synthetic, no element to find
        if let x = params?.x, let y = params?.y {
            do {
                let msg = try actionExecutor.click(at: CGPoint(x: x, y: y))
                return .success(.message(msg), id: id)
            } catch {
                return .failure(.notFound("\(error)"), id: id)
            }
        }
        // Target mode — delegate to smartClick for AX-native + context
        guard let target = params?.target ?? params?.query else {
            return .failure(.invalidParams("'target' or 'x'/'y' required"), id: id)
        }
        let result = actionExecutor.smartClick(query: target, role: params?.role, appName: params?.app)
        return result.success ? .success(.actionResult(result), id: id) : .failure(.notFound(result.description), id: id)
    }

    private func handleType(params: RPCParams?, id: Int) -> RPCResponse {
        guard let text = params?.text else {
            return .failure(.invalidParams("'text' parameter required"), id: id)
        }
        let result = actionExecutor.smartType(text: text, target: params?.target, role: params?.role, appName: params?.app)
        return result.success ? .success(.actionResult(result), id: id) : .failure(.notFound(result.description), id: id)
    }

    private func handlePress(params: RPCParams?, id: Int) -> RPCResponse {
        guard let key = params?.key else {
            return .failure(.invalidParams("'key' parameter required"), id: id)
        }
        let result = actionExecutor.pressWithContext(key: key, appName: params?.app)
        return result.success ? .success(.actionResult(result), id: id) : .failure(.invalidParams(result.description), id: id)
    }

    private func handleHotkey(params: RPCParams?, id: Int) -> RPCResponse {
        guard let keys = params?.keys, !keys.isEmpty else {
            return .failure(.invalidParams("'keys' array required"), id: id)
        }
        let result = actionExecutor.hotkeyWithContext(keys: keys, appName: params?.app)
        return result.success ? .success(.actionResult(result), id: id) : .failure(.internalError(result.description), id: id)
    }

    private func handleScroll(params: RPCParams?, id: Int) -> RPCResponse {
        let direction = params?.direction ?? "down"
        let amount = params?.amount ?? 3.0
        var point: CGPoint? = nil
        if let x = params?.x, let y = params?.y {
            point = CGPoint(x: x, y: y)
        }
        do {
            let msg = try actionExecutor.scroll(direction: direction, amount: amount, at: point)
            return .success(.message(msg), id: id)
        } catch {
            return .failure(.invalidParams("\(error)"), id: id)
        }
    }

    private func handleFocus(params: RPCParams?, id: Int) -> RPCResponse {
        guard let appName = params?.app ?? params?.target else {
            return .failure(.invalidParams("'app' or 'target' parameter required"), id: id)
        }
        do {
            let msg = try actionExecutor.focus(appName: appName)
            return .success(.message(msg), id: id)
        } catch {
            return .failure(.notFound("\(error)"), id: id)
        }
    }

    private func handleReadContent(params: RPCParams?, id: Int) -> RPCResponse {
        stateManager.refresh()
        let items = stateManager.readContent(appName: params?.app, maxItems: params?.depth ?? 500)
        if items.isEmpty {
            return .failure(.notFound("No readable content found"), id: id)
        }
        return .success(.content(items), id: id)
    }

    private func handleFindDeep(params: RPCParams?, id: Int) -> RPCResponse {
        guard let query = params?.query ?? params?.target else {
            return .failure(.invalidParams("'query' or 'target' required"), id: id)
        }
        stateManager.refresh()
        let elements = stateManager.findElementsDeep(
            query: query,
            role: params?.role,
            appName: params?.app,
            maxDepth: params?.depth ?? 15
        )
        return .success(.elements(elements), id: id)
    }

    private func handleGetTree(params: RPCParams?, id: Int) -> RPCResponse {
        stateManager.refresh()
        let depth = params?.depth ?? 5
        if let tree = stateManager.getTree(appName: params?.app, depth: depth) {
            return .success(.tree(tree), id: id)
        }
        return .failure(.notFound("No app found"), id: id)
    }

    private func handleGetDiff(id: Int) -> RPCResponse {
        stateManager.refresh()
        if let diff = stateManager.getDiff() {
            return .success(.diff(diff), id: id)
        }
        return .success(.message("No previous state to diff against"), id: id)
    }

    private func handleSmartClick(params: RPCParams?, id: Int) -> RPCResponse {
        guard let query = params?.target ?? params?.query else {
            return .failure(.invalidParams("'target' or 'query' required"), id: id)
        }
        let result = actionExecutor.smartClick(query: query, role: params?.role, appName: params?.app)
        if result.success {
            return .success(.actionResult(result), id: id)
        }
        return .failure(.notFound(result.description), id: id)
    }

    private func handleSmartDoubleClick(params: RPCParams?, id: Int) -> RPCResponse {
        guard let query = params?.target ?? params?.query else {
            return .failure(.invalidParams("'target' or 'query' required"), id: id)
        }
        let result = actionExecutor.smartDoubleClick(query: query, role: params?.role, appName: params?.app)
        return result.success ? .success(.actionResult(result), id: id) : .failure(.notFound(result.description), id: id)
    }

    private func handleSmartRightClick(params: RPCParams?, id: Int) -> RPCResponse {
        guard let query = params?.target ?? params?.query else {
            return .failure(.invalidParams("'target' or 'query' required"), id: id)
        }
        let result = actionExecutor.smartRightClick(query: query, role: params?.role, appName: params?.app)
        return result.success ? .success(.actionResult(result), id: id) : .failure(.notFound(result.description), id: id)
    }

    private func handleSmartType(params: RPCParams?, id: Int) -> RPCResponse {
        guard let text = params?.text else {
            return .failure(.invalidParams("'text' required"), id: id)
        }
        let result = actionExecutor.smartType(
            text: text,
            target: params?.target,
            role: params?.role,
            appName: params?.app
        )
        if result.success {
            return .success(.actionResult(result), id: id)
        }
        return .failure(.notFound(result.description), id: id)
    }

    private func handleGetContext(params: RPCParams?, id: Int) -> RPCResponse {
        stateManager.refresh()
        if let ctx = stateManager.getContext(appName: params?.app) {
            return .success(.context(ctx), id: id)
        }
        return .failure(.notFound("No app found"), id: id)
    }

    private func handleDescribe(params: RPCParams?, id: Int) -> RPCResponse {
        stateManager.refresh()
        let state = stateManager.getState()
        var description = state.summary()

        // If a specific app is requested, include its element tree summary
        if let appName = params?.app {
            if let tree = stateManager.getTree(appName: appName, depth: 3) {
                description += "\n\nElement tree for \(appName):\n"
                description += tree.renderTree()
            }
        }

        return .success(.message(description), id: id)
    }

    private func handleRefresh(id: Int) -> RPCResponse {
        stateManager.refresh()
        return .success(.message("State refreshed"), id: id)
    }

    private func handleWait(params: RPCParams?, id: Int) -> RPCResponse {
        guard let condition = params?.condition else {
            return .failure(.invalidParams("'condition' required (urlContains, titleContains, elementExists, elementGone, urlChanged, titleChanged)"), id: id)
        }
        let result = actionExecutor.wait(
            condition: condition,
            value: params?.value,
            timeout: params?.timeout ?? 10.0,
            interval: params?.interval ?? 0.5,
            appName: params?.app
        )
        return .success(.actionResult(result), id: id)
    }

    // MARK: - Recording Handlers

    private func handleRecordStart(params: RPCParams?, id: Int) -> RPCResponse {
        guard let name = params?.value ?? params?.query ?? params?.target else {
            return .failure(.invalidParams("'name' required for recordStart"), id: id)
        }
        if recordingManager.startRecording(name: name) {
            return .success(.message("Recording started: \(name)"), id: id)
        }
        return .failure(.internalError("Already recording '\(recordingManager.currentSessionName ?? "?")'"), id: id)
    }

    private func handleRecordStop(id: Int) -> RPCResponse {
        guard let recording = recordingManager.stopRecording() else {
            return .failure(.internalError("Not recording"), id: id)
        }
        let msg = "Recording stopped: \(recording.name) (\(recording.steps.count) steps, \(String(format: "%.1f", recording.duration))s)"
        return .success(.message(msg), id: id)
    }

    private func handleRecordStatus(id: Int) -> RPCResponse {
        if let name = recordingManager.currentSessionName {
            return .success(.message("Recording: \(name)"), id: id)
        }
        return .success(.message("Not recording"), id: id)
    }

    // MARK: - Recipe Execution Handler

    private func handleRun(params: RPCParams?, id: Int) -> RPCResponse {
        guard let engine = recipeEngine else {
            return .failure(.internalError("Recipe engine not initialized"), id: id)
        }

        // Load recipe by name or path
        let recipe: Recipe?
        if let path = params?.query, path.contains("/") {
            recipe = RecipeStore.loadRecipeFromPath(path)
        } else if let name = params?.value ?? params?.query ?? params?.target {
            recipe = RecipeStore.loadRecipe(name: name)
        } else {
            return .failure(.invalidParams("'recipe' name or path required"), id: id)
        }

        guard let recipe = recipe else {
            return .failure(.notFound("Recipe not found"), id: id)
        }

        // Parse recipe params from the text field (JSON string)
        var recipeParams: [String: String] = [:]
        if let paramsJSON = params?.text {
            if let data = paramsJSON.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                recipeParams = parsed
            }
        }

        let result = engine.run(recipe: recipe, params: recipeParams)
        return .success(.runResult(result), id: id)
    }

    // MARK: - Recipe Management Handlers

    private func handleRecipeList(id: Int) -> RPCResponse {
        let recipes = RecipeStore.listRecipes()
        return .success(.recipeList(recipes), id: id)
    }

    private func handleRecipeShow(params: RPCParams?, id: Int) -> RPCResponse {
        guard let name = params?.value ?? params?.query ?? params?.target else {
            return .failure(.invalidParams("'name' required"), id: id)
        }
        if let recipe = RecipeStore.loadRecipe(name: name) {
            return .success(.recipe(recipe), id: id)
        }
        return .failure(.notFound("Recipe '\(name)' not found"), id: id)
    }

    private func handleRecipeSave(params: RPCParams?, id: Int) -> RPCResponse {
        // Expect recipe JSON in the text field
        guard let jsonStr = params?.text,
              let data = jsonStr.data(using: .utf8) else {
            return .failure(.invalidParams("Recipe JSON required in 'text' field"), id: id)
        }
        do {
            let recipe = try JSONDecoder().decode(Recipe.self, from: data)
            try RecipeStore.saveRecipe(recipe)
            return .success(.message("Recipe saved: \(recipe.name)"), id: id)
        } catch {
            return .failure(.invalidParams("Invalid recipe JSON: \(error.localizedDescription)"), id: id)
        }
    }

    private func handleRecipeDelete(params: RPCParams?, id: Int) -> RPCResponse {
        guard let name = params?.value ?? params?.query ?? params?.target else {
            return .failure(.invalidParams("'name' required"), id: id)
        }
        if RecipeStore.deleteRecipe(name: name) {
            return .success(.message("Recipe deleted: \(name)"), id: id)
        }
        return .failure(.notFound("Recipe '\(name)' not found"), id: id)
    }

    // MARK: - Recording Management Handlers

    private func handleRecordingList(id: Int) -> RPCResponse {
        let recordings = RecipeStore.listRecordings()
        if recordings.isEmpty {
            return .success(.message("No recordings found"), id: id)
        }
        return .success(.message(recordings.joined(separator: "\n")), id: id)
    }

    private func handleRecordingShow(params: RPCParams?, id: Int) -> RPCResponse {
        guard let name = params?.value ?? params?.query ?? params?.target else {
            return .failure(.invalidParams("'name' required"), id: id)
        }
        if let recording = RecipeStore.loadRecording(name: name) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(recording), let json = String(data: data, encoding: .utf8) {
                return .success(.message(json), id: id)
            }
        }
        return .failure(.notFound("Recording '\(name)' not found"), id: id)
    }

    // MARK: - Screenshot Handler

    private func handleScreenshot(params: RPCParams?, id: Int) -> RPCResponse {
        // Permission check first — fail fast with actionable message
        guard ScreenCapture.hasPermission() else {
            return .failure(.internalError(
                "Screen Recording permission not granted. Go to: System Settings > Privacy & Security > Screen Recording and add your terminal app."
            ), id: id)
        }

        // Resolve app — default to frontmost if --app not specified
        stateManager.refresh()
        let state = stateManager.getState()

        let appInfo: AppInfo
        if let appName = params?.app {
            guard let found = state.apps.first(where: {
                $0.name.localizedCaseInsensitiveContains(appName)
            }) else {
                return .failure(.notFound("App '\(appName)' not found"), id: id)
            }
            appInfo = found
        } else {
            guard let front = state.frontmostApp else {
                return .failure(.notFound("No frontmost app found"), id: id)
            }
            appInfo = front
        }

        let pid = appInfo.pid
        let windowTitle = params?.target
        let fullRes = params?.fullResolution ?? false

        // Bridge async ScreenCaptureKit to sync RPC dispatch.
        // We're on MainActor — spin the RunLoop to allow the async Task to make progress.
        // This avoids deadlocks because RunLoop.main processes Task continuations.
        var screenshotResult: ScreenshotResult?
        var completed = false

        Task {
            screenshotResult = await ScreenCapture.captureWindow(
                pid: pid, windowTitle: windowTitle, fullResolution: fullRes
            )
            completed = true
        }

        while !completed {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }

        guard let screenshot = screenshotResult else {
            return .failure(.internalError(
                "Screenshot capture failed — no matching window found for \(appInfo.name)"
            ), id: id)
        }
        return .success(.screenshot(screenshot), id: id)
    }
}
