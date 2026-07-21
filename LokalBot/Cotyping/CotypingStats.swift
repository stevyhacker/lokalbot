import Foundation

/// Cotyping usage + latency metrics. A pure, `Codable` value type (the counters
/// and their derivation) wrapped by `CotypingStatsStore` for persistence.
/// Inspired by Cotabby's `PerformanceMetricsStore`, trimmed to the metrics that
/// matter for a local continuer and that record cleanly at unambiguous pipeline
/// points (an LLM generation completing, an accept tap succeeding).
struct CotypingStats: Codable, Equatable, Sendable {
    /// LLM continuations that completed (regardless of whether they produced text).
    var generations: Int = 0
    /// Generations that failed (network error, bad response, …).
    var errors: Int = 0
    /// Continuation accepts (a phrase chunk or a full accept).
    var accepts: Int = 0
    /// Total characters inserted via accept.
    var charsAccepted: Int = 0
    /// Rolling window of generation latencies, newest last.
    var latenciesMs: [Int] = []

    /// Cap on retained latency samples — a rolling window for the averages.
    static let maxLatencies = 50

    /// Accepts per generation. Phrase acceptance can push this above 1.0 (one
    /// generation accepted in multiple word chunks), which is itself a useful
    /// "how much of each suggestion do I keep" signal.
    var acceptsPerGeneration: Double {
        generations > 0 ? Double(accepts) / Double(generations) : 0
    }
    var avgLatencyMs: Int? {
        guard !latenciesMs.isEmpty else { return nil }
        return latenciesMs.reduce(0, +) / latenciesMs.count
    }
    var medianLatencyMs: Int? { percentile(0.5) }
    var p95LatencyMs: Int? { percentile(0.95) }
    var maxLatencyMs: Int? { latenciesMs.max() }

    /// Nearest-rank percentile over the (small) window. Pure and deterministic.
    private func percentile(_ p: Double) -> Int? {
        guard !latenciesMs.isEmpty else { return nil }
        let sorted = latenciesMs.sorted()
        let ratio = Double(sorted.count - 1) * p
        let idx = max(0, min(sorted.count - 1, Int(ratio.rounded())))
        return sorted[idx]
    }

    mutating func recordGeneration(latencyMs: Int) {
        generations += 1
        latenciesMs.append(max(0, latencyMs))
        if latenciesMs.count > Self.maxLatencies {
            latenciesMs.removeFirst(latenciesMs.count - Self.maxLatencies)
        }
    }
    mutating func recordError() { errors += 1 }
    mutating func recordAccept(charsAccepted acceptedChars: Int) {
        accepts += 1
        charsAccepted += max(0, acceptedChars)
    }
    mutating func reset() { self = CotypingStats() }
}

/// Async persistence seam so JSON encoding and UserDefaults writes never run
/// on the UI actor. Actor implementations also give queued snapshots a single
/// deterministic writer.
protocol CotypingStatsPersisting: Sendable {
    func persist(_ stats: CotypingStats) async
    func remove() async
}

actor UserDefaultsCotypingStatsPersistence: CotypingStatsPersisting {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    func persist(_ stats: CotypingStats) {
        guard let data = try? JSONEncoder().encode(stats) else { return }
        defaults.set(data, forKey: key)
    }

    func remove() {
        defaults.removeObject(forKey: key)
    }
}

/// Owns the persisted `CotypingStats` and records into it from the coordinator.
/// `@MainActor` + `ObservableObject` keeps UI state immediately observable, but
/// persistence is delegated to an actor. Local only — written to UserDefaults
/// as the same small JSON blob; never leaves the device.
@MainActor
final class CotypingStatsStore: ObservableObject {
    static let shared = CotypingStatsStore()

    @Published private(set) var stats: CotypingStats

    private let persistence: any CotypingStatsPersisting
    private var persistenceTask: Task<Void, Never>?
    private var revision = 0
    private var enqueuedRevision = 0
    private static let key = "lokalbotv3.cotypingStats"

    init(
        defaults: UserDefaults = .standard,
        persistence: (any CotypingStatsPersisting)? = nil
    ) {
        self.persistence = persistence
            ?? UserDefaultsCotypingStatsPersistence(defaults: defaults, key: Self.key)
        stats = Self.load(from: defaults)
    }

    func recordGeneration(latencyMs: Int) {
        stats.recordGeneration(latencyMs: latencyMs)
        revision &+= 1
        enqueuePersistence()
    }

    func recordError() {
        stats.recordError()
        revision &+= 1
        enqueuePersistence()
    }

    /// Accept counters stay live in the UI for every chunk, but disk remains
    /// dirty until the coordinator closes that suggestion.
    func recordAccept(charsAccepted: Int) {
        stats.recordAccept(charsAccepted: charsAccepted)
        revision &+= 1
    }

    /// One persistence boundary for all chunks accepted from one suggestion.
    func suggestionCompleted() {
        guard revision != enqueuedRevision else { return }
        enqueuePersistence()
    }

    func clear() {
        guard stats != CotypingStats() else { return }
        stats.reset()
        revision &+= 1
        enqueuedRevision = revision
        let previous = persistenceTask
        let persistence = persistence
        persistenceTask = Task.detached(priority: .utility) {
            if let previous { await previous.value }
            await persistence.remove()
        }
    }

    /// Persists any dirty counters and awaits all background writes. This is
    /// the termination safety net for an in-flight/partially accepted session.
    func flushPersistence() async {
        if revision != enqueuedRevision { enqueuePersistence() }
        let pending = persistenceTask
        await pending?.value
    }

    /// Waits only for work already scheduled by a completed suggestion.
    func waitForPendingPersistence() async {
        let pending = persistenceTask
        await pending?.value
    }

    private func enqueuePersistence() {
        let persistedStats = stats
        enqueuedRevision = revision
        let previous = persistenceTask
        let persistence = persistence
        persistenceTask = Task.detached(priority: .utility) {
            if let previous { await previous.value }
            await persistence.persist(persistedStats)
        }
    }

    private static func load(from defaults: UserDefaults) -> CotypingStats {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(CotypingStats.self, from: data) else { return CotypingStats() }
        return decoded
    }
}
