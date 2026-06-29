import Foundation
import FluidAudio

struct TranscriptionModelStore {
    struct Environment {
        let appSupport: URL
        let fluidAudioRoot: URL
        let fluidAudioModelsRoot: URL
        let whisperKitRepoRoot: URL

        static var live: Environment {
            let fileManager = FileManager.default
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent(AppIdentifiers.bundleID, isDirectory: true)
            let fluidAudioRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("FluidAudio", isDirectory: true)
            let fluidAudioModelsRoot = fluidAudioRoot
                .appendingPathComponent("Models", isDirectory: true)
            let whisperKitRepoRoot = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
                .appendingPathComponent("huggingface", isDirectory: true)
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent("argmaxinc", isDirectory: true)
                .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            return Environment(
                appSupport: appSupport,
                fluidAudioRoot: fluidAudioRoot,
                fluidAudioModelsRoot: fluidAudioModelsRoot,
                whisperKitRepoRoot: whisperKitRepoRoot)
        }
    }

    static func downloadedChoices(environment: Environment = .live) -> Set<String> {
        Set(TranscriptionModelChoice.allCases.filter {
            isDownloaded($0, environment: environment)
        }.map(\.id))
    }

    static func isDownloaded(_ choice: TranscriptionModelChoice,
                             environment: Environment = .live) -> Bool {
        switch choice {
        case .parakeetV3:
            return AsrModels.modelsExist(
                at: parakeetDirectory(.parakeetV3, environment: environment),
                version: .v3)
        case .parakeetV2:
            return AsrModels.modelsExist(
                at: parakeetDirectory(.parakeetV2, environment: environment),
                version: .v2)
        case .qwenASR17B:
            return qwenModelExists(modelID: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit",
                                   environment: environment)
        case .qwenASR06B:
            return qwenModelExists(modelID: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit",
                                   environment: environment)
        case .graniteSpeech:
            return ModelFileValidator.looksLikeGGUF(GraniteSpeechEngine.modelURL(appSupport: environment.appSupport))
                && ModelFileValidator.looksLikeGGUF(GraniteSpeechEngine.projectorURL(appSupport: environment.appSupport))
        case .whisperLarge:
            return whisperModelDirectories(environment: environment).contains { directory in
                requiredFilesPresent(
                    at: directory,
                    requiredFiles: ["config.json", "AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc"])
            }
        case .cohere:
            return requiredFilesPresent(
                at: cohereDirectory(environment: environment),
                requiredFiles: ModelNames.CohereTranscribe.requiredModels)
        case .senseVoice:
            return onnxModelExists(folderName: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09",
                                   environment: environment)
        case .gigaamRussian:
            return onnxModelExists(folderName: "sherpa-onnx-nemo-ctc-giga-am-v3-russian-2025-12-16",
                                   environment: environment)
        }
    }

    static func delete(_ choice: TranscriptionModelChoice,
                       environment: Environment = .live) throws {
        let fileManager = FileManager.default
        for directory in cacheDirectories(for: choice, environment: environment) {
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        }
    }

    private static func cacheDirectories(for choice: TranscriptionModelChoice,
                                         environment: Environment) -> [URL] {
        switch choice {
        case .parakeetV3:
            [parakeetDirectory(.parakeetV3, environment: environment)]
        case .parakeetV2:
            [parakeetDirectory(.parakeetV2, environment: environment)]
        case .qwenASR17B:
            [qwenDirectory(modelID: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit",
                           environment: environment)]
        case .qwenASR06B:
            [qwenDirectory(modelID: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit",
                           environment: environment)]
        case .graniteSpeech:
            [GraniteSpeechEngine.modelRoot(appSupport: environment.appSupport)]
        case .whisperLarge:
            whisperModelDirectories(environment: environment)
        case .cohere:
            [cohereDirectory(environment: environment)]
        case .senseVoice:
            [onnxDirectory(folderName: "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2025-09-09",
                           environment: environment)]
        case .gigaamRussian:
            [onnxDirectory(folderName: "sherpa-onnx-nemo-ctc-giga-am-v3-russian-2025-12-16",
                           environment: environment)]
        }
    }

    private static func parakeetDirectory(_ repo: Repo, environment: Environment) -> URL {
        environment.fluidAudioModelsRoot.appendingPathComponent(repo.folderName, isDirectory: true)
    }

    private static func cohereDirectory(environment: Environment) -> URL {
        environment.fluidAudioRoot.appendingPathComponent(Repo.cohereTranscribeCoreml.folderName,
                                                          isDirectory: true)
    }

    private static func qwenDirectory(modelID: String, environment: Environment) -> URL {
        QwenASREngine.hubStyleCacheDir(
            base: environment.appSupport.appendingPathComponent("qwen3-asr-models", isDirectory: true),
            modelID: modelID)
    }

    private static func qwenModelExists(modelID: String, environment: Environment) -> Bool {
        directoryContainsFile(withExtension: "safetensors",
                              at: qwenDirectory(modelID: modelID, environment: environment))
    }

    private static func onnxDirectory(folderName: String, environment: Environment) -> URL {
        environment.appSupport
            .appendingPathComponent("sherpa-models", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    private static func onnxModelExists(folderName: String, environment: Environment) -> Bool {
        let directory = onnxDirectory(folderName: folderName, environment: environment)
        let hasModel = ["model.int8.onnx", "model.onnx"].contains { fileName in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path)
        }
        return hasModel && FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("tokens.txt").path)
    }

    private static func whisperModelDirectories(environment: Environment) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: environment.whisperKitRepoRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        return contents.filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                  values.isDirectory == true else { return false }
            return url.lastPathComponent.contains("large-v3-v20240930")
        }
    }

    private static func requiredFilesPresent(at directory: URL, requiredFiles: some Sequence<String>) -> Bool {
        requiredFiles.allSatisfy { fileName in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName).path)
        }
    }

    private static func directoryContainsFile(withExtension fileExtension: String, at directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return false }

        for case let url as URL in enumerator where url.pathExtension == fileExtension {
            return true
        }
        return false
    }
}
