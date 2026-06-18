import SwiftUI
import AppKit

/// Permission onboarding (design §6: "requested progressively, with
/// explanations"). All TCC state, prompting, deep-links, polling and relaunch
/// now live in the shared `PermissionManager`; this view is presentation only.
struct OnboardingView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var permissions = PermissionManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 30)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to BotinaV2").font(.title2.bold())
                    Text("Three macOS permissions make everything work. All data stays on this Mac.")
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
                    Text("Adding BotinaV2 manually in System Settings?")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("Drag this icon straight into the permission list — it's always the right copy. Remove any older “BotinaV2” entries first.")
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
                Label("If a permission was granted while BotinaV2 was running, relaunch to apply it.",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Relaunch BotinaV2") { PermissionManager.relaunch() }
                if permissions.allGranted {
                    Text("All set ✓").font(.callout.bold()).foregroundStyle(.green)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        // TCC posts no change notification, so poll while this panel is visible
        // to catch grants the user makes over in System Settings.
        .onAppear { permissions.startPolling() }
        .onDisappear { permissions.stopPolling() }
    }

    private func row(_ permission: AppPermission, icon: String, title: String, why: String) -> some View {
        let granted = permissions.granted[permission] ?? permission.isGranted
        return HStack(alignment: .top, spacing: 12) {
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
}
