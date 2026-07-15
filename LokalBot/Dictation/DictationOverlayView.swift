import AppKit
import SwiftUI

@MainActor
final class DictationOverlayController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<DictationOverlayView>?

    func update(for dictation: DictationCoordinator, visible: Bool) {
        guard visible, dictation.state.isWorking else {
            close()
            return
        }
        let size = Self.size(for: dictation)
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false)
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

            let hosting = NSHostingView(rootView: DictationOverlayView(dictation: dictation))
            hosting.frame = NSRect(origin: .zero, size: size)
            panel.contentView = hosting
            self.panel = panel
            self.hostingView = hosting
        }
        hostingView?.rootView = DictationOverlayView(dictation: dictation)
        hostingView?.frame = NSRect(origin: .zero, size: size)
        positionPanel(size: size)
        panel?.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func positionPanel(size: CGSize) {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 48)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }

    private static func size(for dictation: DictationCoordinator) -> CGSize {
        if dictation.shouldShowLiveTranscriptPanel {
            return CGSize(width: 520, height: 156)
        }
        switch dictation.state {
        case .idle, .recording:
            return CGSize(width: 172, height: 40)
        case .transcribing, .composing:
            return CGSize(width: 216, height: 40)
        }
    }
}

struct DictationOverlayView: View {
    @ObservedObject var dictation: DictationCoordinator

    var body: some View {
        Group {
            if dictation.shouldShowLiveTranscriptPanel {
                liveTranscriptPanel
            } else {
                compactPanel
            }
        }
        .frame(width: width, height: height)
        .hudCapsule(radius: radius, shadowed: false)
        .animation(.snappy(duration: 0.28), value: dictation.state)
        .animation(.snappy(duration: 0.22), value: dictation.liveTranscript)
    }

    private var compactPanel: some View {
        HStack(spacing: 0) {
            switch dictation.state {
            case .idle:
                EmptyView()
            case .recording:
                recordingRow
            case .transcribing, .composing:
                workingRow
            }
        }
        .frame(height: 40)
    }

    private var liveTranscriptPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if dictation.state.isRecording {
                    PulsingDictationDot()
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(dictation.state.isRecording ? "Dictating" : dictation.state.label)
                        .font(.system(size: 12, weight: .semibold))
                    Text(liveStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                if dictation.state.isRecording {
                    LiveWaveform().padding(.trailing, 8)
                }
                cancelButton
            }
            .frame(height: 38)
            .padding(.horizontal, 14)

            Divider()
                .opacity(0.45)

            liveTranscriptBody
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var liveTranscriptBody: some View {
        if dictation.liveTranscript.isEmpty {
            Text("Listening…")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            liveTranscriptText
                .font(.system(size: 15))
                .lineSpacing(3)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var liveTranscriptText: Text {
        let committed = dictation.liveTranscript.committed
        let tentative = dictation.liveTranscript.tentative
        if committed.isEmpty {
            return Text(tentative)
                .foregroundColor(.primary)
        }
        if tentative.isEmpty {
            return Text(committed)
                .foregroundColor(.primary)
        }
        return Text(committed + " ")
            .foregroundColor(.primary)
        + Text(tentative)
            .foregroundColor(.secondary)
    }

    private var liveStatusText: String {
        let status = dictation.livePreviewStatus.isEmpty ? "Listening" : dictation.livePreviewStatus
        return "\(status) \(dictation.timerLabel)"
    }

    private var recordingRow: some View {
        HStack(spacing: 0) {
            PulsingDictationDot()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 15)
            LiveWaveform().padding(.trailing, 8)
            cancelButton
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 10)
        }
        .frame(height: 40)
    }

    private var workingRow: some View {
        HStack(spacing: 0) {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
            Text(dictation.state.label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
            cancelButton
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 10)
        }
        .frame(height: 40)
    }

    private var cancelButton: some View {
        Button {
            dictation.cancel()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Cancel dictation")
    }

    private var width: CGFloat {
        if dictation.shouldShowLiveTranscriptPanel { return 520 }
        switch dictation.state {
        case .idle, .recording:
            return 172
        case .transcribing, .composing:
            return 216
        }
    }

    private var height: CGFloat {
        dictation.shouldShowLiveTranscriptPanel ? 156 : 40
    }

    private var radius: CGFloat {
        if dictation.shouldShowLiveTranscriptPanel { return 14 }
        switch dictation.state {
        case .idle, .recording:
            return 20
        case .transcribing, .composing:
            return 18
        }
    }
}

private struct PulsingDictationDot: View {
    var body: some View {
        StatusDot(color: Brand.recording, size: 7, pulses: true)
    }
}
