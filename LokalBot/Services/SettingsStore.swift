import Foundation

/// The single, always-alive owner of the persisted `AppSettings` value.
///
/// Long-lived services (pipeline, dictation, cotyping, chat tools, screenshots)
/// capture this store instead of weak-referencing `AppState`: a weak capture
/// with a `?? AppSettings()` fallback would silently hand out factory-default
/// settings if `AppState` were ever released — an incorrect success. The store
/// makes "settings always exist" true in the type system.
///
/// `AppState.settings` remains the UI-facing binding surface; its `didSet`
/// writes through here, so the store is always current.
@MainActor
final class SettingsStore {
    var current: AppSettings {
        didSet { current.save() }
    }

    init() {
        current = AppSettings.load()
    }
}
