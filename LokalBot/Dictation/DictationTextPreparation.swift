import Foundation

/// The intent boundary is shared by production and hermetic runtime tests.
/// Transcribe cannot construct a language model or request screen context.
enum DictationTextPreparation {
    struct Result {
        let text: String
        let compositionModel: String?
    }

    @MainActor
    static func prepare(
        speech: String,
        settings: AppSettings,
        screenContext: () async -> DictationScreenContext?,
        makeEngine: (AppSettings) async throws -> TextEngine
    ) async throws -> Result {
        try Task.checkCancellation()
        guard settings.dictationIntent == .compose else {
            return Result(text: speech, compositionModel: nil)
        }
        let context = settings.dictationUseScreenContext ? await screenContext() : nil
        try Task.checkCancellation()
        let engine = try await makeEngine(settings)
        let prompt = DictationComposePrompt.userPrompt(
            spokenText: speech, context: context,
            profile: DictationComposeProfile(personalization: settings.cotypingPersonalization))
        let output = try await engine.generate(system: DictationComposePrompt.system, prompt: prompt, context: [])
        try Task.checkCancellation()
        let text = DictationComposePrompt.normalizedOutput(output)
        guard !text.isEmpty else { throw DictationComposeError.emptyOutput }
        return Result(text: text, compositionModel: engine.displayName)
    }
}
