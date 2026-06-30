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
    static let recommendedSummarizationID = "qwen3.6-35b-a3b"
    static let recommendedCotypingID = "gemma4-e4b-q5-xl"

    /// Local GGUF catalog, roughly ordered from tiny fallbacks to higher-quality
    /// meeting-summary and cotyping options.
    static let entries: [Entry] = [
        Entry(id: bundledID, displayName: "Qwen3.5 0.8B (built-in)",
              fileName: "Qwen3.5-0.8B-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf",
              sizeGB: 0.53, blurb: "Ships with the app. Tiny fallback for short meetings and cotyping.",
              disablesThinking: true),
        Entry(id: "lfm2.5-1.2b-instruct", displayName: "LFM2.5 1.2B Instruct",
              fileName: "LFM2.5-1.2B-Instruct-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/LFM2.5-1.2B-Instruct-GGUF/resolve/main/LFM2.5-1.2B-Instruct-Q4_K_M.gguf",
              sizeGB: 0.85, blurb: "Fast English-first cotyping mode. Under 1 GB.",
              disablesThinking: false),
        Entry(id: "qwen3.5-2b", displayName: "Qwen3.5 2B",
              fileName: "Qwen3.5-2B-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf",
              sizeGB: 1.28, blurb: "Lightweight multilingual cotyping option. Any Apple Silicon Mac.",
              disablesThinking: true),
        Entry(id: "qwen3.5-4b", displayName: "Qwen3.5 4B",
              fileName: "Qwen3.5-4B-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf",
              sizeGB: 2.8, blurb: "Balanced local summaries with long context. 16 GB Macs.",
              disablesThinking: true),
        Entry(id: "gemma4-e4b", displayName: "Gemma 4 E4B",
              fileName: "gemma-4-E4B-it-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_M.gguf",
              sizeGB: 4.98, blurb: "Legacy edge-optimized option. 16 GB Macs.",
              disablesThinking: false),
        Entry(id: recommendedCotypingID, displayName: "Gemma 4 E4B Q5 XL",
              fileName: "gemma-4-E4B-it-UD-Q5_K_XL.gguf",
              url: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-UD-Q5_K_XL.gguf",
              sizeGB: 6.66, blurb: "Recommended Cotypist-parity cotyping quality target. 16 GB+ Macs.",
              disablesThinking: false),
        Entry(id: "lfm2.5-8b-a1b", displayName: "LFM2.5 8B (MoE)",
              fileName: "LFM2.5-8B-A1B-Q4_K_M.gguf",
              url: "https://huggingface.co/LiquidAI/LFM2.5-8B-A1B-GGUF/resolve/main/LFM2.5-8B-A1B-Q4_K_M.gguf",
              sizeGB: 5.16, blurb: "Fast meeting summaries; ~1B active. 16 GB Macs.",
              disablesThinking: false),
        Entry(id: recommendedSummarizationID, displayName: "Qwen3.6 35B-A3B (MoE)",
              fileName: "Qwen3.6-35B-A3B-UD-IQ4_XS.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf",
              sizeGB: 17.73, blurb: "Recommended long-meeting default; ~3B active. 32 GB+ Macs.",
              disablesThinking: true),
        Entry(id: "qwen3.6-27b", displayName: "Qwen3.6 27B",
              fileName: "Qwen3.6-27B-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.6-27B-GGUF/resolve/main/Qwen3.6-27B-Q4_K_M.gguf",
              sizeGB: 16.8, blurb: "Maximum-quality dense summaries. Best on 32 GB+ Macs.",
              disablesThinking: true),
        Entry(id: "gemma4-12b", displayName: "Gemma 4 12B",
              fileName: "gemma-4-12b-it-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/gemma-4-12B-it-GGUF/resolve/main/gemma-4-12b-it-Q4_K_M.gguf",
              sizeGB: 7.5, blurb: "Multimodal-family summary option for screenshot/slide workflows.",
              disablesThinking: false),
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
        if ModelFileValidator.looksLikeGGUF(downloaded) { return downloaded }
        return nil
    }
}

enum ModelFileValidator {
    static func looksLikeGGUF(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("GGUF".utf8)
    }
}
