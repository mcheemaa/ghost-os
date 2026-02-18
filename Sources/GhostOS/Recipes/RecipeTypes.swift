// RecipeTypes.swift — Data structures for recording and recipe system

import Foundation

// MARK: - Recording

/// A single recorded interaction step — raw evidence of what happened.
/// Recordings capture everything including mistakes and retries.
public struct RecordedStep: Codable, Sendable {
    public let timestamp: Date
    public let method: String
    public let params: RPCParams?
    public let success: Bool
    public let description: String?
    public let context: ContextInfo?

    public init(
        timestamp: Date,
        method: String,
        params: RPCParams?,
        success: Bool,
        description: String?,
        context: ContextInfo?
    ) {
        self.timestamp = timestamp
        self.method = method
        self.params = params
        self.success = success
        self.description = description
        self.context = context
    }
}

/// A complete recording session — the raw log of a workflow attempt.
/// The agent reads recordings to understand what worked, then crafts recipes.
public struct Recording: Codable, Sendable {
    public let name: String
    public let ghostVersion: String
    public let recordedAt: Date
    public let duration: TimeInterval
    public let steps: [RecordedStep]

    public init(
        name: String,
        ghostVersion: String = Recording.currentVersion,
        recordedAt: Date,
        duration: TimeInterval,
        steps: [RecordedStep]
    ) {
        self.name = name
        self.ghostVersion = ghostVersion
        self.recordedAt = recordedAt
        self.duration = duration
        self.steps = steps
    }

    /// Current Ghost OS version string
    public static let currentVersion = "0.3.0"
}

// MARK: - Recipe

/// A saved, parameterized recipe — a tested sequence that can be replayed.
/// Recipes use the same RPC method names as Ghost OS tools. No DSL, no conditionals.
public struct Recipe: Codable, Sendable {
    public let schemaVersion: Int  // always 1 for now
    public let name: String
    public let description: String?
    public let app: String?  // primary app (metadata for listing, doesn't restrict steps)
    public let params: [String: RecipeParam]?
    public let steps: [RecipeStep]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case name, description, app, params, steps
    }

    public init(
        schemaVersion: Int = 1,
        name: String,
        description: String? = nil,
        app: String? = nil,
        params: [String: RecipeParam]? = nil,
        steps: [RecipeStep]
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.description = description
        self.app = app
        self.params = params
        self.steps = steps
    }
}

/// Recipe parameter definition — describes what the caller must provide.
public struct RecipeParam: Codable, Sendable {
    public let type: String      // "string" for now
    public let description: String?
    public let required: Bool
    public let defaultValue: String?

    enum CodingKeys: String, CodingKey {
        case type, description, required
        case defaultValue = "default"
    }

    public init(type: String = "string", description: String? = nil, required: Bool = true, defaultValue: String? = nil) {
        self.type = type
        self.description = description
        self.required = required
        self.defaultValue = defaultValue
    }
}

/// A single recipe step — maps directly to an RPC method call.
/// Params are [String: String] with {{substitution}} support.
/// The keys array for hotkey is comma-separated: "cmd,return".
public struct RecipeStep: Codable, Sendable {
    public let id: Int
    public let action: String        // RPC method name: click, type, press, hotkey, focus, scroll, wait, screenshot
    public let params: [String: String]  // flat key-value, {{param}} substitution, keys as "cmd,return"
    public let waitAfter: WaitCondition?
    public let delayMs: Int?
    public let note: String?
    public let onFailure: FailurePolicy?

    enum CodingKeys: String, CodingKey {
        case id, action, params, note
        case waitAfter = "wait_after"
        case delayMs = "delay_ms"
        case onFailure = "on_failure"
    }

    public init(
        id: Int,
        action: String,
        params: [String: String],
        waitAfter: WaitCondition? = nil,
        delayMs: Int? = nil,
        note: String? = nil,
        onFailure: FailurePolicy? = nil
    ) {
        self.id = id
        self.action = action
        self.params = params
        self.waitAfter = waitAfter
        self.delayMs = delayMs
        self.note = note
        self.onFailure = onFailure
    }
}

/// Wait condition — checked after a step completes.
public struct WaitCondition: Codable, Sendable {
    public let condition: String  // urlContains, titleContains, elementExists, elementGone, urlChanged, titleChanged
    public let value: String?
    public let timeout: Double?   // default 10

