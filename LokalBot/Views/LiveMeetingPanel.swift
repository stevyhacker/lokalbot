import SwiftUI

/// Popover behind the recording capsule: the rolling live transcript on top,
/// a quick-notes pad below. The transcript is a preview (chunked, undiarized —
/// the full pipeline transcript replaces it after the meeting); the notes are
/// saved to `notes.md` in the meeting folder and folded into the summary.
struct LiveMeetingPanel: View {
    @ObservedObject var transcriber: LiveMeetingTranscriber
    let notesFolder: URL?

    @State private var notes = ""
    @State private var notesLoaded = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            transcript
            Divider()
            notesPad
        }
        .frame(width: 380, height: 460)
        .onAppear {
            transcriber.activate()   // opting in starts the ASR passes
            loadNotes()
        }
        .onDisappear {
            saveTask?.cancel()
            saveNotes()
        }
    }

    private var transcript: some View {
        Group {
            if transcriber.lines.isEmpty {
                VStack(spacing: 6) {
                    if transcriber.isWorking || transcriber.statusMessage == nil {
                        ProgressView().controlSize(.small)
                    }
                    Text(transcriber.statusMessage ?? "Listening…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(transcriber.lines) { line in
                                lineView(line).id(line.id)
                            }
                        }
                        .padding(10)
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

    private var notesPad: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextEditor(text: $notes)
                .font(.callout)
                .scrollContentBackground(.hidden)
                .accessibilityIdentifier("live.notes")
                .onChange(of: notes) { scheduleSave() }
            Text("Notes are saved with the meeting and folded into the summary.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(height: 150)
    }

    private static func timestamp(_ time: TimeInterval) -> String {
        let total = max(0, Int(time))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Notes persistence

    private func loadNotes() {
        guard !notesLoaded, let folder = notesFolder else { return }
        notesLoaded = true
        notes = MeetingNotes.load(from: folder) ?? ""
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            saveNotes()
        }
    }

    private func saveNotes() {
        guard notesLoaded, let folder = notesFolder else { return }
        MeetingNotes.write(notes, to: folder)
    }
}
