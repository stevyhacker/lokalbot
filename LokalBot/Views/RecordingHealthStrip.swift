import SwiftUI

struct RecordingHealthStrip: View {
    @ObservedObject var recording: RecordingController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            let health = recording.memoryHealthSnapshot(at: context.date)
            VStack(alignment: .leading, spacing: 4) {
                Label("Microphone · \(health.microphoneStatus)", systemImage: "mic")
                Label("System audio · \(health.systemAudioStatus)", systemImage: "speaker.wave.2")
                if let recovery = health.lastRecoveryAt {
                    Text("Last recovery \(recovery.formatted(date: .omitted, time: .standard))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(WorkspaceTypography.metadata)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("recording.health")
        }
    }
}
