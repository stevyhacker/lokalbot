import XCTest
import FluidAudio
@testable import LokalBot

final class TranscriptionModelStoreTests: XCTestCase {
    func testDownloadedChoicesReadDiskCaches() throws {
        let (root, environment) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeFluidAudioParakeetV3(in: environment)
        try writeQwenModel(modelID: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit", in: environment)
        try writeGraniteModel(in: environment)
        try writeWhisperModel(in: environment)
        try writeFluidAudioCohere(in: environment)
        try writeOnnxModel(
            folderName: "sherpa-onnx-nemo-ctc-giga-am-v3-russian-2025-12-16",
            in: environment)

        let downloaded = TranscriptionModelStore.downloadedChoices(environment: environment)

        XCTAssertTrue(downloaded.contains(TranscriptionModelChoice.parakeetV3.id))
        XCTAssertTrue(downloaded.contains(TranscriptionModelChoice.qwenASR06B.id))
        XCTAssertTrue(downloaded.contains(TranscriptionModelChoice.graniteSpeech.id))
        XCTAssertTrue(downloaded.contains(TranscriptionModelChoice.whisperLarge.id))
        XCTAssertTrue(downloaded.contains(TranscriptionModelChoice.cohere.id))
        XCTAssertTrue(downloaded.contains(TranscriptionModelChoice.gigaamRussian.id))
        XCTAssertFalse(downloaded.contains(TranscriptionModelChoice.parakeetV2.id))
        XCTAssertFalse(downloaded.contains(TranscriptionModelChoice.senseVoice.id))
    }

    func testDeleteRemovesOnlySelectedTranscriptionCache() throws {
        let (root, environment) = try makeEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }

        try writeQwenModel(modelID: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit", in: environment)
        try writeQwenModel(modelID: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit", in: environment)

        try TranscriptionModelStore.delete(.qwenASR06B, environment: environment)

        XCTAssertFalse(TranscriptionModelStore.isDownloaded(.qwenASR06B, environment: environment))
        XCTAssertTrue(TranscriptionModelStore.isDownloaded(.qwenASR17B, environment: environment))
    }

    private func makeEnvironment() throws -> (URL, TranscriptionModelStore.Environment) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcription-model-store-\(UUID().uuidString)", isDirectory: true)
        let environment = TranscriptionModelStore.Environment(
            appSupport: root.appendingPathComponent("app-support", isDirectory: true),
            fluidAudioRoot: root.appendingPathComponent("fluidaudio", isDirectory: true),
            fluidAudioModelsRoot: root.appendingPathComponent("fluidaudio-models", isDirectory: true),
            whisperKitRepoRoot: root.appendingPathComponent("whisperkit-coreml", isDirectory: true))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, environment)
    }

    private func writeFluidAudioParakeetV3(in environment: TranscriptionModelStore.Environment) throws {
        let directory = environment.fluidAudioModelsRoot.appendingPathComponent(Repo.parakeetV3.folderName)
        for fileName in ModelNames.ASR.requiredModelsV3().union([ModelNames.ASR.vocabularyFile]) {
            try writeEmptyFile(directory.appendingPathComponent(fileName))
        }
    }

    private func writeFluidAudioCohere(in environment: TranscriptionModelStore.Environment) throws {
        let directory = environment.fluidAudioRoot.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName)
        for fileName in ModelNames.CohereTranscribe.requiredModels {
            try writeEmptyFile(directory.appendingPathComponent(fileName))
        }
    }

    private func writeQwenModel(modelID: String, in environment: TranscriptionModelStore.Environment) throws {
        let directory = QwenASREngine.hubStyleCacheDir(
            base: environment.appSupport.appendingPathComponent("qwen3-asr-models", isDirectory: true),
            modelID: modelID)
        try writeEmptyFile(directory.appendingPathComponent("model.safetensors"))
    }

    private func writeGraniteModel(in environment: TranscriptionModelStore.Environment) throws {
        try writeGGUF(GraniteSpeechEngine.modelURL(appSupport: environment.appSupport))
        try writeGGUF(GraniteSpeechEngine.projectorURL(appSupport: environment.appSupport))
    }

    private func writeWhisperModel(in environment: TranscriptionModelStore.Environment) throws {
        let directory = environment.whisperKitRepoRoot
            .appendingPathComponent("openai_whisper-large-v3-v20240930_turbo", isDirectory: true)
        for fileName in ["config.json", "AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"] {
            try writeEmptyFile(directory.appendingPathComponent(fileName))
        }
    }

    private func writeOnnxModel(folderName: String, in environment: TranscriptionModelStore.Environment) throws {
        let directory = environment.appSupport
            .appendingPathComponent("sherpa-models", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        try writeEmptyFile(directory.appendingPathComponent("model.int8.onnx"))
        try writeEmptyFile(directory.appendingPathComponent("tokens.txt"))
    }

    private func writeEmptyFile(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data().write(to: url)
    }

    private func writeGGUF(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("GGUF".utf8).write(to: url)
    }
}
