import Foundation

/// App-wide ledger of which model weights are resident in memory, with a RAM
/// budget and least-recently-used eviction. The llama runtimes (`LlamaServer`
/// instances and the in-process cotyping runtime) register on load, touch on
/// reuse, and consult `willLoad` before pulling new weights in so the app
/// never silently stacks a summarizer, an embedder, and a cotyping model past
/// what the machine can hold.
///
/// GGUF rows include weights plus a role-specific cache/KV allowance. Retained
/// CoreML/MLX reservations are supplied as non-evictable bytes by
/// `ModelRuntimeRegistry`, so every local model load consults one RAM budget.
/// Eviction choices live in `ModelResidencyPolicy` (pure, unit-tested); this
/// class owns the mutable GGUF ledger and the `@Published` UI mirror.
@MainActor
final class ModelResidency: ObservableObject {

    static let shared = ModelResidency()

    struct Resident: Identifiable, Equatable {
        let id: String
        var label: String
        var bytes: Int64
        /// Present for out-of-process runtimes so diagnostics can report the
        /// helper's live footprint. In-process models leave this nil because the
        /// app footprint cannot be attributed to one model accurately.
        var processIdentifier: pid_t?
        /// Paired with the PID so a stale row can never be mistaken for an
        /// unrelated process after macOS reuses that identifier.
        var processStartTime: UInt64?
        var lastUsed: Date
    }

    @Published private(set) var residents: [Resident] = []
    /// Unload hooks by resident id, kept out of `Resident` so it stays a
    /// plain Equatable value for the UI.
    private var unloaders: [String: () async -> Void] = [:]
    /// A runtime can stop and restart while an older shutdown task is still
    /// finishing. Generations keep that stale task from unregistering the
    /// replacement model that now occupies the same logical residency id.
    private var registrationGenerations: [String: UUID] = [:]

    /// Weights budget: half of physical RAM by default, leaving the other
    /// half for the app, transcription engines, and everything else.
    var budgetBytes: Int64

    init(budgetBytes: Int64 = Int64(ProcessInfo.processInfo.physicalMemory / 2)) {
        self.budgetBytes = budgetBytes
    }

    var totalBytes: Int64 { residents.reduce(0) { $0 + $1.bytes } }

    func register(id: String, label: String, bytes: Int64,
                  processIdentifier: pid_t? = nil,
                  processStartTime: UInt64? = nil,
                  generation: UUID = UUID(),
                  unload: @escaping () async -> Void) {
        unloaders[id] = unload
        registrationGenerations[id] = generation
        let entry = Resident(
            id: id,
            label: label,
            bytes: bytes,
            processIdentifier: processIdentifier,
            processStartTime: processStartTime,
            lastUsed: Date()
        )
        if let index = residents.firstIndex(where: { $0.id == id }) {
            residents[index] = entry
        } else {
            residents.append(entry)
        }
    }

    func touch(id: String) {
        guard let index = residents.firstIndex(where: { $0.id == id }) else { return }
        residents[index].lastUsed = Date()
    }

    func unregister(id: String) {
        unloaders[id] = nil
        registrationGenerations[id] = nil
        residents.removeAll { $0.id == id }
    }

    /// Removes a row only if it is still the registration created by the
    /// caller. Used by subprocess shutdown paths, which can finish after a
    /// replacement process has already registered under the same id.
    func unregister(id: String, ifGenerationMatches generation: UUID) {
        guard registrationGenerations[id] == generation else { return }
        unregister(id: id)
    }

    /// Evict least-recently-used residents (never `id` itself — a model swap
    /// on the same runtime replaces in place) until `bytes` fits the budget.
    /// Call right before loading new weights.
    func willLoad(id: String, bytes: Int64, reservedBytes: Int64 = 0) async {
        let victims = ModelResidencyPolicy.evictions(
            residents: residents.map { .init(id: $0.id, bytes: $0.bytes, lastUsed: $0.lastUsed) },
            incomingID: id, incomingBytes: bytes, reservedBytes: reservedBytes,
            budgetBytes: budgetBytes)
        for victim in victims {
            let unload = unloaders[victim]
            let label = residents.first { $0.id == victim }?.label ?? victim
            lokalbotLog("model residency: evicting \(label) to fit incoming load")
            // Drop the ledger row first so the victim's own unregister call
            // (from its unload path) is a harmless no-op.
            unregister(id: victim)
            await unload?()
        }
    }

    /// File size of the weights at `url` (0 if unreadable) — the bytes every
    /// caller registers with, so ledger entries stay comparable.
    nonisolated static func weightBytes(at url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? 0
    }
}

/// The eviction decision, kept pure for unit tests.
enum ModelResidencyPolicy {

    struct Entry: Equatable {
        let id: String
        let bytes: Int64
        let lastUsed: Date
    }

    /// IDs to evict, least-recently-used first, so the surviving residents
    /// plus the incoming load fit `budgetBytes`. The incoming id is never a
    /// victim. When the newcomer alone exceeds the budget, everything else is
    /// evicted and the load proceeds best-effort — refusing to load would
    /// break the feature the user just asked for.
    static func evictions(residents: [Entry], incomingID: String,
                          incomingBytes: Int64, reservedBytes: Int64 = 0,
                          budgetBytes: Int64) -> [String] {
        let kept = residents.filter { $0.id != incomingID }
        var total = kept.reduce(0) { $0 + $1.bytes }
        total = total.addingReportingOverflow(max(0, incomingBytes)).overflow
            ? .max : total + max(0, incomingBytes)
        total = total.addingReportingOverflow(max(0, reservedBytes)).overflow
            ? .max : total + max(0, reservedBytes)
        guard total > budgetBytes else { return [] }
        var victims: [String] = []
        for entry in kept.sorted(by: { $0.lastUsed < $1.lastUsed }) {
            guard total > budgetBytes else { break }
            victims.append(entry.id)
            total -= entry.bytes
        }
        return victims
    }
}
