import Foundation

/// Built-in LLM backend, part 1 of 3: the model catalog + on-disk validation.
/// A bundled llama.cpp `llama-server` (Metal) speaks the OpenAI-compatible API
/// on localhost. Users choose and download GGUF models on demand into
/// Application Support. No Ollama / LM Studio required.
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
        let sha256: String?
        let sizeGB: Double
        let blurb: String
        /// Qwen3 (non-2507) thinks by default; we turn that off for summaries.
        let disablesThinking: Bool

        init(id: String, displayName: String, fileName: String, url: String,
             sha256: String? = nil, sizeGB: Double, blurb: String,
             disablesThinking: Bool) {
            self.id = id
            self.displayName = displayName
            self.fileName = fileName
            self.url = url
            self.sha256 = sha256
            self.sizeGB = sizeGB
            self.blurb = blurb
            self.disablesThinking = disablesThinking
        }
    }

    static let compactFallbackID = "qwen3.5-0.8b"
    static let recommendedSummarizationID = "qwen3.6-35b-a3b"
    static let recommendedCotypingID = "gemma4-e4b-q5-xl"
    /// Summarizer preselected on Macs that can't hold the recommended model.
    static let compactSummarizationID = "qwen3.5-4b"

    /// Fresh-install summarizer default: the recommended long-meeting model
    /// when this Mac's RAM can hold it, else the compact Qwen3.5 4B. A 17.7 GB
    /// first download that then fails to load is a worse first run than a
    /// modest model that just works — the big one stays one click away in
    /// Settings → Models, labelled "Recommended".
    static func defaultSummarizationID(for capability: HardwareCapability) -> String {
        guard let entry = entry(id: recommendedSummarizationID) else {
            return compactSummarizationID
        }
        let fit = ModelFit.evaluate(modelSizeGB: entry.sizeGB, capability: capability)
        return fit == .tooLarge ? compactSummarizationID : recommendedSummarizationID
    }

    /// Local GGUF catalog, roughly ordered from tiny fallbacks to higher-quality
    /// meeting-summary and cotyping options.
    static let entries: [Entry] = [
        Entry(id: compactFallbackID, displayName: "Qwen 3.5 · 0.8B",
              fileName: "Qwen3.5-0.8B-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/6ab461498e2023f6e3c1baea90a8f0fe38ab64d0/Qwen3.5-0.8B-Q4_K_M.gguf",
              sha256: "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517",
              sizeGB: 0.53, blurb: "Tiny downloadable fallback for short meetings and cotyping.",
              disablesThinking: true),
        Entry(id: "lfm2.5-1.2b-instruct", displayName: "LFM2.5 1.2B Instruct",
              fileName: "LFM2.5-1.2B-Instruct-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/LFM2.5-1.2B-Instruct-GGUF/resolve/bf1ebe055f24ddd24f3622d933a63b42606773f3/LFM2.5-1.2B-Instruct-Q4_K_M.gguf",
              sha256: "856aeee6d85ac684b1db8dee48795b44fc06731ecda03aee36ece682413a9b9a",
              sizeGB: 0.85, blurb: "Fast English-first cotyping mode. Under 1 GB.",
              disablesThinking: false),
        Entry(id: "qwen3.5-2b", displayName: "Qwen3.5 2B",
              fileName: "Qwen3.5-2B-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/f6d5376be1edb4d416d56da11e5397a961aca8ae/Qwen3.5-2B-Q4_K_M.gguf",
              sha256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
              sizeGB: 1.28, blurb: "Lightweight multilingual cotyping option. Any Apple Silicon Mac.",
              disablesThinking: true),
        Entry(id: "qwen3.5-4b", displayName: "Qwen3.5 4B",
              fileName: "Qwen3.5-4B-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf",
              sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
              sizeGB: 2.8, blurb: "Balanced local summaries with long context. 16 GB Macs.",
              disablesThinking: true),
        Entry(id: "gemma4-e4b", displayName: "Gemma 4 E4B",
              fileName: "gemma-4-E4B-it-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/0720adb23527c2cd5ea01d1db067cd960327fdac/gemma-4-E4B-it-Q4_K_M.gguf",
              sha256: "519b9793ed6ce0ff530f1b7c96e848e08e49e7af4d57bb97f76215963a54146d",
              sizeGB: 4.98, blurb: "Legacy edge-optimized option. 16 GB Macs.",
              disablesThinking: false),
        Entry(id: recommendedCotypingID, displayName: "Gemma 4 · E4B",
              fileName: "gemma-4-E4B-it-UD-Q5_K_XL.gguf",
              url: "https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/0720adb23527c2cd5ea01d1db067cd960327fdac/gemma-4-E4B-it-UD-Q5_K_XL.gguf",
              sha256: "5fb55145c335edd0c2e0cdd7505ed1557cd346787449479be65094c6f5b016c6",
              sizeGB: 6.66, blurb: "Recommended cotyping quality target (Q5 XL quant). 16 GB+ Macs.",
              disablesThinking: false),
        Entry(id: "lfm2.5-8b-a1b", displayName: "LFM2.5 8B (MoE)",
              fileName: "LFM2.5-8B-A1B-Q4_K_M.gguf",
              url: "https://huggingface.co/LiquidAI/LFM2.5-8B-A1B-GGUF/resolve/dfd5fdcad7a1c0d31473fb4ca443b8befbacddf0/LFM2.5-8B-A1B-Q4_K_M.gguf",
              sha256: "4923ec14f06b968b74d663e5949867d2d9c3bf13a20b8be1a9f9af39989b2bb0",
              sizeGB: 5.16, blurb: "Fast meeting summaries; ~1B active. 16 GB Macs.",
              disablesThinking: false),
        Entry(id: recommendedSummarizationID, displayName: "Qwen 3.6 · 35B-A3B",
              fileName: "Qwen3.6-35B-A3B-UD-IQ4_XS.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/a483e9e6cbd595906af30beda3187c2663a1118c/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf",
              sha256: "649d7508507b84638732c4f52c24c8b15843c6dca2f3ff793ae07c14a67ebbb3",
              sizeGB: 17.73, blurb: "Recommended long-meeting default; ~3B active. 32 GB+ Macs.",
              disablesThinking: true),
        Entry(id: "qwen3.6-27b", displayName: "Qwen3.6 27B",
              fileName: "Qwen3.6-27B-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/Qwen3.6-27B-GGUF/resolve/82d411acf4a06cfb8d9b073a5211bf410bfc29bf/Qwen3.6-27B-Q4_K_M.gguf",
              sha256: "5ed60d0af4650a854b1755bd392f9aef4872643dc25a254bc68043fa638392a0",
              sizeGB: 16.8, blurb: "Maximum-quality dense summaries. Best on 32 GB+ Macs.",
              disablesThinking: true),
        Entry(id: "gemma4-12b", displayName: "Gemma 4 12B",
              fileName: "gemma-4-12b-it-Q4_K_M.gguf",
              url: "https://huggingface.co/unsloth/gemma-4-12B-it-GGUF/resolve/d997c805aafe035a8024f961c6e1afd6b30d79a5/gemma-4-12b-it-Q4_K_M.gguf",
              sha256: "43fec98c5102b1c446b4ddd0a9439f1db3a2e1f2e0b8cd143ce1ea619a9403d6",
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

    /// Downloads live in <storage>/models/.
    static func localURL(for entry: Entry, storage: StorageManager) -> URL? {
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
