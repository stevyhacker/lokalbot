import SwiftUI

/// Timeline's detail inspector for one exact captured moment.
struct ScreenMomentDetailView: View {
    @EnvironmentObject private var app: AppState

    let screenshot: ActivityStore.Screenshot
    let onReload: () -> Void
    let onClear: () -> Void

    @State private var note = ""
    @State private var confirmingDeletion = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                ScreenThumbnailView(
                    snapshotID: screenshot.id,
                    height: 320,
                    contentMode: .fit,
                    cornerRadius: Brand.Radius.panel)
                    .background(.black.opacity(0.82),
                                in: RoundedRectangle(cornerRadius: Brand.Radius.panel))
                metadata
                actions
                if screenshot.isBookmarked {
                    savedNote
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear(perform: loadNote)
        .confirmationDialog("Delete this captured screen?", isPresented: $confirmingDeletion) {
            Button("Delete captured screen", role: .destructive, action: deleteCapture)
        } message: {
            Text("This permanently removes the encrypted screenshot and its searchable screen text.")
        }
        .accessibilityIdentifier("timeline.screenDetail.\(screenshot.id)")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            IconTile(systemImage: "camera.viewfinder", tint: Brand.teal, size: 34)
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
            .help("Delete captured screen")
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
