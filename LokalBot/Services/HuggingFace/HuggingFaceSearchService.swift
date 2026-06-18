import Combine
import Foundation
import os

private let logger = Logger(subsystem: AppIdentifiers.bundleID, category: "HuggingFaceSearch")

/// Drives the two-step HuggingFace browse flow for the Settings sheet: search
/// for GGUF repositories, then drill into one to list its `.gguf` files. Owns
/// cancellation so the UI can bind directly to published state without juggling
/// async `Task`s of its own.
@MainActor
final class HuggingFaceSearchService: ObservableObject {

    /// Matching repositories, most-downloaded first. Empty until a search runs.
    @Published private(set) var results: [HFModelSummary] = []

    /// True only while a search request is in flight; drives a spinner.
    @Published private(set) var isSearching = false

    /// Two-way bound to the search field. Mutating it does not auto-search;
    /// the view decides when to call `search()` (typically debounced).
    @Published var query = ""

    /// Last failure's user-facing text, or nil when the last operation was
    /// clean. The single error channel for both search and file listing.
    @Published private(set) var errorMessage: String?

    private let client: HuggingFaceAPIClient
    private let resultLimit: Int

    /// Handle to the in-flight search so a newer `search()` can supersede it.
    private var searchTask: Task<Void, Never>?

    init(client: HuggingFaceAPIClient = HuggingFaceAPIClient(), resultLimit: Int = 20) {
        self.client = client
        self.resultLimit = resultLimit
    }

    /// Run a search for the current `query`, cancelling any prior in-flight one.
    /// Safe to call on every keystroke — superseded requests are cancelled
    /// before they mutate state, so the latest query always wins.
    func search() async {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Cleared field: drop stale results immediately, hit no network.
            results = []
            errorMessage = nil
            isSearching = false
            return
        }

        let task = Task { await performSearch(query: trimmed) }
        searchTask = task
        await task.value
    }

    /// Fetch a repository's `.gguf` files. Returns an empty array (and sets
    /// `errorMessage`) on failure so the caller never has to catch.
    func ggufFiles(for modelID: String) async -> [HFFile] {
        do {
            let files = try await client.files(modelID: modelID)
            errorMessage = nil
            return files
        } catch is CancellationError {
            return []
        } catch {
            errorMessage = error.localizedDescription
            logger.error("File list failed for \(modelID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    // MARK: - Private

    /// The body of one search. Touches published state only when it is still
    /// the active task: a cancelled task returns without writing, leaving
    /// `isSearching` for its successor (which already set it true) to clear.
    private func performSearch(query: String) async {
        isSearching = true
        errorMessage = nil
        do {
            let found = try await client.searchModels(query: query, limit: resultLimit)
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            errorMessage = error.localizedDescription
            isSearching = false
            logger.error("Search for \(query, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
