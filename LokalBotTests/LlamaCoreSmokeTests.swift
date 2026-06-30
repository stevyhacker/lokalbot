import XCTest
import LlamaCore

/// Proves the LlamaCore module imports, the vendored libllama.dylib links, and
/// the @rpath resolves at runtime by executing real b9844 C calls.
final class LlamaCoreSmokeTests: XCTestCase {
    func testBackendInitAndDefaultParamsLink() {
        llama_backend_init()
        let model = llama_model_default_params()
        // The n_gpu_layers field must be reachable through the imported struct.
        // b9844 defaults it to -1 ("a negative value means all layers" per
        // llama.h) — i.e. full Metal offload, exactly what the runtime wants.
        XCTAssertEqual(model.n_gpu_layers, -1)
        let ctx = llama_context_default_params()
        XCTAssertGreaterThan(ctx.n_ctx, 0)
        // Intentionally NOT calling llama_backend_free(): this runs in the shared
        // test process, and freeing the global backend here would be a footgun for
        // any test class that loads a model (LlamaCotypingRuntime's once-let init).
        // The smoke test's purpose — LlamaCore imports, dylib links, default-params
        // structs resolve — needs no teardown.
    }
}
