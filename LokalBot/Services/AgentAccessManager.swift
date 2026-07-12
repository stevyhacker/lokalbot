import Combine
import Foundation

/// App-side owner of the external-agent marker and local-model wake watcher.
@MainActor
final class AgentAccessManager: ObservableObject {
    @Published private(set) var isEnabled = false

    private let gate: AgentAccessGate
    private let storage: StorageManager
    private let settings: () -> AppSettings
    private let startEngine: (AppSettings, StorageManager) async -> String?

    private var watcher: DispatchSourceFileSystemObject?
    private var handlingWake = false

    init(
        storage: StorageManager,
        settings: @escaping () -> AppSettings,
        gate: AgentAccessGate = AgentAccessGate(),
        startEngine: ((AppSettings, StorageManager) async -> String?)? = nil
    ) {
        self.storage = storage
        self.settings = settings
        self.gate = gate
        self.startEngine = startEngine ?? {
            await Self.startMainLLM(settings: $0, storage: $1)
        }
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
            if let failure = await startEngine(settings(), storage) {
                gate.writeWakeError(failure)
            } else {
                gate.clearWakeError()
            }
            handlingWake = false
            handleControlDirectoryChange()
        }
    }

    static func startMainLLM(
        settings: AppSettings,
        storage: StorageManager
    ) async -> String? {
        switch AgentLLMEndpointResolver.resolve(settings: settings) {
        case .builtIn(let modelID):
            guard let entry = ModelCatalog.entry(
                id: modelID,
                custom: settings.customBuiltInModels)
                ?? ModelCatalog.entry(id: modelID),
                let modelURL = ModelCatalog.localURL(for: entry, storage: storage) else {
                return "The built-in model isn't downloaded. Open LokalBot → Settings → Models and download it, then ask again."
            }
            do {
                try await LlamaServer.shared.ensureRunning(modelAt: modelURL)
                return nil
            } catch {
                return "LokalBot's model server failed to start: \(error.localizedDescription)"
            }
        case .ready:
            return "The Main LLM is set to an external server; ask_library answers with LokalBot's built-in engine. Pick a built-in model in LokalBot → Settings → Models."
        case .unsupported(let reason):
            return reason
        }
    }
}
