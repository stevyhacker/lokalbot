import Foundation

/// Single source of truth for LokalBot's on-disk roots. Compiled into both the
/// app and the embedded `lokalbot-cli`, so every binary resolves the same
/// paths — nothing else in the codebase should rebuild these from
/// `FileManager.urls(for: .applicationSupportDirectory, ...)`.
enum AppDirectories {

    /// `~/Library/Application Support` (temp-directory fallback keeps this
    /// total; the URL is always present in practice).
    static var userApplicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// The app's real Application Support home:
    /// `~/Library/Application Support/me.dotenv.LokalBot`.
    ///
    /// Deliberately NOT redirected by the storage-root override: the installed
    /// llama-server binary, its PID markers, transcription model stores, and
    /// the agent runtime live here even under `LOKALBOT_STORAGE_ROOT`
    /// isolation, so hermetic test runs share them with the real install.
    /// Catalog GGUFs are the exception — they download under the overridable
    /// library root (`ModelCatalog.localURL`); `Scripts/e2e.sh` symlinks the
    /// real models/ into its temp root to keep those shared too.
    static var applicationSupport: URL {
        userApplicationSupport.appendingPathComponent(AppIdentifiers.bundleID, isDirectory: true)
    }

    /// FluidAudio's own cache root (`~/Library/Application Support/FluidAudio`)
    /// — the package's convention, not ours; Parakeet/Cohere models land here.
    static var fluidAudioRoot: URL {
        userApplicationSupport.appendingPathComponent("FluidAudio", isDirectory: true)
    }

    /// The meeting-library root — all user data (meetings, indexes, journal,
    /// logs) lives under it. Honors the `LOKALBOT_STORAGE_ROOT` override so UI
    /// tests, hermetic e2e runs, and the CLI all resolve the same isolated
    /// library as the app.
    static var libraryRoot: URL {
        if let override = UITestRuntime.storageRoot {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return applicationSupport
    }
}
