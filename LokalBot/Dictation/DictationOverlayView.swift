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
        let size = Self.size(for: dictation.state)
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

    private static func size(for state: DictationCoordinator.State) -> CGSize {
        switch state {
        case .idle: CGSize(width: 172, height: 40)
        case .recording: CGSize(width: 172, height: 40)
        case .transcribing: CGSize(width: 216, height: 40)
        }
    }
}

struct DictationOverlayView: View {
    @ObservedObject var dictation: DictationCoordinator

    var body: some View {
        HStack(spacing: 0) {
            switch dictation.state {
            case .idle:
                EmptyView()
            case .recording:
                recordingRow
            case .transcribing:
                workingRow
            }
        }
        .frame(width: width, height: 40)
        .background(.background.opacity(0.98), in: RoundedRectangle(cornerRadius: radius))
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .animation(.snappy(duration: 0.28), value: dictation.state)
    }

    private var recordingRow: some View {
        HStack(spacing: 0) {
            PulsingDictationDot()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 15)
            DictationWaveform()
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
            Text("Transcribing")
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
        switch dictation.state {
        case .idle, .recording: 172
        case .transcribing: 216
        }
    }

    private var radius: CGFloat {
        switch dictation.state {
        case .idle, .recording: 20
        case .transcribing: 18
        }
    }
}

private struct PulsingDictationDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 7, height: 7)
            .overlay {
                Circle()
                    .stroke(Color.accentColor.opacity(0.30), lineWidth: 2)
                    .scaleEffect(pulse ? 2.2 : 1)
                    .opacity(pulse ? 0 : 0.8)
            }
            .onAppear { pulse = true }
            .animation(.easeOut(duration: 1.9).repeatForever(autoreverses: false), value: pulse)
    }
}

private struct DictationWaveform: View {
    private let barCount = 9

    var body: some View {
        SwiftUI.TimelineView(.animation) { timeline in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(width: 4, height: height(for: index, at: timeline.date))
                }
            }
            .frame(height: 18)
            .padding(.trailing, 8)
        }
    }

    private func height(for index: Int, at date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate * 5.2
        let wave = (sin(t + Double(index) * 0.72) + 1) / 2
        return max(3, min(18, 3 + CGFloat(pow(wave, 0.7)) * 15))
    }
}
