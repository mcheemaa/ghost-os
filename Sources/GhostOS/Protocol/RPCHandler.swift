// RPCHandler.swift — Routes JSON-RPC methods to StateManager/ActionExecutor

import Foundation

/// RPCHandler processes incoming JSON-RPC requests and dispatches them
/// to the appropriate StateManager or ActionExecutor method.
@MainActor
public final class RPCHandler {
    private let stateManager: StateManager
    private let actionExecutor: ActionExecutor

    public init(stateManager: StateManager, actionExecutor: ActionExecutor) {
        self.stateManager = stateManager
        self.actionExecutor = actionExecutor
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

    /// Dispatch a parsed request to the appropriate handler
    public func dispatch(_ request: RPCRequest) -> RPCResponse {
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
        case "refresh":
            return handleRefresh(id: id)
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
        do {
            if let x = params?.x, let y = params?.y {
                let msg = try actionExecutor.click(at: CGPoint(x: x, y: y))
                return .success(.message(msg), id: id)
            }
            guard let target = params?.target ?? params?.query else {
                return .failure(.invalidParams("'target' or 'x'/'y' required"), id: id)
            }
            let msg = try actionExecutor.click(target: target, appName: params?.app)
            return .success(.message(msg), id: id)
        } catch {
            return .failure(.notFound("\(error)"), id: id)
        }
    }

    private func handleType(params: RPCParams?, id: Int) -> RPCResponse {
        guard let text = params?.text else {
            return .failure(.invalidParams("'text' parameter required"), id: id)
        }
        do {
            let msg = try actionExecutor.type(text: text)
            return .success(.message(msg), id: id)
        } catch {
            return .failure(.internalError("\(error)"), id: id)
        }
    }

    private func handlePress(params: RPCParams?, id: Int) -> RPCResponse {
        guard let key = params?.key else {
            return .failure(.invalidParams("'key' parameter required"), id: id)
        }
        do {
            let msg = try actionExecutor.press(key: key)
            return .success(.message(msg), id: id)
        } catch {
            return .failure(.invalidParams("\(error)"), id: id)
        }
    }

    private func handleHotkey(params: RPCParams?, id: Int) -> RPCResponse {
        guard let keys = params?.keys, !keys.isEmpty else {
            return .failure(.invalidParams("'keys' array required"), id: id)
        }
        do {
            let msg = try actionExecutor.hotkey(keys: keys)
            return .success(.message(msg), id: id)
        } catch {
            return .failure(.internalError("\(error)"), id: id)
        }
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

    private func handleRefresh(id: Int) -> RPCResponse {
        stateManager.refresh()
        return .success(.message("State refreshed"), id: id)
    }
}
