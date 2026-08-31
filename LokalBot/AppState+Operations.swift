import AppKit
import CoreGraphics
import Foundation

extension AppState {
    // MARK: - Detection → recording glue

    /// Builds a detection context for a user-initiated recording on `detectedApp`
    /// (nil → manual), folding in the active calendar event when calendar
    /// detection is enabled and authorized — so menu and command entry points
    /// get calendar titling too.
    func recordingContext(for detectedApp: MeetingDetector.DetectedApp?) -> MeetingDetectionContext? {
        guard let detectedApp else { return nil }
        let event = (settings.calendarDetectionEnabled && calendar.hasAccess)
            ? calendar.activeCandidate(now: Date()) : nil
        return MeetingDetectionContext(
            detectedApp: detectedApp,
            calendarEvent: event,
            confidence: MeetingMatcher.confidence(hasApp: true, hasCalendar: event != nil),
            reason: "user")
    }

    /// A user can explicitly start the scheduled event from Today's upcoming
    /// meeting card before automatic detection fires. Attach the calendar
    /// metadata immediately; capture system audio too when a matching meeting
    /// app is already visible, otherwise RecordingController safely records
    /// the microphone when no meeting app is visible yet.
    func recordingContext(for calendarEvent: CalendarMeetingCandidate) -> MeetingDetectionContext {
        let detectedApp = detector.activeApp ?? MeetingDetector.visibleBrowserMeeting()
        return MeetingDetectionContext(
            detectedApp: detectedApp,
            calendarEvent: calendarEvent,
            confidence: MeetingMatcher.confidence(
                hasApp: detectedApp != nil,
                hasCalendar: true),
            reason: "today-upcoming")
    }

