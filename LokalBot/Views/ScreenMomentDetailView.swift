import SwiftUI

/// Timeline's detail inspector for one exact captured moment.
struct ScreenMomentDetailView: View {
    @EnvironmentObject private var app: AppState

    let screenshot: ActivityStore.Screenshot
    let onReload: () -> Void
    let onClear: () -> Void

    @State private var note = ""
    @State private var confirmingDeletion = false

    private var capturedText: String {
        app.activityStore.ocrText(snapshotID: screenshot.id) ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if screenshot.hasPixels {
                    ScreenThumbnailView(
                        screenshot: screenshot,
                        height: 320,
                        contentMode: .fit,
                        cornerRadius: Brand.Radius.panel)
                        .background(.black.opacity(0.82),
                                    in: RoundedRectangle(cornerRadius: Brand.Radius.panel))
                } else {
                    Label("This moment retained text context without screen pixels.",
                          systemImage: "text.viewfinder")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.3),
                                    in: RoundedRectangle(cornerRadius: Brand.Radius.panel))
                }
                metadata
                if !capturedText.isEmpty { capturedTextSection }
                actions
                if screenshot.isBookmarked {
                    savedNote
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear(perform: loadNote)
        .confirmationDialog("Delete this context moment?", isPresented: $confirmingDeletion) {
            Button("Delete context moment", role: .destructive, action: deleteCapture)
        } message: {
            Text("This permanently removes its pixels, captured text, and metadata.")
        }
        .accessibilityIdentifier("timeline.screenDetail.\(screenshot.id)")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            IconTile(systemImage: screenshot.hasPixels ? "camera.viewfinder" : "text.viewfinder",
                     tint: Brand.teal, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(screenshot.app).font(.title3.bold())
                Text(screenshot.ts.formatted(date: .abbreviated, time: .standard))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close screen detail")
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !screenshot.windowTitle.isEmpty {
                LabeledContent("Window") {
                    Text(screenshot.windowTitle)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
            LabeledContent("Captured") {
                Text(screenshot.trigger.replacingOccurrences(of: "_", with: " ").capitalized)
            }
            LabeledContent("Context") {
                Text(screenshot.hasPixels ? "Accessible text + pixels" : "Accessible text only")
            }
            if !screenshot.documentName.isEmpty {
                LabeledContent("Document") {
                    Text(screenshot.documentName)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
            if !screenshot.sourceURL.isEmpty {
                LabeledContent("Source") {
                    Text(screenshot.sourceURL)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
            if !screenshot.meetingID.isEmpty {
                LabeledContent("Meeting") {
                    Text("Linked recording")
                }
            }
            if screenshot.privacyRedactionCount > 0 {
                LabeledContent("Privacy") {
                    Text("\(screenshot.privacyRedactionCount) secret\(screenshot.privacyRedactionCount == 1 ? "" : "s") redacted")
                }
            }
            if let groupID = screenshot.similarityGroupID {
                LabeledContent("Scene") {
                    Text("\(groupID)").monospacedDigit()
                }
            }
        }
        .font(.callout)
        .padding(10)
        .background(.quaternary.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: Brand.Radius.control))
    }

    private var capturedTextSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Captured text", systemImage: "text.quote")
                .font(.headline)
            Text(capturedText)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(12)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: Brand.Radius.control))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                toggleSaved()
            } label: {
                Label(screenshot.isBookmarked ? "Saved" : "Save moment",
                      systemImage: screenshot.isBookmarked ? "bookmark.fill" : "bookmark")
            }
            .tint(screenshot.isBookmarked ? Brand.amber : nil)
            Button {
                app.openAsk(
                    query: "What was I looking at here?",
                    screenSnapshotIDs: [screenshot.id])
            } label: {
                Label("Ask about this", systemImage: "sparkles")
            }
            Spacer()
            Button(role: .destructive) {
                confirmingDeletion = true
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete context moment")
        }
    }

    private var savedNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Saved moment note").font(.headline)
            TextField("Why does this moment matter?", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
            HStack {
                Spacer()
                Button("Save note") { saveNote() }
                    .disabled(note == savedNoteValue)
            }
        }
    }

    private var savedNoteValue: String {
        app.activityStore.savedMoments().first { $0.snapshotID == screenshot.id }?.note ?? ""
    }

    private func loadNote() {
        note = savedNoteValue
    }

    private func toggleSaved() {
        do {
            if screenshot.isBookmarked {
                try app.activityStore.removeSavedMoment(snapshotID: screenshot.id)
            } else {
                try app.activityStore.saveMoment(snapshotID: screenshot.id, note: note)
            }
            onReload()
        } catch {
            app.lastError = "Could not update saved moment: \(error.localizedDescription)"
        }
    }

    private func saveNote() {
        do {
            try app.activityStore.saveMoment(snapshotID: screenshot.id, note: note)
            onReload()
        } catch {
            app.lastError = "Could not save moment note: \(error.localizedDescription)"
        }
    }

    private func deleteCapture() {
        do {
            try app.screenshots.deleteCapture(id: screenshot.id)
            onClear()
            onReload()
        } catch {
            app.lastError = "Could not delete captured screen: \(error.localizedDescription)"
        }
    }
}
