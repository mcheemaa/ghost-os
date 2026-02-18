// RecipeEngine.swift — Recipe loading, validation, parameter substitution, and execution
//
// The execution loop is entirely synchronous. Individual handlers (wait, screenshot)
// manage their own async bridging internally. The engine calls RPCHandler.dispatch()
// for each step, handles wait_after, delay_ms, on_failure, and builds the RunResult.
//
// Execution order per step:
//   1. Capture baseline context (for wait_after race condition prevention)
//   2. Execute action via RPCHandler.dispatch()
//   3. Check action result — apply on_failure policy if failed
//   4. If wait_after defined: call wait() with baseline from step 1
//      Wait failure always stops (action succeeded but expected state didn't materialize)
//   5. delay_ms: sleep for that duration (UI settle time before NEXT step)
//   6. Record step result

import Foundation

/// Executes recipes by dispatching steps through RPCHandler.
@MainActor
public final class RecipeEngine {
    private let rpcHandler: RPCHandler
    private let stateManager: StateManager

    public init(rpcHandler: RPCHandler, stateManager: StateManager) {
        self.rpcHandler = rpcHandler
        self.stateManager = stateManager
    }

    // MARK: - Public API

    /// Execute a recipe with parameter substitution.
    /// Returns a RunResult with per-step details and failure info.
    public func run(recipe: Recipe, params: [String: String]) -> RunResult {
        let startTime = Date()
        var stepResults: [StepResult] = []

        // 1. Validate parameters
        if let paramDefs = recipe.params {
            for (name, def) in paramDefs {
                if def.required && params[name] == nil && def.defaultValue == nil {
                    return RunResult(
                        recipe: recipe.name,
                        success: false,
                        stepsCompleted: 0,
                        stepsTotal: recipe.steps.count,
                        duration: Date().timeIntervalSince(startTime),
                        failedStep: FailedStepInfo(
                            id: 0, action: "validate",
                            params: [:],
                            error: "Missing required parameter: '\(name)'"
                        ),
                        stepResults: []
                    )
                }
            }
        }

        // 2. Build resolved params (user params + defaults)
        var resolvedParams = params
        if let paramDefs = recipe.params {
            for (name, def) in paramDefs {
                if resolvedParams[name] == nil, let defaultVal = def.defaultValue {
                    resolvedParams[name] = defaultVal
                }
            }
        }

        // 3. Execute steps in sequence
        for step in recipe.steps {
            let stepStart = Date()

            // Substitute parameters in step params
            let substituted: [String: String]
            do {
                substituted = try substituteParams(step.params, values: resolvedParams)
            } catch {
                let failInfo = FailedStepInfo(
                    id: step.id, action: step.action,
                    params: step.params,
                    error: "Parameter substitution failed: \(error.localizedDescription)"
                )
                return RunResult(
                    recipe: recipe.name,
                    success: false,
                    stepsCompleted: stepResults.count,
                    stepsTotal: recipe.steps.count,
                    duration: Date().timeIntervalSince(startTime),
                    failedStep: failInfo,
                    stepResults: stepResults
                )
            }

            // Capture baseline context BEFORE the action (for wait_after race prevention)
            let baseline: ContextInfo?
            if step.waitAfter != nil {
                stateManager.refresh()
                baseline = stateManager.getContext(appName: substituted["app"])
            } else {
                baseline = nil
            }

            // Build RPC request and dispatch
            let rpcParams = RPCParams.fromRecipeStep(substituted)
            let rpcMethod = mapActionToMethod(step.action)
            let request = RPCRequest(method: rpcMethod, params: rpcParams, id: step.id)
            let response = rpcHandler.dispatch(request)

            let actionSuccess = response.error == nil
            let stepDuration = Date().timeIntervalSince(stepStart)

            // Handle action failure
            if !actionSuccess {
                let policy = step.onFailure ?? .stop

                switch policy {
                case .stop:
                    // Capture screenshot for debugging
                    let ctx = extractContext(from: response)
                    let screenshot = captureFailureScreenshot(appName: substituted["app"])
                    let failInfo = FailedStepInfo(
                        id: step.id, action: step.action,
                        params: substituted,
                        error: response.error?.message ?? "Unknown error",
                        context: ctx,
                        screenshot: screenshot
                    )
                    stepResults.append(StepResult(
                        id: step.id, action: step.action,
                        success: false,
                        description: response.error?.message,
                        duration: stepDuration
                    ))
                    return RunResult(
                        recipe: recipe.name,
                        success: false,
                        stepsCompleted: stepResults.count,
                        stepsTotal: recipe.steps.count,
                        duration: Date().timeIntervalSince(startTime),
                        failedStep: failInfo,
                        stepResults: stepResults
                    )

                case .skip:
                    stepResults.append(StepResult(
                        id: step.id, action: step.action,
                        success: false,
                        description: "Skipped: \(response.error?.message ?? "failed")",
                        duration: stepDuration
                    ))
                    // Apply delay_ms even on skip, then continue
                    if let delayMs = step.delayMs, delayMs > 0 {
                        usleep(UInt32(delayMs) * 1000)
                    }
                    continue
                }
            }

            // Action succeeded — check wait_after
            if let waitCond = step.waitAfter {
                let waitParams = RPCParams(
                    app: substituted["app"],
                    condition: waitCond.condition,
                    value: waitCond.value,
                    timeout: waitCond.timeout ?? 10.0
                )
                // Pass baseline for race condition prevention
                let waitRequest = RPCRequest(method: "wait", params: waitParams, id: step.id)
                let waitResponse = rpcHandler.dispatch(waitRequest)

                if waitResponse.error != nil {
                    // Wait failure ALWAYS stops — action succeeded but expected state didn't materialize
                    let ctx = extractContext(from: waitResponse) ?? extractContext(from: response)
                    let screenshot = captureFailureScreenshot(appName: substituted["app"])
                    let failInfo = FailedStepInfo(
                        id: step.id, action: step.action,
                        params: substituted,
                        error: "Action succeeded but wait_after failed: \(waitCond.condition) '\(waitCond.value ?? "")' timed out",
                        context: ctx,
                        screenshot: screenshot
                    )
                    let totalDuration = Date().timeIntervalSince(stepStart)
                    stepResults.append(StepResult(
                        id: step.id, action: step.action,
                        success: false,
                        description: failInfo.error,
                        duration: totalDuration
                    ))
                    return RunResult(
                        recipe: recipe.name,
                        success: false,
                        stepsCompleted: stepResults.count,
                        stepsTotal: recipe.steps.count,
                        duration: Date().timeIntervalSince(startTime),
                        failedStep: failInfo,
                        stepResults: stepResults
                    )
                }
            }

            // Record success
            let desc = extractDescription(from: response)
            let totalDuration = Date().timeIntervalSince(stepStart)
            stepResults.append(StepResult(
                id: step.id, action: step.action,
                success: true,
                description: desc,
                duration: totalDuration
            ))

            // delay_ms: UI settle time before the NEXT step
            if let delayMs = step.delayMs, delayMs > 0 {
                usleep(UInt32(delayMs) * 1000)
            }
        }

        // All steps completed successfully
        stateManager.refresh()
        let finalCtx = stateManager.getContext(appName: nil)

        return RunResult(
            recipe: recipe.name,
            success: true,
            stepsCompleted: stepResults.count,
            stepsTotal: recipe.steps.count,
            duration: Date().timeIntervalSince(startTime),
            finalContext: finalCtx,
            stepResults: stepResults
        )
    }