    /// `AudioSourceMonitor` saw an app newly start producing output. Auto-record
    /// in automatic mode only for high-confidence native meeting output or a
    /// verified browser meeting; ignore broader candidates so notification
    /// sounds cannot start recordings.
    func audioMonitorDetected(_ process: AudioProcess) {
        guard !recording.isRecording, !recording.isStarting else { return }
        guard settings.autoRecordMode == .automatic, let bundleID = process.bundleID else { return }
        let calendarEvent = (settings.calendarDetectionEnabled && calendar.hasAccess)
            ? calendar.activeCandidate(now: Date()) : nil
        if let name = MeetingDetector.knownApps[bundleID] {
            guard MeetingDetector.shouldAutoRecordNativeAudioMonitor(
                bundleID: bundleID,
                calendarBacked: calendarEvent != nil) else {
                return
            }
            let detected = MeetingDetector.DetectedApp(name: name, bundleID: bundleID, pid: process.id)
            startRecording(context: detectionContext(detected, calendarEvent), source: "audio-monitor")
            return
        }
        guard let hostBundleID = MeetingDetector.hostBrowserBundleID(forAudioBundleID: bundleID) else { return }
        // The browser is already producing output (the monitor fired on it), so a
        // window-title match OR an active calendar meeting link is enough — the
        // latter catches a generic-title Google Meet the title check misses.
        let titleMatches = MeetingDetector.visibleBrowserMeeting()?.bundleID == hostBundleID
        let calendarBacked = calendarEvent?.meetingURL != nil
        guard MeetingMatcher.browserCountsAsMeeting(
            titleMatchesMarker: titleMatches, hasOutputAudio: true,
            calendarBacked: calendarBacked, requireCalendarForBrowser: settings.requireCalendarForBrowser)
        else { return }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: hostBundleID)
            .first?.localizedName ?? "Browser"
        let detected = MeetingDetector.DetectedApp(name: name, bundleID: hostBundleID, pid: process.id)
        startRecording(context: detectionContext(detected, calendarEvent), source: "audio-monitor")
    }

    func detectionContext(_ app: MeetingDetector.DetectedApp,
                          _ event: CalendarMeetingCandidate?) -> MeetingDetectionContext {
        MeetingDetectionContext(
            detectedApp: app, calendarEvent: event,
            confidence: MeetingMatcher.confidence(hasApp: true, hasCalendar: event != nil),
            reason: "audio-monitor")
    }

    func notifyMeetingDetected(_ context: MeetingDetectionContext) {
        lastError = nil
        let title = MeetingMatcher.recordingTitle(
            calendarTitle: context.calendarEvent?.title,
            useCalendarTitles: settings.useCalendarTitles,
            appName: context.detectedApp?.name)
        RecordingNotifier.shared.meetingDetected(title: title) { [weak self] in
            guard let self,
                  self.settings.autoRecordMode == .ask,
                  !self.recording.isRecording,
                  !self.recording.isStarting else { return }
            self.startRecording(context: context, source: "notification")
        }
    }

    // MARK: - Library operations

    func reprocess(_ meeting: Meeting, transcribe: Bool, summarize: Bool) {
        lastError = nil
        switch pipeline.enqueue(
            meeting,
            transcribe: transcribe,
            summarize: summarize) {
        case .alreadyProcessing:
            lastError = "Summary processing has already started for this meeting. Wait for it to finish before choosing a different processing action."
        case .persistenceFailed:
            lastError = "LokalBot could not save the updated processing request."
        case .enqueued, .coalesced, .updatedActive:
            break
        }
    }

    /// Resume from the latest durable artifact. If transcription already
    /// succeeded, Retry fixes only summarization; missing transcripts still run
    /// the complete pipeline. User-initiated work may download missing models.
    func retryProcessing(_ meeting: Meeting) {
        let work = pipeline.retryWork(
            for: meeting,
            autoSummarize: settings.autoSummarize)
        reprocess(meeting, transcribe: work.transcribe, summarize: work.summarize)
    }

    /// Meetings parked because a model was missing re-enter the queue; jobs
    /// whose models are still missing simply park again — nothing downloads
    /// from this path.
    func processMeetingsWaitingForModels() {
        pipeline.retryJobsWaitingForModels()
    }

    func saveTranscript(_ transcript: Transcript, for meeting: Meeting) throws {
        try pipeline.saveTranscript(transcript, for: meeting)
        reindexSearchInBackground(meeting)
        if settings.semanticSearchEnabled {
            reindexEmbeddingInBackground(meeting)
        }
        objectWillChange.send()
    }

    func speakerNameHints(for meeting: Meeting) -> [String] {
        let fallbackDuration = max(meeting.recordedDuration ?? 60, 60)
        let fallbackEnd = meeting.startedAt.addingTimeInterval(fallbackDuration)
        var end = meeting.endedAt.map { max($0, meeting.startedAt) } ?? fallbackEnd
        if end <= meeting.startedAt { end = fallbackEnd }
        let ocr = activityStore.ocrText(from: meeting.startedAt, to: end, maxChars: 12_000)
        return SpeakerNameHintExtractor.hints(
            calendarNames: meeting.resolvedCalendarParticipantIdentities.compactMap(\.name),
            ocrText: ocr)
    }

    func applyTrackingSetting() {
        sampler.excludedApps = { [weak self] in self?.settings.excludedAppList ?? [] }
        if settings.trackingEnabled { sampler.start() } else { sampler.stop() }
        screenshots.restart()
    }

    func applyQuickRecallSetting() {
        let registered = quickRecallHotKey.setEnabled(settings.quickRecallEnabled)
        if settings.quickRecallEnabled, !registered {
            settings.quickRecallEnabled = false
            lastError = "The Ask shortcut could not register \(QuickRecallHotKeyController.shortcutLabel). Another app may already use it."
        }
    }

    func applyDailyMemoryExportSetting() {
        let snapshot = settings
        let destinationID = snapshot.dailyMemoryExportFolder.isEmpty
            ? ""
            : "\(snapshot.dailyMemoryExportFolder)|\(snapshot.dailyMemoryExportFormat.rawValue)"
        let configuration = DailyMemoryExportScheduler.Configuration(
            enabled: snapshot.dailyMemoryExportEnabled,
            hour: snapshot.dailyMemoryExportHour,
            destinationID: destinationID)
        let storageRoot = storage.rootURL
        let destinationPath = snapshot.dailyMemoryExportFolder
        let exportKind: DailyMemoryExportKind = switch snapshot.dailyMemoryExportFormat {
        case .markdown: .markdown
        case .obsidian: .obsidian
        case .logseq: .logseq
        }
        dailyMemoryExportScheduler.configure(configuration) { day in
            let destination = URL(
                fileURLWithPath: destinationPath,
                isDirectory: true)
            try Task.checkCancellation()
            let service = DailyMemoryExportService(
                source: FileDailyMemoryExportSource(root: storageRoot),
                calendar: .current)
            _ = try service.export(
                day: day,
                configuration: DailyMemoryExportConfiguration(
                    destinationDirectory: destination,
                    format: exportKind))
        } onError: { [weak self] message in
            self?.lastError = message
        }
    }

    func applyDayDigestSetting() {
        let snapshot = settings
        dayDigest.configureAutomaticGeneration(
            DayDigestScheduler.Configuration(
                enabled: snapshot.dayDigestAutoEnabled,
                hour: snapshot.dayDigestHour),
            canRun: { [weak self] in
                guard let self, self.libraryReady else { return false }
                // Scheduled background work never triggers a model download —
                // the digest waits until the Think model is actually on disk
                // (or a remote backend is configured).
                guard ModelReadinessSnapshot.thinkReady(self.settings, storage: self.storage)
                else { return false }
                return self.backgroundAutomationIsIdle
            },
            onError: { [weak self] message in
                self?.lastError = message
            })
    }

    func applyMemoryRoutineSetting() {
        let snapshot = settings
        memoryRoutines.configure(MemoryRoutineScheduler.Configuration(
            enabled: snapshot.memoryRoutinesEnabled,
            destinationPath: snapshot.memoryRoutineFolder,
            kinds: snapshot.enabledMemoryRoutines,
            hour: snapshot.memoryRoutineHour,
            weekday: snapshot.memoryRoutineWeekday
        )) { [weak self] message in
            self?.lastError = message
        }
    }

    func applyDreamingSetting() {
        let snapshot = settings

        // Persist the beginning of each opt-in period. This keeps catch-up
        // bounded instead of interpreting a first launch as permission to
        // backfill every historical workday.
        if snapshot.dreamingEnabled,
           snapshot.dreamingFirstEligibleDayKey?.isEmpty != false {
            let calendar = Calendar.current
            var updated = snapshot
            updated.dreamingFirstEligibleDayKey = DreamDay.key(
                for: DreamScheduler.previousDay(of: Date(), calendar: calendar),
                calendar: calendar)
            settings = updated
            return
        }

        if !snapshot.dreamingEnabled,
           snapshot.dreamingFirstEligibleDayKey != nil {
            var updated = snapshot
            updated.dreamingFirstEligibleDayKey = nil
            settings = updated
            return
        }

        let storageRoot = storage.rootURL
        dreaming.configure(
            DreamScheduler.Configuration(
                enabled: snapshot.dreamingEnabled,
                hour: snapshot.dreamingHour,
                firstEligibleDayKey: snapshot.dreamingFirstEligibleDayKey ?? ""),
            hasReport: { dayKey in
                DreamStore(root: storageRoot).hasReport(forDayKey: dayKey)
            },
            canRun: { [weak self] in
                guard let self else { return false }
                guard self.libraryReady else { return false }
                // Overnight dreaming is background automation: never let it
                // trigger a model download on a fresh install.
                guard ModelReadinessSnapshot.thinkReady(self.settings, storage: self.storage)
                else { return false }
                guard self.backgroundAutomationIsIdle else { return false }
                guard DreamScheduler.powerAllowsDreaming(
                    isOnBattery: PowerSourceMonitor.currentlyOnBattery(),
                    isLowPower: ProcessInfo.processInfo.isLowPowerModeEnabled) else {
                    return false
                }
                let userIdleSeconds = CGEventSource.secondsSinceLastEventType(
                    .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
                return DreamScheduler.isSystemIdle(for: userIdleSeconds)
            },
            dream: { [weak self] target in
                guard let self else {
                    throw TextEngineError.unavailable("LokalBot is shutting down.")
                }
                let service = DreamService(
                    storageRoot: storageRoot,
                    makeEngine: { [weak self] in
                        guard let self else {
                            throw TextEngineError.unavailable("LokalBot is shutting down.")
                        }
                        let engineSettings = self.settings
                        let engine = try await self.thinkExecution.makeTextEngine(
                            engineSettings,
                            priority: .background,
                            purpose: "dreaming")
                        return (engine, DreamInferenceProvenance(settings: engineSettings))
                    })
                let report = try await service.dream(target: target)
                self.latestDreamReport = report
                self.refreshDreamMemory()
            },
            onError: { [weak self] message in
                self?.lastError = message
            })
    }

    func setDreamingEnabled(_ enabled: Bool) {
        guard settings.dreamingEnabled != enabled else { return }

        var updated = settings
        updated.dreamingEnabled = enabled
        if enabled {
            let calendar = Calendar.current
            updated.dreamingFirstEligibleDayKey = DreamDay.key(
                for: DreamScheduler.previousDay(of: Date(), calendar: calendar),
                calendar: calendar)
        } else {
            updated.dreamingFirstEligibleDayKey = nil
        }
        settings = updated
    }

    func dreamNow() {
        guard libraryReady else {
            lastError = "Preparing your meeting library; dreaming will be available when it is ready."
            return
        }
        dreaming.dreamNow()
    }

    func refreshDreamMemory() {
        do {
            updateDreamMemory(try dreamStore.loadMemory())
        } catch {
            updateDreamMemory(nil)
            lastError = "Could not load dream memory: \(error.localizedDescription)"
        }
    }

    func setDreamMemoryPinned(_ pinned: Bool, for entry: DreamMemoryEntry) {
        guard !dreaming.isDreaming else {
            lastError = "Wait for the current dream to finish before changing pins."
            return
        }
        do {
            guard let updated = try dreamStore.setPinned(pinned, for: entry) else {
                refreshDreamMemory()
                lastError = "That dream memory item is no longer available."
                return
            }
            updateDreamMemory(updated)
        } catch {
            lastError = "Could not update dream memory: \(error.localizedDescription)"
        }
    }

    func restartMemoryCapture() {
        sampler.stop()
        screenshots.stop()
        applyTrackingSetting()
        PermissionManager.shared.refresh()
    }

    /// Search hit → open the meeting; transcript hits seek the player.
    func openSearchHit(_ hit: SearchIndex.Hit) {
        openMeeting(
            hit.meetingID,
            seek: hit.kind == .segment ? hit.start : nil)
    }

    /// Screen search/citation hit → open Timeline at the exact captured frame.
    func openScreenSnapshot(_ snapshotID: Int64) {
        navigationHandoff.stageScreenSnapshot(snapshotID)
        selectedMeetingIDs = []
        navSection = .timeline
    }

    /// Chat citation marker → open the cited meeting; timed markers seek the player.
    func openCitation(_ citation: ChatCitation) {
        guard let meeting = try? SessionLookup.find(id: citation.meetingID, in: meetings) else { return }
        openMeeting(meeting.id, seek: citation.seconds)
    }

    /// Permanently removes meetings: audio folder, list entry, both indexes.
    func deleteMeetings(_ ids: Set<Meeting.ID>) {
        var deletedIDs: Set<Meeting.ID> = []
        for meeting in meetings where ids.contains(meeting.id) {
            do {
                try storage.deleteMeeting(meeting)
                embeddingIndexTasks.removeValue(forKey: meeting.id)?.task.cancel()
                deletedMeetingIDs.insert(meeting.id)
                cachedSearchIndex?.noteDeletion(meeting.id)
                cachedEmbeddingIndex?.noteDeletion(meeting.id)
                scheduleIndexCleanup(meeting.id)
                deletedIDs.insert(meeting.id)
            } catch {
                lastError = "Could not delete \(meeting.title): \(error.localizedDescription)"
            }
        }
        removeMeetingsFromLibrary(deletedIDs)
        selectedMeetingIDs.subtract(deletedIDs)
        pipeline.forget(meetingIDs: deletedIDs)
        outcomeIndex.refresh(meetings: meetings)
    }
}
