import SwiftUI

struct AgentAccessToggleRow: View {
    @ObservedObject var manager: AgentAccessManager

    var body: some View {
        Group {
            Toggle(
                "Allow external agents to read your meeting library",
                isOn: Binding(
                    get: { manager.isEnabled },
                    set: { manager.setEnabled($0) }))
            Text("Lets MCP clients and the lokalbot-cli skill (Claude, Cursor, …) list, read, and search your meetings, and ask questions answered by your local model — read-only, localhost only. Off by default; while off, agent tools return an error explaining how to enable this.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct ScreenMemoryAccessToggleRow: View {
    @ObservedObject var manager: ScreenMemoryAccessManager

    var body: some View {
        Group {
            Toggle(
                "Allow external agents to read screen memory",
                isOn: Binding(
                    get: { manager.isEnabled },
                    set: { manager.setEnabled($0) }))
            if manager.isEnabled {
                Picker("Granted history", selection: Binding(
                    get: { manager.profile.scope },
                    set: { manager.setScope($0) })) {
                    ForEach(ScreenMemoryAccessProfile.Scope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                Text(manager.profile.scope.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Separately grants scoped, read-only MCP access to captured text and metadata. Decrypted screenshot pixels are never returned, out-of-scope ids appear missing, and meeting access remains independently controlled above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