    public init(condition: String, value: String? = nil, timeout: Double? = nil) {
        self.condition = condition
        self.value = value
        self.timeout = timeout
    }
}

/// What to do when a step's action fails.
/// Note: wait_after failure always stops — if the action succeeded but expected state
/// didn't materialize, something unexpected happened. The agent needs to investigate.
public enum FailurePolicy: String, Codable, Sendable {
    case stop   // default — halt execution, return failure with context + screenshot
    case skip   // log failure, continue to next step (for optional steps like "dismiss banner if present")
}

// MARK: - Run Result

/// Result of executing a recipe — returned by `ghost run`.
public struct RunResult: Codable, Sendable {
    public let recipe: String
    public let success: Bool
    public let stepsCompleted: Int
    public let stepsTotal: Int
    public let duration: TimeInterval
    public let failedStep: FailedStepInfo?
    public let finalContext: ContextInfo?
    public let stepResults: [StepResult]

    public init(
        recipe: String,
        success: Bool,
        stepsCompleted: Int,
        stepsTotal: Int,
        duration: TimeInterval,
        failedStep: FailedStepInfo? = nil,
        finalContext: ContextInfo? = nil,
        stepResults: [StepResult]
    ) {
        self.recipe = recipe
        self.success = success
        self.stepsCompleted = stepsCompleted
        self.stepsTotal = stepsTotal
        self.duration = duration
        self.failedStep = failedStep
        self.finalContext = finalContext
        self.stepResults = stepResults
    }
}

/// Summary of one executed step in a run.
public struct StepResult: Codable, Sendable {
    public let id: Int
    public let action: String
    public let success: Bool
    public let description: String?
    public let duration: TimeInterval

    public init(id: Int, action: String, success: Bool, description: String? = nil, duration: TimeInterval) {
        self.id = id
        self.action = action
        self.success = success
        self.description = description
        self.duration = duration
    }
}

/// Detailed info when a step fails during recipe execution.
public struct FailedStepInfo: Codable, Sendable {
    public let id: Int
    public let action: String
    public let params: [String: String]
    public let error: String
    public let context: ContextInfo?
    public let screenshot: ScreenshotResult?

    public init(
        id: Int,
        action: String,
        params: [String: String],
        error: String,
        context: ContextInfo? = nil,
        screenshot: ScreenshotResult? = nil
    ) {
        self.id = id
        self.action = action
        self.params = params
        self.error = error
        self.context = context
        self.screenshot = screenshot
    }
}

// MARK: - Recipe Listing

/// Summary for recipe listing — compact view without full step details.
public struct RecipeSummary: Codable, Sendable {
    public let name: String
    public let description: String?
    public let app: String?
    public let params: [String]   // just param names
    public let stepCount: Int
    public let source: String     // "user" or "builtin"

    public init(name: String, description: String? = nil, app: String? = nil, params: [String], stepCount: Int, source: String) {
        self.name = name
        self.description = description
        self.app = app
        self.params = params
        self.stepCount = stepCount
        self.source = source
    }
}

// MARK: - RPCParams Construction from Recipe Step

extension RPCParams {
    /// Build RPCParams from a recipe step's [String: String] params.
    /// Handles the keys array case: "cmd,return" → ["cmd", "return"].
    public static func fromRecipeStep(_ stepParams: [String: String]) -> RPCParams {
        RPCParams(
            query: stepParams["query"],
            role: stepParams["role"],
            target: stepParams["target"],
            text: stepParams["text"],
            key: stepParams["key"],
            keys: stepParams["keys"]?.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) },
            app: stepParams["app"],
            x: stepParams["x"].flatMap(Double.init),
            y: stepParams["y"].flatMap(Double.init),
            direction: stepParams["direction"],
            amount: stepParams["amount"].flatMap(Double.init),
            action: stepParams["action"],
            depth: stepParams["depth"].flatMap(Int.init),
            condition: stepParams["condition"],
            value: stepParams["value"],
            timeout: stepParams["timeout"].flatMap(Double.init),
            interval: stepParams["interval"].flatMap(Double.init),
            fullResolution: stepParams["fullResolution"].flatMap { $0 == "true" }
        )
    }
}
