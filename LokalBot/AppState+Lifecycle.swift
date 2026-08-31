import Foundation

@MainActor
extension AppState {
    /// Large meeting libraries can take seconds to enumerate, repair, duration-
    /// probe, and FTS-index. Do that work on a utility executor and publish one
    /// sorted snapshot when ready instead of blocking the first app window.
    func loadLibraryInBackground() {
        libraryLoadTask?.cancel()
        let rootURL = storage.rootURL
        libraryLoadTask = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .utility) { () -> MeetingLibraryLoadOutcome in
                guard !Task.isCancelled else { return .cancelled }
                let workerStorage = StorageManager(rootURL: rootURL)
                do {
                    return .loaded(try workerStorage.loadMeetingLibrary())
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
            let outcome = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case .cancelled:
                self.libraryLoadTask = nil
                return
            case .failed(let detail):
                self.handleLibraryLoadFailure(detail)
                self.libraryLoadTask = nil
                return
            case .loaded(let loaded):
                self.finishLibraryLoad(loaded)
            }
        }
    }

    private func finishLibraryLoad(_ load: MeetingLibraryLoad) {
        var byID = Dictionary(uniqueKeysWithValues: load.meetings.map { ($0.id, $0) })
        // Preserve meetings created while the background scan was running.
        for meeting in meetings { byID[meeting.id] = meeting }
        let merged = byID.values.sorted { $0.startedAt > $1.startedAt }
        meetings = merged
        libraryReady = true
        applyLibraryIssues(load.issues)
        outcomeIndex.refresh(meetings: merged)
        pipeline.resumePending(meetings: merged)
        // Dreaming was deliberately gated while launch recovery rebuilt the
        // library and durable processing queue. Re-check immediately; pending
        // work keeps the downtime gate closed until a later timer tick.
        dreaming.tick()
        reindexLibraryInBackground(merged)
        libraryLoadTask = nil
        if let pending = pendingRecordingStart {
            pendingRecordingStart = nil
            lastError = nil
            startRecording(
                context: pending.context,
                source: pending.source,
                systemAudioPolicy: pending.systemAudioPolicy
            )
        }
    }

    func retryLibraryLoad() {
        guard !recording.isRecording, !recording.isStarting else {
            lastError = "Finish the current recording before reloading the meeting library."
            return
        }
        libraryLoadError = nil
        libraryReady = false
        loadLibraryInBackground()
    }

    func applyLibraryIssues(_ issues: [MeetingLibraryLoad.Issue]) {
        guard !issues.isEmpty else {
            libraryLoadError = nil
            return
        }
        let message = "Loaded the meeting library, but \(issues.count) item"
            + (issues.count == 1 ? "" : "s")
            + " could not be read or repaired. Retry after checking disk access."
        libraryLoadError = message
        lastError = message
        issues.prefix(10).forEach { lokalbotLog("meeting library issue: \($0.message)") }
    }

    func handleLibraryLoadFailure(_ detail: String) {
        let message = "Could not load the meeting library. No recordings will start until it is available. \(detail)"
        libraryReady = false
        libraryLoadError = message
        pendingRecordingStart = nil
        lastError = message
        lokalbotLog("meeting library unavailable: \(detail)")
    }

    private func reindexLibraryInBackground(_ meetings: [Meeting]) {
        let worker = searchIndexWorkQueue
        Task { await worker.enqueue(meetings) }
    }

    func reindexSearchInBackground(_ meeting: Meeting) {
        let worker = searchIndexWorkQueue
        Task { await worker.enqueue(meeting) }
    }

    func reindexEmbeddingInBackground(_ meeting: Meeting) {
        embeddingIndexTasks.removeValue(forKey: meeting.id)?.task.cancel()
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            try? await self.embeddingIndex.index(meeting)
            guard self.embeddingIndexTasks[meeting.id]?.token == token else { return }
            self.embeddingIndexTasks.removeValue(forKey: meeting.id)
        }
        embeddingIndexTasks[meeting.id] = (token, task)
    }

    /// Index rows are reconstructible, but a failed SQLite cleanup must not
    /// become permanent once the meeting folder disappears. Retry both stores
    /// with bounded backoff for the rest of the session; durable tombstones and
    /// each index's startup reconciliation cover interruption or app exit.
    func scheduleIndexCleanup(_ meetingID: Meeting.ID) {
        indexCleanupTasks.removeValue(forKey: meetingID)?.task.cancel()
        let token = UUID()
        let worker = searchIndexWorkQueue
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var embeddingClean = false
            var searchClean = false
            var attempt = 0

            while !Task.isCancelled {
                let result = await worker.remove(meetingID)
                embeddingClean = embeddingClean || result.embedding
                searchClean = searchClean || result.search
                guard !Task.isCancelled,
                      self.indexCleanupTasks[meetingID]?.token == token else { return }
                if embeddingClean && searchClean {
                    self.indexCleanupTasks.removeValue(forKey: meetingID)
                    return
                }

                attempt += 1
                if attempt.isMultiple(of: 4) {
                    let reconciled = await worker.reconcileDeletedMeetings()
                    embeddingClean = embeddingClean || reconciled.embedding
                    searchClean = searchClean || reconciled.search
                }
                let delayMilliseconds = min(30_000, 250 * (1 << min(attempt, 7)))
                try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            }
        }
        indexCleanupTasks[meetingID] = (token, task)
    }

    private enum CotypingRuntimeOperation {
        case unload
        case prewarm
    }

    func scheduleCotypingRuntimeUnload() {
        scheduleCotypingRuntimeOperation(.unload)
    }

    func scheduleCotypingPrewarm() {
        scheduleCotypingRuntimeOperation(.prewarm)
    }

    /// Queue lifecycle changes instead of launching independent tasks. An
    /// unload intentionally runs even if a later operation cancels its task:
    /// the later operation awaits it before loading another model.
    private func scheduleCotypingRuntimeOperation(_ operation: CotypingRuntimeOperation) {
        let previous = cotypingRuntimeTask
        previous?.cancel()
        let taskID = UUID()
        cotypingRuntimeTaskID = taskID
        cotypingRuntimeTask = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            defer {
                if self.cotypingRuntimeTaskID == taskID {
                    self.cotypingRuntimeTask = nil
                    self.cotypingRuntimeTaskID = nil
                }
            }
            switch operation {
            case .unload:
                await self.cotypingEngine.unload()
            case .prewarm:
                guard !Task.isCancelled, self.settings.cotypingEnabled else { return }
                await self.cotypingEngine.prewarm()
            }
        }
    }

    func prepareForTermination() async {
        if let terminationCleanupTask {
            await terminationCleanupTask.value
            return
        }
        let task = Task { @MainActor in
            interactive = false
            settingsStore.flush()
            let pendingCotypingRuntimeTask = self.cotypingRuntimeTask
            pendingCotypingRuntimeTask?.cancel()
            await pendingCotypingRuntimeTask?.value
            self.cotypingRuntimeTask = nil
            cotypingRuntimeTaskID = nil
            libraryLoadTask?.cancel()
            libraryLoadTask = nil
            for entry in embeddingIndexTasks.values { entry.task.cancel() }
            embeddingIndexTasks.removeAll()
            for entry in indexCleanupTasks.values { entry.task.cancel() }
            indexCleanupTasks.removeAll()
            await searchIndexWorkQueue.stop()
            pendingRecordingStart = nil
            recording.prepareForTermination()
            detector.stop()
            audioMonitor.stop()
            sampler.stop()
            screenshots.stop()
            quickRecallHotKey.stop()
            dailyMemoryExportScheduler.stop()
            memoryRoutines.stop()
            dreaming.stop()
            chat.stop()
            dictation.stop()
            cotyping.stop()
            await cotypingLearning.flushPersistence()
            await CotypingStatsStore.shared.flushPersistence()
            await agentSessions.shutdownAll()
            await cotypingEngine.unload()
            await LlamaServer.shared.stop()
            await LlamaServer.embedder.stop()
            await LlamaServer.cotyping.stop()
            await GraniteSpeechEngine.shared.shutdown()
        }
        terminationCleanupTask = task
        await task.value
    }

}
