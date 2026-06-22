import Foundation

/// Built-in LLM backend, part 1 of 3: the model catalog + on-disk validation.
/// A bundled llama.cpp `llama-server` (Metal) speaks the OpenAI-compatible API
/// on localhost. The small default model ships inside the app; bigger ones
/// download on demand (Handy-style catalog). No Ollama / LM Studio required.
///
/// Runtime split (mirrors the lifecycle/prompt/lifecycle separation): catalog
/// here, download orchestration in `ModelDownloadManager.swift`, the server
/// subprocess in `LlamaServer.swift`.
struct ModelCatalog {

    struct Entry: Codable, Identifiable, Hashable {
        let id: String
        let displayName: String
        let fileName: String
        let url: String
        let sizeGB: Double
        let blurb: String
        /// Qwen3 (non-2507) thinks by default; we turn that off for summaries.
        let disablesThinking: Bool
        var isBundled: Bool { id == ModelCatalog.bundledID }
    }

    static let bundledID = "qwen3.5-0.8b"

    /// Five recommended models, smallest first. Current generations
    /// (Qwen3.5, Gemma 4) verified June 2026 — same families Cotabby ships.
    static let entries: [Entry] = [
        Entry(id: bundledID, displayName: "Qwen3.5 0.8B (built-in)",
              fileName: "Qwen3.5-0.8B-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf",
              sizeGB: 0.53, blurb: "Ships with the app. Fast, fine for short meetings.",
              disablesThinking: true),
        Entry(id: "qwen3.5-2b", displayName: "Qwen3.5 2B",
              fileName: "Qwen3.5-2B-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf",
              sizeGB: 1.28, blurb: "Best quality under 1.5 GB. Any Apple Silicon Mac.",
              disablesThinking: true),
        Entry(id: "gemma4-e4b", displayName: "Gemma 4 E4B",
              fileName: "gemma-4-E4B-it-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf",
              sizeGB: 4.98, blurb: "Edge-optimized (MatFormer). 16 GB Macs.",
              disablesThinking: false),
        Entry(id: "lfm2.5-8b-a1b", displayName: "LFM2.5 8B (MoE)",
              fileName: "LFM2.5-8B-A1B-Q4_K_M.gguf",
              url: "https://huggingface.co/LiquidAI/LFM2.5-8B-A1B-GGUF/resolve/main/LFM2.5-8B-A1B-Q4_K_M.gguf",
              sizeGB: 5.16, blurb: "Liquid AI MoE — ~1B active, extremely fast. 16 GB Macs.",
              disablesThinking: false),
        Entry(id: "qwen3.6-35b-a3b", displayName: "Qwen3.6 35B (MoE)",
              fileName: "Qwen3.6-35B-A3B-UD-IQ4_XS.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf",
              sizeGB: 17.73, blurb: "Newest generation; 35B quality, ~3B active. 32 GB+ Macs.",
              disablesThinking: true),
    ]

    static func entry(id: String) -> Entry? { entries.first { $0.id == id } }

    static func selectableEntries(custom: [Entry]) -> [Entry] {
        entries + custom.filter { customEntry in
            !entries.contains { $0.id == customEntry.id || $0.fileName == customEntry.fileName }
        }
    }

    static func entry(id: String, custom: [Entry]) -> Entry? {
        selectableEntries(custom: custom).first { $0.id == id }
    }

    /// Bundled model lives in Resources; downloads live in <storage>/models/.
    static func localURL(for entry: Entry, storage: StorageManager) -> URL? {
        if entry.isBundled,
           let bundled = Bundle.main.resourceURL?
               .appendingPathComponent("llama-models/\(entry.fileName)"),
           ModelFileValidator.looksLikeGGUF(bundled) {
            return bundled
        }
        let downloaded = storage.rootURL.appendingPathComponent("models/\(entry.fileName)")
        return ModelFileValidator.looksLikeGGUF(downloaded) ? downloaded : nil
    }
}

enum ModelFileValidator {
    static func looksLikeGGUF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("GGUF".utf8)
    }
}
