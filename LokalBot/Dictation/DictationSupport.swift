import Foundation

extension DictationCoordinator {
    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case transcribing(startedAt: Date)
        case composing(startedAt: Date)

        var isRecording: Bool {
            if case .recording = self { true } else { false }
        }

        var isWorking: Bool {
            switch self {
            case .idle: false
            case .recording, .transcribing, .composing: true
            }
        }

        var label: String {
            switch self {
            case .idle: "Ready"
            case .recording: "Recording"
            case .transcribing: "Transcribing"
            case .composing: "Composing"
            }
        }
    }
}

final class DictationASRResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Transcript, Error>?

    func store(_ result: Result<Transcript, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func resolve() throws -> Transcript {
        lock.lock()
        let result = self.result
        lock.unlock()
        guard let result else { throw CancellationError() }
        return try result.get()
    }
}

enum DictationError: LocalizedError {
    case noAudio
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .noAudio: "Recording was too short to transcribe."
        case .noSpeech: "No speech detected."
        }
    }
}
