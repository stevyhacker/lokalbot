import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device summarization backend that satisfies `TextEngine` by running Apple
/// Intelligence in-process — no localhost server, no model download.
///
/// FoundationModels exists only in the macOS 26 SDK while LokalBot deploys to
/// 14.4, so every framework symbol stays behind `#if canImport` plus
/// `if #available(macOS 26.0, *)`. On older systems `generate` throws instead,
/// which keeps the file compiling on the 14.4 target and lets the pipeline fall
/// back to another `TextEngine`.
struct AppleIntelligenceEngine: TextEngine {
    var displayName: String { "Apple Intelligence" }

    /// Upper bound on characters handed to the on-device model. Its context
    /// window is small (~4k tokens shared across instructions, prompt, and the
    /// reply), so we trim to roughly 3k tokens of input (≈4 chars/token) rather
    /// than let the model reject an oversized prompt. We keep the *tail*: the
    /// task instruction is appended last and must survive trimming.
    static let maxPromptCharacters = 12_000

    func generate(system: String, prompt: String, context: [String]) async throws -> String {
        let availability = await FoundationModelAvailability.current()
        guard case .available = availability else {
            throw TextEngineError.unavailable(
                availability.reason ?? FoundationModelAvailability.unsupportedMessage
            )
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let user = Self.composePrompt(prompt: prompt, context: context)
            return try await Self.respond(instructions: system, prompt: user)
        }
        #endif
        // Unreachable once `current()` reported `.available` (only macOS 26+ with
        // the framework can), but required so the 14.4 build throws on every path
        // instead of relying solely on the guard above.
        throw TextEngineError.unavailable(FoundationModelAvailability.unsupportedMessage)
    }

    /// Joins the context blocks and task prompt into one user turn, dropping
    /// blank entries and capping length. `nonisolated`/`static` so it stays unit
    /// testable without a model or the main actor. Mirrors the localhost engines'
    /// `(context + [prompt]).joined("\n\n")` shape so backends agree on layout.
    nonisolated static func composePrompt(prompt: String, context: [String]) -> String {
        let joined = (context + [prompt])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return cappedToTail(joined, limit: maxPromptCharacters)
    }

    /// Returns the last `limit` characters of `text` (the whole text when
    /// shorter). Trimming the head preserves the trailing task instruction.
    nonisolated static func cappedToTail(_ text: String, limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        let start = text.index(text.endIndex, offsetBy: -limit)
        return String(text[start...])
    }

    #if canImport(FoundationModels)
    /// Single-turn request against the default system model. Generation failures
    /// (guardrails, unsupported language, oversized prompt, …) map to
    /// `badResponse` so the pipeline treats them like any other engine error.
    @available(macOS 26.0, *)
    private static func respond(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: prompt)
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as LanguageModelSession.GenerationError {
            throw TextEngineError.badResponse(message(for: error))
        } catch {
            throw TextEngineError.badResponse(error.localizedDescription)
        }
    }

    /// Maps Apple's generation errors to short, user-facing sentences. The
    /// `@unknown default` keeps us compiling if Apple adds cases in a later SDK.
    @available(macOS 26.0, *)
    private static func message(for error: LanguageModelSession.GenerationError) -> String {
        switch error {
        case .exceededContextWindowSize:
            return "The transcript was too long for the on-device model."
        case .assetsUnavailable:
            return "Apple Intelligence assets are unavailable right now."
        case .guardrailViolation:
            return "Apple Intelligence blocked this content with its safety guardrails."
        case .unsupportedGuide:
            return "Apple Intelligence rejected the request format."
        case .unsupportedLanguageOrLocale:
            return "Apple Intelligence does not support this language or locale."
        case .decodingFailure:
            return "Apple Intelligence returned a response that could not be decoded."
        case .rateLimited:
            return "Apple Intelligence is busy right now. Try again in a moment."
        case .concurrentRequests:
            return "Apple Intelligence is already handling another request."
        case .refusal:
            return "Apple Intelligence declined to answer this prompt."
        @unknown default:
            return error.localizedDescription
        }
    }
    #endif
}
