import Combine
import Foundation

/// App-side owner of the external-agent marker and local-model wake watcher.
@MainActor
final class AgentAccessManager: ObservableObject {
    @Published private(set) var isEnabled = false

    private let gate: AgentAccessGate
    private let storage: StorageManager
    private let settings: () -> AppSettings
    /// Test seam. When nil (production), wakes go through `wakeMainLLM`,
    /// which holds a TTL lease on the broker.
    private let startEngine: ((AppSettings, StorageManager) async -> String?)?
    private let broker: InferenceBroker
    /// The lease behind the most recent ask_library wake. Replaced (not
    /// stacked) on every wake; released on disable; expires on its own TTL.
    private var agentLease: InferenceLease?

    /// One external question rarely comes alone: the TTL keeps the model
    /// warm for follow-ups, then returns the RAM ten minutes after the last.
    static let agentLeaseTTL: TimeInterval = 600

    private var watcher: DispatchSourceFileSystemObject?
    private var handlingWake = false

    init(
        storage: StorageManager,
        settings: @escaping () -> AppSettings,
        gate: AgentAccessGate = AgentAccessGate(),
        startEngine: ((AppSettings, StorageManager) async -> String?)? = nil,
        broker: InferenceBroker = .shared
    ) {
        self.storage = storage
        self.settings = settings
        self.gate = gate
        self.startEngine = startEngine
        self.broker = broker
    }

    func start() {
        isEnabled = gate.isEnabled
        if isEnabled { startWatcher() }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            do {
                try gate.enable()
            } catch {
                return
            }
            isEnabled = true
            startWatcher()
        } else {
            stopWatcher()
            gate.disable()
            isEnabled = false
            releaseAgentLease()
        }
    }

    private func startWatcher() {
        guard watcher == nil else { return }
        let descriptor = open(gate.controlDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.handleControlDirectoryChange()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
        handleControlDirectoryChange()
    }

    private func stopWatcher() {
        watcher?.cancel()
        watcher = nil
    }

    private func handleControlDirectoryChange() {
        guard !handlingWake, gate.consumeWake() else { return }
        handlingWake = true
        Task { @MainActor in
            let failure: String?
            if let startEngine {
                failure = await startEngine(settings(), storage)
            } else {
                failure = await wakeMainLLM(settings: settings(), storage: storage)
            }
            if let failure {
                gate.writeWakeError(failure)
            } else {
                gate.clearWakeError()
            }
            handlingWake = false
            handleControlDirectoryChange()
        }
    }

    enum ResolvedBuiltInModel: Equatable {
        case model(URL)
        case failure(String)
    }

    /// Pure resolution half of the wake path. The failure strings are the
    /// exact messages the CLI relays to external agents — keep them verbatim.
    static func resolveBuiltInModelURL(
        settings: AppSettings,
        storage: StorageManager
    ) -> ResolvedBuiltInModel {
        switch AgentLLMEndpointResolver.resolve(settings: settings) {
        case .builtIn(let modelID):
            guard let entry = ModelCatalog.entry(
                id: modelID,
                custom: settings.customBuiltInModels)
                ?? ModelCatalog.entry(id: modelID),
                let modelURL = ModelCatalog.localURL(for: entry, storage: storage) else {
                return .failure("The built-in model isn't downloaded. Open LokalBot → Settings → Models and download it, then ask again.")
            }
            return .model(modelURL)
        case .ready:
            return .failure("The Main LLM is set to an external server; ask_library answers with LokalBot's built-in engine. Pick a built-in model in LokalBot → Settings → Models.")
        case .unsupported(let reason):
            return .failure(reason)
        }
    }

    /// Default wake handler: resolve the built-in model, then hold a TTL
    /// lease on the Main LLM.
    func wakeMainLLM(settings: AppSettings, storage: StorageManager) async -> String? {
        switch Self.resolveBuiltInModelURL(settings: settings, storage: storage) {
        case .failure(let reason):
            return reason
        case .model(let modelURL):
            return await acquireOrRenewAgentLease(modelURL: modelURL)
        }
    }

    /// Acquires a fresh TTL lease, then releases the previous one — in that
    /// order, so the lease count never dips to zero and starts a linger.
    /// Re-acquiring instead of renewing means the broker's ensure runs on
    /// every wake: a llama-server that crashed since the last question is
    /// revived instead of trusted.
    func acquireOrRenewAgentLease(modelURL: URL) async -> String? {
        do {
            let fresh = try await broker.lease(.mainLLM, model: modelURL,
                                               priority: .agent,
                                               purpose: "ask_library",
                                               expiresAfter: Self.agentLeaseTTL)
            if let previous = agentLease {
                await broker.release(previous)
            }
            agentLease = fresh
            return nil
        } catch {
            return "LokalBot's model server failed to start: \(error.localizedDescription)"
        }
    }

    private func releaseAgentLease() {
        guard let lease = agentLease else { return }
        agentLease = nil
        let broker = self.broker
        Task { await broker.release(lease) }
    }
}
