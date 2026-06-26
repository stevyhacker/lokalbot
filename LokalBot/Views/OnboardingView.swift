import SwiftUI
import AppKit

/// First-run onboarding. Redesigned value-first: a short walk through what
/// LokalBot *does* (record → transcribe → summarize, all on-device) before the
/// permission asks, so the user grants with intent. The final step is the
/// permission panel (TCC state, prompting, deep-links, polling, relaunch all
/// live in the shared `PermissionManager`; this view is presentation only).
///
/// Two modes: `.welcome` (the dedicated first-run window — the value walk then
/// permissions) and `.permissions` (the Settings re-entry surface, which only
/// ever repairs permissions). The latter is what the main window's Settings
/// detail shows.
struct OnboardingView: View {
    enum Mode { case welcome, permissions }
    var mode: Mode = .welcome

    @EnvironmentObject var app: AppState
    @StateObject private var permissions = PermissionManager.shared
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                if mode == .permissions || step >= steps.count {
                    permissionsStep
                } else {
                    steps[step]
                }
            }
            .padding(24)
            .frame(width: 560)

            if mode == .welcome, step < steps.count {
                footerNav
            }
        }
        .onAppear {
            // The Settings surface is always the permission panel; only the
            // first-run window does the value walk (starting at welcome).
            if mode == .permissions { step = steps.count }
            permissions.startPolling()
        }
        .onDisappear { permissions.stopPolling() }
        .animation(.easeInOut(duration: 0.2), value: step)
    }

    // MARK: - Value steps (0…2)

    /// The pre-permission steps: what LokalBot does, how a meeting flows, and
    /// the privacy stance. Each is a self-contained view; the index drives nav.
    private var steps: [AnyView] {
        [
            AnyView(welcomeStep),
            AnyView(flowStep),
            AnyView(privacyStep)
        ]
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            heroMark
            Text("LokalBot is your meeting brain.").font(.title.bold())
            Text("It records both sides of every call, turns them into a transcript, and writes the recap — decisions, action items, and all. Then it lets you search every word, and ask questions in plain language.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                pillar("waveform", "Record", "Both sides, auto-detected")
                pillar("doc.text.magnifyingglass", "Recap", "Transcript + summary")
                pillar("bubble.left.and.bubble.right", "Ask", "Chat over your library")
            }
        }
    }

    private var flowStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How a meeting flows").font(.title2.bold())
            VStack(alignment: .leading, spacing: 12) {
                flowRow(number: "1", icon: "magnifyingglass", title: "It notices the call",
                        body: "LokalBot watches for Zoom, Teams, Meet, and more — and starts recording both sides on its own.")
                flowRow(number: "2", icon: "waveform.badge.checkmark", title: "It transcribes & summarizes",
                        body: "On-device models turn the audio into a labeled transcript and a structured recap the moment the call ends.")
                flowRow(number: "3", icon: "lock.shield", title: "It stays on your Mac",
                        body: "Everything lands in a local library you can search, replay, and ask questions about. Nothing is uploaded.")
            }
        }
    }

    private var privacyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Private by construction").font(.title2.bold())
            Label {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your audio, transcripts, and summaries never leave this Mac.")
                        .font(.callout).foregroundStyle(.primary)
                    Text("Transcription and summarization run on-device with Apple Silicon. The only network calls are optional: a one-time model download, or pointing summaries at a backend you choose.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 30)).foregroundStyle(Brand.teal.gradient)
            }
            Divider()
            Label("No account. No subscription. No telemetry.", systemImage: "checkmark.seal")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func flowRow(number: String, icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(Brand.teal.gradient).frame(width: 30, height: 30)
                Text(number).font(.callout.bold()).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: icon).font(.headline)
                Text(body).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pillar(_ icon: String, _ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint)
            Text(title).font(.headline)
            Text(body).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    private var heroMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(Brand.gradient)
                .frame(width: 56, height: 56)
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 26)).foregroundStyle(.white)
        }
    }

    // MARK: - Step 3: Permissions (the original, focused panel)

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 30)).foregroundStyle(Brand.teal.gradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Grant three permissions").font(.title2.bold())
                    Text("They make everything work. All data stays on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            row(.microphone,
                icon: "mic.fill", title: "Microphone",
                why: "Records your side of meetings. Without it, nothing records.")
            row(.screenRecording,
                icon: "rectangle.inset.filled.badge.record", title: "Screen & System Audio Recording",
                why: "Captures the other participants' audio from the meeting app, and the periodic screenshots for day tracking.")
            row(.accessibility,
                icon: "macwindow", title: "Accessibility",
                why: "Reads window titles — distinguishes \"GitHub PR #412\" from \"YouTube\", and detects Google Meet in your browser.")

            // System Settings sometimes wants the app added manually (+ or
            // drag-and-drop). Make "which app?" unambiguous: drag this icon
            // straight into the list, or reveal the bundle in Finder.
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable().frame(width: 44, height: 44)
                    .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Adding LokalBot manually in System Settings?")
                        .font(.headline)
                    Text("Drag this icon straight into the permission list — it's always the right copy. Remove any older “LokalBot” entries first.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
            }
            .padding(10)
            .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))

            Divider()
            HStack {
                Label("If a permission was granted while LokalBot was running, relaunch to apply it.",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Relaunch LokalBot") { PermissionManager.relaunch() }
                if permissions.allGranted {
                    Text("All set ✓").font(.callout.bold()).foregroundStyle(.green)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func row(_ permission: AppPermission, icon: String, title: String, why: String) -> some View {
        let granted = permissions.granted[permission] ?? permission.isGranted
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19)).frame(width: 30)
                .foregroundStyle(granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(why).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                // Prompt, then open the right pane so a previously-denied
                // permission (where the prompt is a silent no-op) is still fixable.
                Button("Grant…") {
                    permissions.request(permission)
                    permissions.openSettings(for: permission)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: - Nav

    private var footerNav: some View {
        HStack {
            stepDots
            Spacer()
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            Button(step == steps.count - 1 ? "Continue to permissions" : "Next") {
                step += 1
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 24).padding(.bottom, 20)
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<steps.count, id: \.self) { index in
                Circle()
                    .fill(index == step ? Brand.teal : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }
}
