import Combine
import Foundation

/// Coalesces child-object change notifications before forwarding them through
/// `AppState`. Several subsystems often publish during one logical transition;
/// forwarding each event separately invalidated the entire window repeatedly.
@MainActor
final class AppStateInvalidationBridge {
    private let emit: () -> Void
    private var observers: Set<AnyCancellable> = []
    private var emissionPending = false

    init(emit: @escaping () -> Void) {
        self.emit = emit
    }

    func observe<Changes: Publisher>(_ changes: Changes)
    where Changes.Output == Void, Changes.Failure == Never {
        changes.sink { [weak self] in
            self?.requestEmission()
        }.store(in: &observers)
    }

    private func requestEmission() {
        guard !emissionPending else { return }
        emissionPending = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            emissionPending = false
            emit()
        }
    }
}
