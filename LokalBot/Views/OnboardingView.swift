import SwiftUI
import AVFoundation
import CoreGraphics

/// Permission onboarding (design §6: "requested progressively, with
/// explanations"). Live status per permission, one Grant button each,
/// and a relaunch button because Accessibility only applies at launch.
struct OnboardingView: View {
    @EnvironmentObject var app: AppState
    @State private var mic = Permission.microphone.granted
    @State private var screen = Permission.screenRecording.granted
    @State private var accessibility = Permission.accessibility.granted

    private let ticker = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    enum Permission {
        case microphone, screenRecording, accessibility

        var granted: Bool {
            switch self {
            case .microphone:
                AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            case .screenRecording:
                CGPreflightScreenCaptureAccess()
            case .accessibility:
                ActivitySampler.hasAccessibility
            }
        }

        func request() {
            switch self {
            case .microphone:
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            case .screenRecording:
                if !CGRequestScreenCaptureAccess() { Self.openSettings("Privacy_ScreenCapture") }
            case .accessibility:
                ActivitySampler.requestAccessibility()
                Self.openSettings("Privacy_Accessibility")
            }
        }

        static func openSettings(_ pane: String) {
            NSWorkspace.shared.open(URL(
                string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
        }
    }

    static var allGranted: Bool {
        Permission.microphone.granted && Permission.screenRecording.granted
            && Permission.accessibility.granted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 30)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Botina").font(.title2.bold())
                    Text("Three macOS permissions make everything work. All data stays on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            row(granted: mic,
                icon: "mic.fill", title: "Microphone",
                why: "Records your side of meetings. Without it, nothing records.",
                permission: .microphone)
            row(granted: screen,
                icon: "rectangle.inset.filled.badge.record", title: "Screen & System Audio Recording",
                why: "Captures the other participants' audio from the meeting app, and the periodic screenshots for day tracking.",
                permission: .screenRecording)
            row(granted: accessibility,
                icon: "macwindow", title: "Accessibility",
                why: "Reads window titles — distinguishes \"GitHub PR #412\" from \"YouTube\", and detects Google Meet in your browser.",
                permission: .accessibility)

            // System Settings sometimes wants the app added manually (+ or
            // drag-and-drop). Make "which app?" unambiguous: drag this icon
            // straight into the list, or reveal the bundle in Finder.
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable().frame(width: 44, height: 44)
                    .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Adding Botina manually in System Settings?")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("Drag this icon straight into the permission list — it's always the right copy. Remove any older “Botina” entries first.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
            }
            .padding(10)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))

            Divider()
            HStack {
                Label("If a permission was granted while Botina was running, relaunch to apply it.",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Relaunch Botina") { Self.relaunch() }
                if Self.allGranted {
                    Text("All set ✓").font(.callout.bold()).foregroundStyle(.green)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .onReceive(ticker) { _ in refresh() }
        .onAppear { refresh() }
    }

    private func row(granted: Bool, icon: String, title: String,
                     why: String, permission: Permission) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19)).frame(width: 30)
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(why).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Button("Grant…") { permission.request() }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
    }

    private func refresh() {
        mic = Permission.microphone.granted
        screen = Permission.screenRecording.granted
        accessibility = Permission.accessibility.granted
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        // Tiny delay so the new instance starts after this one exits.
        task.environment = ProcessInfo.processInfo.environment
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
    }
}
