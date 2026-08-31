import SwiftUI

/// The detail pane for the meeting being recorded right now, shown when the
/// in-progress row is selected (and as the Meetings empty state while
/// recording). The rolling
/// transcript preview (chunked, undiarized — the full pipeline transcript
/// replaces it after the meeting) sits beside a full-height quick-notes pad;
/// notes are saved to `notes.md` in the meeting folder and folded into the
/// summary.
///
/// Appearing is the ASR opt-in: `transcriber.activate()` runs on first show,
/// so recordings nobody watches still cost zero live-transcription cycles
/// (the same economy the old popover had).
struct LiveMeetingDetailView: View {
    @EnvironmentObject var app: AppState
    let meeting: Meeting

    @State private var notes = ""
    @State private var savedNotes = ""
    @State private var notesLoaded = false
    @State private var isLoadingNotes = false
    @State private var isSavingNotes = false
    @State private var notesPersistenceError: String?
    @State private var saveTask: Task<Void, Never>?

    private var transcriber: LiveMeetingTranscriber { app.liveTranscriber }
    private var folder: URL { meeting.folderURL(in: app.storage) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            HSplitView {
                transcriptColumn
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                notesColumn
                    .frame(minWidth: 240, idealWidth: 300, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(WorkspaceMetric.sectionGap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            transcriber.activate()   // opting in starts the ASR passes
            Task { await loadNotes() }
        }
        .onDisappear {
            saveTask?.cancel()
            scheduleSave(immediately: true)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(meeting.title).font(.title2.bold())
                    .accessibilityIdentifier("live.title")
                Spacer()
                Button {
                    app.stopRecording()
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                }
                .tint(.red)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("live.stop")
            }
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    StatusDot(color: Brand.recording, size: 7, pulses: true)
                    Text("recording").font(.caption)
                    LiveWaveform(barCount: 5, barWidth: 2.5, maxHeight: 10)
                    MeetingRecordingTimerText(recording: app.recording)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .hudCapsule(shadowed: false)
                BrandChip(icon: "calendar",
                          text: meeting.startedAt.formatted(date: .omitted, time: .shortened))
                BrandChip(icon: "video", text: meeting.appName)
                BrandChip(icon: meeting.hasSystemTrack ? "speaker.wave.2.fill" : "mic.fill",
                          text: meeting.hasSystemTrack ? "Mic + system" : "Mic only")
            }
        }
    }

    // MARK: - Transcript

    private var transcriptColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Live transcript")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
            Text("Preview — the full transcript and summary arrive after the meeting.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.trailing, 12)
    }

    private var transcript: some View {
        Group {
            if transcriber.lines.isEmpty {
                Group {
                    if transcriber.isWorking || transcriber.statusMessage == nil {
                        LoadingStateLabel(
                            transcriber.statusMessage ?? "Listening…",
                            font: .callout)
                    } else {
                        Text(transcriber.statusMessage ?? "Listening…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(transcriber.lines) { line in
                                lineView(line).id(line.id)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: transcriber.lines.count) {
                        if let last = transcriber.lines.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                    .onAppear {
                        if let last = transcriber.lines.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private func lineView(_ line: LiveMeetingTranscriber.Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.timestamp(line.time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(line.speaker == "me" ? "Me" : "Them")
                .font(.caption.weight(.semibold))
                .foregroundStyle(line.speaker == "me" ? Brand.me : Brand.them)
            Text(line.text)
                .font(.callout)
                .textSelection(.enabled)
        }
    }

    // MARK: - Notes

    private var notesColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $notes)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityIdentifier("live.notes")
                .disabled(!notesLoaded)
                .onChange(of: notes) { scheduleSave() }
            notesStatus
        }
        .padding(.leading, 12)
    }

    @ViewBuilder
    private var notesStatus: some View {
        if let notesPersistenceError {
            InlineIssueView(
                notesPersistenceError,
                actionTitle: "Retry",
                font: .caption2
            ) {
                if notesLoaded {
                    scheduleSave(immediately: true)
                } else {
                    Task { await loadNotes() }
                }
            }
        } else if isLoadingNotes {
            LoadingStateLabel("Loading notes…", font: .caption2, controlSize: .mini)
        } else if isSavingNotes || notes != savedNotes {
            Text("Saving notes…")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Text("Saved with the meeting and folded into the summary.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private static func timestamp(_ time: TimeInterval) -> String {
        let total = max(0, Int(time))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Notes persistence

    private func loadNotes() async {
        guard !notesLoaded, !isLoadingNotes else { return }
        isLoadingNotes = true
        let notesFolder = folder
        do {
            let loaded = try await Task.detached(priority: .utility) {
                try MeetingNotes.load(from: notesFolder) ?? ""
            }.value
            savedNotes = loaded
            notes = loaded
            notesLoaded = true
            notesPersistenceError = nil
        } catch {
            notesLoaded = false
            notesPersistenceError = "Could not load notes."
            app.lastError = "Could not load meeting notes: \(error.localizedDescription)"
        }
        isLoadingNotes = false
    }

    private func scheduleSave(immediately: Bool = false) {
        guard notesLoaded, notes != savedNotes else { return }
        if isSavingNotes { return }
        saveTask?.cancel()
        let snapshot = notes
        let notesFolder = folder
        saveTask = Task {
            do {
                if !immediately {
                    try await Task.sleep(for: .milliseconds(600))
                }
                try Task.checkCancellation()
                isSavingNotes = true
                try await Task.detached(priority: .utility) {
                    try MeetingNotes.write(snapshot, to: notesFolder)
                }.value
                savedNotes = snapshot
                notesPersistenceError = nil
            } catch is CancellationError {
                return
            } catch {
                notesPersistenceError = "Notes were not saved."
                app.lastError = "Could not save meeting notes: \(error.localizedDescription)"
            }
            isSavingNotes = false
            if notes != savedNotes {
                scheduleSave()
            }
        }
    }
}
