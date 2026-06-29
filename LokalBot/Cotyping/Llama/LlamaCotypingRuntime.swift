import Foundation
import LlamaCore

enum LlamaRuntimeError: Error, Equatable {
    case modelLoadFailed(String)
    case contextInitFailed
    case decodeFailed
}

/// In-process llama.cpp runtime for cotyping. Owns the model, a persistent
/// context + memory, and serializes all inference on the actor's executor
/// (off the main actor).
///
/// The KV-reuse probe (`IncrementalPrefill`) reports how much of each prompt
/// overlaps the previous one. The bundled Qwen3.5 is a hybrid SSM/attention
/// model whose recurrent state cannot be partially rewound to a prefix, so the
/// prompt is re-prefilled in full on every call; `lastPrefillTokenCount` still
/// surfaces the diverged-suffix length as the meaningful reuse signal. On a
/// pure-attention model the same probe would drive true partial-prefix reuse.
///
/// Pinned to llama.cpp `b9789`; symbols verified against the vendored dylib.
actor LlamaCotypingRuntime {
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var loadedModelPath: String?
    /// The prompt most recently prefilled into the context (basis for the
    /// incremental KV-reuse probe against the next prompt).
    private var cachedTokens: [Int32] = []
    private(set) var lastPrefillTokenCount: Int = 0

    private static var backendReady = false

    var isLoaded: Bool { model != nil && ctx != nil }

    // MARK: - Lifecycle

    func loadIfNeeded(modelPath: String) throws {
        if isLoaded, loadedModelPath == modelPath { return }
        unload()

        if !Self.backendReady {
            llama_backend_init()
            Self.backendReady = true
        }

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 99   // full Metal offload (matches LlamaServer's -ngl 99)
        guard let m = llama_model_load_from_file(modelPath, mparams) else {
            throw LlamaRuntimeError.modelLoadFailed(modelPath)
        }

        var cparams = llama_context_default_params()
        cparams.n_ctx = 2048        // matches LlamaServer.cotyping.contextTokens
        cparams.n_batch = 2048
        let threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        cparams.n_threads = threads
        cparams.n_threads_batch = threads
        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            throw LlamaRuntimeError.contextInitFailed
        }

        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        loadedModelPath = modelPath
        cachedTokens = []
        lastPrefillTokenCount = 0
        warmup()
    }

    /// Frees the llama context + model when the actor is deallocated. Without
    /// this the Metal backend's residency set is still live at process exit,
    /// which trips a teardown assertion in the vendored ggml-metal build.
    deinit {
        if let c = ctx { llama_free(c) }
        if let m = model { llama_model_free(m) }
    }

    /// Prewarm == load + the priming decode `loadIfNeeded` already performs.
    func prewarm(modelPath: String) throws { try loadIfNeeded(modelPath: modelPath) }

    func unload() {
        if let c = ctx { llama_free(c) }
        if let m = model { llama_model_free(m) }
        ctx = nil
        model = nil
        vocab = nil
        loadedModelPath = nil
        cachedTokens = []
    }

    /// Runs one priming decode so Metal pipelines are hot before the first real
    /// keystroke, then clears the KV so generation starts from a clean cache.
    private func warmup() {
        guard let vocab, let ctx else { return }
        let bos = llama_vocab_bos(vocab)
        _ = decode([bos], startPos: 0, logitsLastOnly: true)
        llama_memory_clear(llama_get_memory(ctx), true)
        cachedTokens = []
    }

    // MARK: - Tokenize / detokenize

    func tokenize(_ text: String, addBOS: Bool) -> [Int32] {
        guard let vocab else { return [] }
        return text.withCString { cstr -> [Int32] in
            let textLen = Int32(strlen(cstr))
            var capacity = textLen + (addBOS ? 1 : 0) + 8
            var tokens = [Int32](repeating: 0, count: Int(capacity))
            var n = llama_tokenize(vocab, cstr, textLen, &tokens, capacity, addBOS, true)
            if n < 0 {                      // buffer too small: -n is required size
                capacity = -n
                tokens = [Int32](repeating: 0, count: Int(capacity))
                n = llama_tokenize(vocab, cstr, textLen, &tokens, capacity, addBOS, true)
            }
            return Array(tokens.prefix(Int(max(0, n))))
        }
    }

    private func piece(for token: Int32) -> String {
        guard let vocab else { return "" }
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
        }
        guard n > 0 else { return "" }
        let bytes = buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Decode

    /// Decodes `tokens` starting at `startPos` in sequence 0. When
    /// `logitsLastOnly` is true only the final token requests logits (prefill).
    @discardableResult
    private func decode(_ tokens: [Int32], startPos: Int32, logitsLastOnly: Bool) -> Bool {
        guard let ctx, !tokens.isEmpty else { return true }
        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }
        for i in 0..<tokens.count {
            batch.token[i] = tokens[i]
            batch.pos[i] = startPos + Int32(i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = (logitsLastOnly ? (i == tokens.count - 1) : true) ? 1 : 0
        }
        batch.n_tokens = Int32(tokens.count)
        return llama_decode(ctx, batch) == 0
    }

    // MARK: - Generate

    func generate(
        promptTokens: [Int32],
        maxTokens: Int,
        samplerSpecs: [LlamaSamplerSpec],
        onToken: @Sendable (String) -> Bool
    ) -> String {
        guard let ctx, let vocab, !promptTokens.isEmpty else { return "" }
        guard let sampler = makeSampler(samplerSpecs) else { return "" }
        defer { llama_sampler_free(sampler) }

        let mem = llama_get_memory(ctx)
        // KV-reuse probe: how many leading tokens this prompt shares with the one
        // resident in the cache. The bundled Qwen3.5 is a hybrid SSM/attention
        // model whose recurrent state cannot be partially rewound, so we cannot
        // physically keep only the shared prefix; we rebuild the full prompt each
        // call. `lastPrefillTokenCount` still reports the *new* (diverged-suffix)
        // tokens, which is the meaningful KV-reuse signal for callers.
        let reuse = IncrementalPrefill.commonPrefixLength(cachedTokens, promptTokens)
        lastPrefillTokenCount = promptTokens.count - reuse

        // Recurrent state has no per-position cells to evict, so reset and
        // prefill the whole prompt from position 0 for a clean, contiguous state.
        llama_memory_seq_rm(mem, 0, 0, -1)
        guard decode(promptTokens, startPos: 0, logitsLastOnly: true) else { return "" }
        cachedTokens = promptTokens

        var output = ""
        var pos = Int32(promptTokens.count)
        for _ in 0..<maxTokens {
            let tok = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { break }
            llama_sampler_accept(sampler, tok)
            let text = piece(for: tok)
            output += text
            if !onToken(text) { break }
            guard decode([tok], startPos: pos, logitsLastOnly: true) else { break }
            pos += 1
        }
        return output
    }

    private func makeSampler(_ specs: [LlamaSamplerSpec]) -> UnsafeMutablePointer<llama_sampler>? {
        let params = llama_sampler_chain_default_params()
        guard let chain = llama_sampler_chain_init(params) else { return nil }
        for spec in specs {
            let s: UnsafeMutablePointer<llama_sampler>?
            switch spec {
            case let .penalties(lastN, rep, freq, present):
                s = llama_sampler_init_penalties(lastN, rep, freq, present)
            case let .topK(k):            s = llama_sampler_init_top_k(k)
            case let .topP(p, minKeep):   s = llama_sampler_init_top_p(p, minKeep)
            case let .minP(p, minKeep):   s = llama_sampler_init_min_p(p, minKeep)
            case let .temp(t):            s = llama_sampler_init_temp(t)
            case let .dist(seed):         s = llama_sampler_init_dist(seed)
            }
            if let s { llama_sampler_chain_add(chain, s) }
        }
        return chain
    }
}
