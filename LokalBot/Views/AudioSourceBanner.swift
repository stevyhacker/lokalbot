import SwiftUI

/// The "We noticed <app> just started playing audio — record it?" affordance
/// driven by `AudioSourceMonitor`. Surfaces meetings the mic-in-use signal
/// missed (muted call, browser tab playing audio) and audio sources outside
/// the curated meeting-bundle list (so the user can opt in explicitly).
struct AudioSourceBanner: View {
    let process: AudioProcess
    let onRecord: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let icon = process.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.tint)
                    .frame(width: 24, height: 24)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(process.name) is producing audio").font(.callout).bold()
                    .lineLimit(1)
                Text("Record this session?")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Record", action: onRecord).buttonStyle(.borderedProminent)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Don't ask for this app this session.")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .hudCapsule()
        .frame(maxWidth: 480)
    }
}
