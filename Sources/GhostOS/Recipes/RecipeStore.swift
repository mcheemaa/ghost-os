// RecipeStore.swift — Filesystem operations for recordings and recipes

import Foundation

/// Manages reading and writing of recordings and recipes to ~/.ghost-os/
@MainActor
public final class RecipeStore {

    // MARK: - Directory Paths

    private static var baseDir: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.ghost-os"
    }

    private static var recipesDir: String { baseDir + "/recipes" }
    private static var recordingsDir: String { baseDir + "/recordings" }

    // MARK: - Directory Setup

    /// Ensure the storage directories exist.
    public static func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: recipesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: recordingsDir, withIntermediateDirectories: true)
    }

    // MARK: - JSON Helpers

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Recordings

    /// Save a recording to ~/.ghost-os/recordings/{name}-{timestamp}.json
    /// Uses atomic write (write to temp, then rename).
    public static func saveRecording(_ recording: Recording) throws {
        ensureDirectories()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate]
        let ts = formatter.string(from: recording.recordedAt)
            .replacingOccurrences(of: ":", with: "")
        let filename = "\(recording.name)-\(ts).json"
        let path = recordingsDir + "/" + filename

        let data = try encoder.encode(recording)
        let tempPath = path + ".tmp"
        try data.write(to: URL(fileURLWithPath: tempPath))
        try FileManager.default.moveItem(atPath: tempPath, toPath: path)
    }

    /// List all recordings, sorted by date (newest first).
    public static func listRecordings() -> [String] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: recordingsDir) else { return [] }
        return files.filter { $0.hasSuffix(".json") }
            .sorted().reversed()
            .map { String($0.dropLast(5)) } // remove .json
    }

    /// Load a recording by name (filename without .json).
    public static func loadRecording(name: String) -> Recording? {
        let path = recordingsDir + "/" + name + ".json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? decoder.decode(Recording.self, from: data)
    }

    // MARK: - Recipes

    /// Save a recipe to ~/.ghost-os/recipes/{name}.json
    /// Uses atomic write (write to temp, then rename).
    public static func saveRecipe(_ recipe: Recipe) throws {
        ensureDirectories()
        let path = recipesDir + "/" + recipe.name + ".json"
        let data = try encoder.encode(recipe)
        let tempPath = path + ".tmp"
        try data.write(to: URL(fileURLWithPath: tempPath))
        // Remove existing file first if it exists (moveItem fails if destination exists)
        try? FileManager.default.removeItem(atPath: path)
        try FileManager.default.moveItem(atPath: tempPath, toPath: path)
    }

    /// Save raw recipe JSON data to ~/.ghost-os/recipes/{name}.json
    public static func saveRecipeData(name: String, data: Data) throws {
        ensureDirectories()
        // Validate it's a valid recipe first
        _ = try decoder.decode(Recipe.self, from: data)
        let path = recipesDir + "/" + name + ".json"
        let tempPath = path + ".tmp"
        try data.write(to: URL(fileURLWithPath: tempPath))
        try? FileManager.default.removeItem(atPath: path)
        try FileManager.default.moveItem(atPath: tempPath, toPath: path)
    }

    /// Load a recipe by name. Checks user recipes first, then built-in.
    public static func loadRecipe(name: String) -> Recipe? {
        // 1. User recipes: ~/.ghost-os/recipes/{name}.json
        let userPath = recipesDir + "/" + name + ".json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: userPath)),
           let recipe = try? decoder.decode(Recipe.self, from: data) {
            return recipe
        }
        // 2. Built-in recipes not supported yet (would check install path)
        return nil
    }

    /// Load a recipe from an arbitrary file path.
    public static func loadRecipeFromPath(_ path: String) -> Recipe? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? decoder.decode(Recipe.self, from: data)
    }

    /// Delete a user recipe by name.
    public static func deleteRecipe(name: String) -> Bool {
        let path = recipesDir + "/" + name + ".json"
        do {
            try FileManager.default.removeItem(atPath: path)
            return true
        } catch {
            return false
        }
    }

    /// List all available recipes with summaries.
    public static func listRecipes() -> [RecipeSummary] {
        let fm = FileManager.default
        var results: [RecipeSummary] = []

        // User recipes
        if let files = try? fm.contentsOfDirectory(atPath: recipesDir) {
            for file in files.sorted() where file.hasSuffix(".json") {
                let path = recipesDir + "/" + file
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                      let recipe = try? decoder.decode(Recipe.self, from: data) else { continue }
                results.append(RecipeSummary(
                    name: recipe.name,
                    description: recipe.description,
                    app: recipe.app,
                    params: recipe.params?.keys.sorted() ?? [],
                    stepCount: recipe.steps.count,
                    source: "user"
                ))
            }
        }

        return results
    }
}
