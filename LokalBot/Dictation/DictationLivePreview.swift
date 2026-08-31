import Foundation

/// Serialized ASR access and incremental live-preview lifecycle. Kept separate
/// from recording start/finish orchestration so each subsystem stays bounded.
extension DictationCoordinator {
    func transcribeSerialized(
        _ audioURL: URL,
        config: AppSettings
    ) async throws -> Transcript {
        let precedingTask = asrHandoffTask
        let result = DictationASRResultBox()
        let task = Task {
            if let precedingTask { await precedingTask.value }
            do {
                try Task.checkCancellation()
                result.store(.success(try await Self.transcribe(audioURL, config: config)))
            } catch {
                result.store(.failure(error))
            }
        }
        asrHandoffTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return try result.resolve()
    }

    func startLivePreviewIfNeeded(
        audioURL: URL,
        config: AppSettings,
        generation session: Int
    ) {
        guard config.dictationShowOverlay, config.dictationLivePreview else { return }
        livePreviewTaskID += 1
        let taskID = livePreviewTaskID
        livePreviewTask?.cancel()
        let task = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.runLivePreviewLoop(
                audioURL: audioURL,
                config: config,
                generation: session,
                taskID: taskID)
        }
        livePreviewTask = task
    }

    private func runLivePreviewLoop(
        audioURL: URL,
        config: AppSettings,
        generation session: Int,
        taskID: Int
    ) async {
        defer {
            if generation == session, livePreviewTaskID == taskID {
                livePreviewTask = nil
                isLivePreviewWorking = false
            }
        }
        var progress = LivePreviewProgress()
        do {
            try await Task.sleep(for: .milliseconds(1_200))
            while !Task.isCancelled {
                try ensureLivePreviewActive(session: session, taskID: taskID)
                let duration = recorder.captureHealth().duration
                let minimumAdvance = duration < 10 ? 1.25 : 2.0
                guard duration >= 1.25,
                      duration - progress.lastPreviewedDuration >= minimumAdvance else {
                    try await Task.sleep(for: .milliseconds(450))
                    continue
                }
                progress = try await updateLivePreview(
                    audioURL: audioURL,
                    config: config,
                    session: session,
                    taskID: taskID,
                    progress: progress)
                try ensureLivePreviewActive(session: session, taskID: taskID)
                isLivePreviewWorking = false
                refreshOverlay()
                try await Task.sleep(
                    for: .milliseconds(Int(Self.livePreviewInterval(after: duration) * 1_000)))
            }
        } catch is CancellationError {
            if generation == session, livePreviewTaskID == taskID {
                isLivePreviewWorking = false
            }
        } catch {
            if generation == session, livePreviewTaskID == taskID {
                isLivePreviewWorking = false
                lokalbotLog("dictation live preview stopped: \(error.localizedDescription)")
            }
        }
    }

    private struct LivePreviewProgress {
        var lastPreviewedDuration: TimeInterval = 0
        var accumulatedText = ""
    }

    private func updateLivePreview(
        audioURL: URL,
        config: AppSettings,
        session: Int,
        taskID: Int,
        progress: LivePreviewProgress
    ) async throws -> LivePreviewProgress {
        do {
            let window = try await Self.makeIncrementalLivePreviewWindow(
                from: audioURL,
                storageRoot: storageRoot,
                previousEnd: progress.lastPreviewedDuration)
            defer { try? FileManager.default.removeItem(at: window.url) }
            try ensureLivePreviewActive(session: session, taskID: taskID)
            beginLivePreviewUpdate()
            return try await transcribeLivePreview(
                window,
                config: config,
                session: session,
                taskID: taskID,
                progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if isCurrentLivePreview(session: session, taskID: taskID) {
                livePreviewStatus = liveTranscript.isEmpty ? "Listening" : "Live"
                lokalbotLog("dictation live preview skipped: \(error.localizedDescription)")
            }
            return progress
        }
    }

    private func beginLivePreviewUpdate() {
        isLivePreviewWorking = true
        livePreviewStatus = liveTranscript.isEmpty ? "Listening" : "Updating"
        refreshOverlay()
    }

    private func transcribeLivePreview(
        _ window: IncrementalLivePreviewWindow,
        config: AppSettings,
        session: Int,
        taskID: Int,
        progress: LivePreviewProgress
    ) async throws -> LivePreviewProgress {
        do {
            let transcript = try await transcribeSerialized(window.url, config: config)
            try ensureLivePreviewActive(
                session: session,
                taskID: taskID,
                requiresRecording: false)
            let text = Transcript.normalizedText(
                transcript.segments.map(\.displayText).joined(separator: " "))
            return applyLivePreviewText(text, window: window, progress: progress)
        } catch DictationError.noAudio {
            return .init(
                lastPreviewedDuration: window.endTime,
                accumulatedText: progress.accumulatedText)
        } catch DictationError.noSpeech {
            return .init(
                lastPreviewedDuration: window.endTime,
                accumulatedText: progress.accumulatedText)
        }
    }

    private func applyLivePreviewText(
        _ text: String,
        window: IncrementalLivePreviewWindow,
        progress: LivePreviewProgress
    ) -> LivePreviewProgress {
        guard !text.isEmpty else {
            return .init(
                lastPreviewedDuration: window.endTime,
                accumulatedText: progress.accumulatedText)
        }
        let accumulated = window.startTime == 0
            ? text
            : DictationPreviewTextStitcher.stitch(
                previous: progress.accumulatedText,
                incoming: text)
        liveTranscript = DictationLiveTranscript.preview(from: accumulated)
        livePreviewStatus = "Live"
        refreshOverlay()
        return .init(
            lastPreviewedDuration: window.endTime,
            accumulatedText: accumulated)
    }

    private func ensureLivePreviewActive(
        session: Int,
        taskID: Int,
        requiresRecording: Bool = true
    ) throws {
        try Task.checkCancellation()
        guard isCurrentLivePreview(session: session, taskID: taskID),
              !requiresRecording || state.isRecording else {
            throw CancellationError()
        }
    }

    private func isCurrentLivePreview(session: Int, taskID: Int) -> Bool {
        generation == session && livePreviewTaskID == taskID
    }

    func cancelLivePreview(reset: Bool) {
        livePreviewTaskID += 1
        livePreviewTask?.cancel()
        livePreviewTask = nil
        isLivePreviewWorking = false
        if reset { resetLivePreview() }
    }

    func resetLivePreview() {
        liveTranscript = DictationLiveTranscript()
        livePreviewStatus = ""
        isLivePreviewWorking = false
        isLivePreviewEnabled = false
    }
}