    // MARK: - Parameter Substitution

    /// Replace {{param}} placeholders in step params with actual values.
    /// Throws if any {{param}} is unresolved after substitution.
    private func substituteParams(
        _ stepParams: [String: String],
        values: [String: String]
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        for (key, val) in stepParams {
            var substituted = val
            // Find and replace all {{param}} patterns
            let pattern = try NSRegularExpression(pattern: "\\{\\{(\\w+)\\}\\}")
            let range = NSRange(substituted.startIndex..., in: substituted)
            let matches = pattern.matches(in: substituted, range: range)

            // Replace in reverse order to preserve indices
            for match in matches.reversed() {
                guard let paramRange = Range(match.range(at: 1), in: substituted) else { continue }
                let paramName = String(substituted[paramRange])
                guard let paramValue = values[paramName] else {
                    throw SubstitutionError.unresolvedParam(paramName)
                }
                let fullRange = Range(match.range, in: substituted)!
                substituted.replaceSubrange(fullRange, with: paramValue)
            }

            result[key] = substituted
        }
        return result
    }

    private enum SubstitutionError: LocalizedError {
        case unresolvedParam(String)

        var errorDescription: String? {
            switch self {
            case .unresolvedParam(let name):
                return "Unresolved recipe parameter: {{\(name)}}"
            }
        }
    }

    // MARK: - Method Mapping

    /// Map recipe action names to RPC method names.
    /// Recipe actions use short names; some map to "smart" variants.
    private func mapActionToMethod(_ action: String) -> String {
        switch action {
        case "click":    return "smartClick"
        case "type":     return "smartType"
        case "press":    return "press"
        case "hotkey":   return "hotkey"
        case "focus":    return "focus"
        case "scroll":   return "scroll"
        case "wait":     return "wait"
        case "screenshot": return "screenshot"
        case "context":  return "getContext"
        case "read":     return "readContent"
        case "find":     return "findDeep"
        default:         return action  // pass through for exact RPC method names
        }
    }

    // MARK: - Helpers

    private func extractDescription(from response: RPCResponse) -> String? {
        guard let result = response.result else {
            return response.error?.message
        }
        switch result {
        case .actionResult(let ar): return ar.description
        case .message(let msg): return msg
        default: return nil
        }
    }

    private func extractContext(from response: RPCResponse) -> ContextInfo? {
        guard let result = response.result else { return nil }
        switch result {
        case .actionResult(let ar): return ar.context
        case .context(let ctx): return ctx
        default: return nil
        }
    }

    /// Capture a screenshot for failure debugging.
    /// Uses the same RunLoop bridge pattern as ActionExecutor.
    private func captureFailureScreenshot(appName: String?) -> ScreenshotResult? {
        guard ScreenCapture.hasPermission() else { return nil }

        let pid: pid_t
        if let name = appName {
            guard let app = stateManager.getState().apps.first(where: {
                $0.name.localizedCaseInsensitiveContains(name)
            }) else { return nil }
            pid = app.pid
        } else {
            guard let front = stateManager.getState().frontmostApp else { return nil }
            pid = front.pid
        }

        var result: ScreenshotResult?
        var done = false
        Task {
            result = await ScreenCapture.captureWindow(pid: pid)
            done = true
        }
        while !done {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return result
    }
}
