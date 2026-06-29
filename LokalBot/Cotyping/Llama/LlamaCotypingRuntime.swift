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
/// overlaps the previous one. On a pure-attention model this drives true
/// partial-prefix reuse: the shared prefix KV is kept and only the diverged
/// suffix is re-decoded. The bundled Qwen3.5 is a hybrid SSM/attention model
/// whose recurrent state cannot be partially rewound to a prefix, so it falls
/// back to a full re-prefill on every call; `lastPrefillTokenCount` still
/// surfaces the diverged-suffix length as the meaningful reuse signal either
/// way. The capability is cached once at load (`supportsPartialReuse`).
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
    /// True only for pure-attention models, whose per-position KV cells can be
    /// partially evicted (`seq_rm` at a non-zero p0). Recurrent/hybrid (SSM/Mamba)
    /// models cannot rewind their rolling state to a prefix, so they full-reprefill.
    private var supportsPartialReuse = false

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
        // Cache the architecture capability once, at load: probing inside generate
        // would emit a dylib stderr warning on every call for recurrent models.
        supportsPartialReuse = !llama_model_is_recurrent(m) && !llama_model_is_hybrid(m)
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
        supportsPartialReuse = false
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

        // KV-reuse probe: how many leading tokens this prompt shares with the cache.
        // Clamp to count-1 so we ALWAYS decode >=1 token and get fresh logits for the
        // next-token sample — required when the new prompt equals/prefixes the cached
        // one (e.g. an identical re-generation), else we'd sample from stale logits.
        let shared = IncrementalPrefill.commonPrefixLength(cachedTokens, promptTokens)
        let reuse = min(shared, promptTokens.count - 1)

        if supportsPartialReuse, reuse > 0 {
            // Attention model: keep the shared prefix KV, re-decode only the suffix.
            // seq_rm drops [reuse, end) — the diverged tail plus any stale tokens the
            // previous generation appended past the prompt.
            llama_memory_seq_rm(mem, 0, Int32(reuse), -1)
            guard decode(Array(promptTokens[reuse...]), startPos: Int32(reuse),
                         logitsLastOnly: true) else { return "" }
        } else {
            // Recurrent/hybrid model (SSM/Mamba) cannot partially rewind its rolling
            // state, so a non-zero-p0 seq_rm is unsupported — reset and prefill the
            // whole prompt from position 0. `reuse` above is still the meaningful
            // KV-reuse *signal* callers read via lastPrefillTokenCount.
            llama_memory_seq_rm(mem, 0, 0, -1)
            guard decode(promptTokens, startPos: 0, logitsLastOnly: true) else { return "" }
        }
        lastPrefillTokenCount = promptTokens.count - reuse
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
