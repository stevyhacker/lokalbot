import SwiftUI

private struct MeetingProcessingToolbarModifier: ViewModifier {
    @ObservedObject var app: AppState
    let meeting: Meeting

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    app.reprocess(meeting, transcribe: true, summarize: true)
                } label: {
                    Label("Transcribe & Summarize", systemImage: "wand.and.stars")
                        .labelStyle(.titleAndIcon)
                }
                .help("Transcribe & summarize")
                .accessibilityIdentifier("toolbar.transcribeAndSummarize")

                Button {
                    app.reprocess(meeting, transcribe: true, summarize: false)
                } label: {
                    Label("Transcribe", systemImage: "waveform")
                        .labelStyle(.titleAndIcon)
                }
                .help("Transcribe only")
                .accessibilityIdentifier("toolbar.transcribeOnly")

                Button {
                    app.reprocess(meeting, transcribe: false, summarize: true)
                } label: {
                    Label("Re-summarize", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .help("Re-summarize and keep the current transcript")
                .accessibilityIdentifier("toolbar.resummarize")
            }
        }
    }
}

extension View {
    func meetingProcessingToolbar(app: AppState, meeting: Meeting) -> some View {
        modifier(MeetingProcessingToolbarModifier(app: app, meeting: meeting))
    }
}
