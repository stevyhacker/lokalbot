import SwiftUI

/// One permission line in a grouped Form: state icon, title, rationale, and a
/// Grant button when missing. Shared by Settings, Dictation, and Cotyping so
/// permission state reads the same everywhere. Callers are responsible for
/// `PermissionManager.shared.startPolling()` while the row is visible.
struct PermissionRow: View {
    let permission: AppPermission
    var why: String?
    @ObservedObject private var permissions = PermissionManager.shared
    @State private var actionButtonFrame = CGRect.zero

    var body: some View {
        let granted = permissions.granted[permission] ?? permission.isGranted
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(why ?? permission.why).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant Access") {
                    PermissionGuidanceController.shared.requestAccess(
                        for: permission,
                        sourceFrameInScreen: actionButtonFrame)
                }
                .background(PermissionScreenFrameReader(frameInScreen: $actionButtonFrame))
                .help(permission.guidanceHint)
            }
        }
    }
}
