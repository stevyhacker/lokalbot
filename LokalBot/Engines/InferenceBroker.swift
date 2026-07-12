import Foundation

/// One actor owns when the shared llama-server runtimes start and stop.
/// Consumers take leases instead of calling `ensureRunning` directly: a
/// lease boots on demand, pins the model during use, and makes the server
/// eligible for an idle unload after the final release.
actor InferenceBroker {

    /// Start/stop hooks for one role. Tests inject recorders rather than
    /// launching real llama-server processes.
    struct RuntimeHooks {
        let ensure: (URL) async throws -> Void
        let stop: () async -> Void
    }

    static let shared = InferenceBroker()

    private let hooks: [InferenceRole: RuntimeHooks]
    private let lingerSeconds: [InferenceRole: TimeInterval]
    private let leaseStateSink: @MainActor (Set<String>, [String: [String]]) -> Void

    private var book = LeaseBook()
    private var generations: [InferenceRole: UInt64] = [:]
    private var lingerTasks: [InferenceRole: Task<Void, Never>] = [:]
    private var expiryTasks: [UUID: Task<Void, Never>] = [:]

    init(hooks: [InferenceRole: RuntimeHooks]? = nil,
         lingerSeconds: [InferenceRole: TimeInterval] = [:],
         leaseStateSink: (@MainActor (Set<String>, [String: [String]]) -> Void)? = nil) {
        self.hooks = hooks ?? [
            .mainLLM: RuntimeHooks(
                ensure: { try await LlamaServer.shared.ensureRunning(modelAt: $0) },
                stop: { await LlamaServer.shared.stop() }),
            .embedder: RuntimeHooks(
                ensure: { try await LlamaServer.embedder.ensureRunning(modelAt: $0) },
                stop: { await LlamaServer.embedder.stop() }),
            .cotypingServer: RuntimeHooks(
                ensure: { try await LlamaServer.cotyping.ensureRunning(modelAt: $0) },
                stop: { await LlamaServer.cotyping.stop() }),
        ]
        self.lingerSeconds = lingerSeconds
        self.leaseStateSink = leaseStateSink ?? { pinned, descriptions in
            ModelResidency.shared.setLeaseState(pinned: pinned, descriptions: descriptions)
        }
    }

    /// Records and publishes the pin before ensuring the runtime. If ensure
    /// fails, the record is removed and the original runtime error propagates.
    func lease(_ role: InferenceRole, model: URL, priority: InferencePriority,
               purpose: String,
               expiresAfter ttl: TimeInterval? = nil) async throws -> InferenceLease {
        generations[role, default: 0] += 1
        lingerTasks[role]?.cancel()
        lingerTasks[role] = nil
        let expiresAt = ttl.map { Date().addingTimeInterval($0) }
        let lease = book.acquire(role: role, priority: priority, purpose: purpose,
                                 expiresAt: expiresAt)
        await pushLeaseState()
        do {
            try await runtimeHooks(for: role).ensure(model)
        } catch {
            book.release(id: lease.id)
            await pushLeaseState()
            throw error
        }
        if let ttl { scheduleExpiry(for: lease, after: ttl) }
        return lease
    }

    func release(_ lease: InferenceLease) async {
        expiryTasks[lease.id]?.cancel()
        expiryTasks[lease.id] = nil
        guard book.release(id: lease.id) else { return }
        await pushLeaseState()
        if book.activeCount(for: lease.role) == 0 {
            scheduleLinger(for: lease.role)
        }
    }

    /// Acquires one scoped lease and releases it on success or error.
    nonisolated func withLease<T>(_ role: InferenceRole, model: URL,
                                  priority: InferencePriority, purpose: String,
                                  _ body: () async throws -> T) async throws -> T {
        let acquired = try await lease(role, model: model, priority: priority,
                                       purpose: purpose)
        do {
            let value = try await body()
            await release(acquired)
            return value
        } catch {
            await release(acquired)
            throw error
        }
    }

    func activeLeaseCount(_ role: InferenceRole) -> Int {
        book.activeCount(for: role)
    }

    private func scheduleLinger(for role: InferenceRole) {
        let generation = generations[role, default: 0]
        let delay = lingerSeconds[role] ?? role.defaultLingerSeconds
        lingerTasks[role] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.lingerFired(role: role, generation: generation)
        }
    }

    private func lingerFired(role: InferenceRole, generation: UInt64) async {
        guard generations[role, default: 0] == generation,
              book.activeCount(for: role) == 0 else { return }
        lingerTasks[role] = nil
        lokalbotLog("inference broker: stopping idle \(role.rawValue) after linger")
        await runtimeHooks(for: role).stop()
    }

    private func scheduleExpiry(for lease: InferenceLease, after ttl: TimeInterval) {
        expiryTasks[lease.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ttl * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.expiryFired(leaseID: lease.id)
        }
    }

    private func expiryFired(leaseID: UUID) async {
        guard let record = book.record(id: leaseID),
              let expiresAt = record.expiresAt, expiresAt <= Date() else { return }
        await release(record.lease)
    }

    private func runtimeHooks(for role: InferenceRole) -> RuntimeHooks {
        guard let roleHooks = hooks[role] else {
            preconditionFailure("no runtime hooks for \(role.rawValue)")
        }
        return roleHooks
    }

    private func pushLeaseState() async {
        let pinned = book.pinnedResidencyIDs
        let descriptions = book.descriptionsByResidencyID
        await leaseStateSink(pinned, descriptions)
    }
}
