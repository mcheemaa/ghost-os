// RecordingManager.swift — Recording state and step logging
//
// Hooks into RPCHandler.dispatch() to capture every command and its result.
// One hook captures all routes. The recording manager filters out meta-commands
// (recordStart, recordStop, run, etc.) internally.

import Foundation

/// Manages recording sessions — start, log steps, stop and save.
@MainActor
public final class RecordingManager {
    private var isRecording = false
    private var sessionName: String?
    private var steps: [RecordedStep] = []
    private var startTime: Date?

    /// Commands that should not be recorded (meta-commands about recording itself).
    private static let skipMethods: Set<String> = [
        "recordStart", "recordStop", "recordStatus",
        "run", "recipeList", "recipeShow", "recipeSave", "recipeDelete",
        "recordingList", "recordingShow",
        "ping",
    ]

    // MARK: - Public API

    /// Start a recording session. Returns false if already recording.
    public func startRecording(name: String) -> Bool {
        guard !isRecording else { return false }
        isRecording = true
        sessionName = name
        steps = []
        startTime = Date()
        return true
    }

    /// Stop the current recording session. Saves to disk and returns the recording.
    /// Returns nil if not recording.
    public func stopRecording() -> Recording? {
        guard isRecording, let start = startTime else { return nil }
        isRecording = false

        let recording = Recording(
            name: sessionName ?? "untitled",
            recordedAt: start,
            duration: Date().timeIntervalSince(start),
            steps: steps
        )

        // Save to disk
        try? RecipeStore.saveRecording(recording)

        // Clean up
        sessionName = nil
        steps = []
        startTime = nil

        return recording
    }

    /// Check if currently recording.
    public var recording: Bool { isRecording }

    /// Get the current recording session name, or nil.
    public var currentSessionName: String? { isRecording ? sessionName : nil }

    /// Log a command and its result. Called by RPCHandler.dispatch() after every command.
    /// Skips meta-commands (recording, recipe management, ping).
    public func log(method: String, params: RPCParams?, response: RPCResponse) {
        guard isRecording else { return }
        guard !Self.skipMethods.contains(method) else { return }

        // Extract description and context from the response
        let description = Self.extractDescription(from: response)
        let context = Self.extractContext(from: response)
        let success = response.error == nil

        steps.append(RecordedStep(
            timestamp: Date(),
            method: method,
            params: params,
            success: success,
            description: description,
            context: context
        ))
    }

    // MARK: - Response Parsing

    /// Extract a human-readable description from an RPC response.
    private static func extractDescription(from response: RPCResponse) -> String? {
        guard let result = response.result else {
            return response.error?.message
        }
        switch result {
        case .actionResult(let ar):
            return ar.description
        case .message(let msg):
            return msg
        default:
            return nil
        }
    }

    /// Extract ContextInfo from an RPC response (if available).
    private static func extractContext(from response: RPCResponse) -> ContextInfo? {
        guard let result = response.result else { return nil }
        switch result {
        case .actionResult(let ar):
            return ar.context
        case .context(let ctx):
            return ctx
        default:
            return nil
        }
    }
}
