import SwiftUI

/// A ⌘K command palette for keyboard-first navigation. Fires record/stop,
/// jumps to any sidebar section, opens recent meetings, and toggles cotyping —
/// all from a single fuzzy-filtered list. Built for the power-user audience
/// (menu-bar residents, agent-CLI users) who reach for the keyboard, not the
/// trackpad. Summoned via ⌘K (registered in `LokalBotApp.commands`).
struct CommandPaletteView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundStyle(.tint).font(.title3)
                TextField("Type a command or search meetings…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { runSelection() }
                    .accessibilityIdentifier("palette.input")
                Text("⌘K").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Divider()

            if results.isEmpty {
                Text("No matches")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            PaletteRow(item: item, selected: index == selection)
                                .contentShape(Rectangle())
                                .onTapGesture { run(item) }
                                .accessibilityIdentifier("palette.row.\(item.id)")
                        }
                    }
                    .padding(6)
                }
            }
        }
        .frame(width: 560, height: 420)
        .background(.regularMaterial)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { selection = 0 }
        .onKeyPress(.upArrow) { move(by: -1); return .handled }
        .onKeyPress(.downArrow) { move(by: 1); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    // MARK: - Items

    /// Everything the palette can do, computed live from app state. Commands,
    /// plus recent meetings when idle; typed queries add one handoff row into
    /// Ask — the palette stays a command surface, Ask is the search surface.
    private var results: [PaletteItem] {
        let actions: [PaletteItem] = [
            .init(id: "record", icon: app.isRecording ? "stop.circle.fill" : "record.circle",
                  title: app.isRecording ? "Stop recording" : "Record now",
                  subtitle: "Recording", action: {
                app.isRecording ? app.stopRecording()
                                : app.startRecording(context: app.recordingContext(for: app.detector.activeApp), source: "palette")
            }),
            .init(id: "nav.capture", icon: "waveform.circle", title: "Go to Capture",
                  subtitle: "Library", action: { app.navSection = .capture }),
            .init(id: "nav.ask", icon: "sparkle.magnifyingglass", title: "Go to Ask",
                  subtitle: "Library", action: { app.openAsk() }),
            .init(id: "nav.capture.day", icon: "calendar.day.timeline.left", title: "Go to Day timeline",
                  subtitle: "Library", action: {
                app.captureScope = .day
                app.navSection = .capture
            }),
            .init(id: "dictation", icon: app.dictation.state.isRecording ? "stop.circle.fill" : "mic.badge.plus",
                  title: app.dictation.state.isRecording ? "Stop dictation" : "Start dictation",
                  subtitle: "Automation", action: { app.dictation.toggle(source: "palette") }),
            .init(id: "nav.dictation", icon: "mic.badge.plus",
                  title: app.settings.dictationEnabled ? "Go to Dictation (on)" : "Go to Dictation (off)",
                  subtitle: "Type", action: { app.openType(.dictation) }),
            .init(id: "nav.cotyping", icon: "text.cursor",
                  title: app.settings.cotypingEnabled ? "Go to Cotyping (on)" : "Go to Cotyping (off)",
                  subtitle: "Type", action: { app.openType(.cotyping) }),
            .init(id: "nav.models", icon: "brain", title: "Go to Models",
                  subtitle: "Configure", action: { app.openSettings(tab: .models) }),
            .init(id: "nav.settings", icon: "gearshape", title: "Go to Settings",
                  subtitle: "Configure", action: { app.navSection = .settings })
        ]
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        // Empty query: commands + recent meetings (quick navigation).
        guard !q.isEmpty else {
            let recents = app.meetings.prefix(8).map { meeting in
                PaletteItem(id: "meeting.\(meeting.id.uuidString)", icon: "waveform",
                            title: meeting.title,
                            subtitle: "Open · \(meeting.appName) · \(meeting.durationLabel)",
                            action: { app.openMeeting(meeting.id) })
            }
            return actions + recents
        }
        // Non-empty query: matching commands, then a single handoff into Ask
        // (spec §2.3: the palette's meeting-search rows hand off to Ask).
        let tokens = q.split(separator: " ").map(String.init)
        let matched = actions.filter { item in
            let hay = (item.title + " " + item.subtitle).lowercased()
            return tokens.allSatisfy { hay.contains($0) }
        }
        let raw = query.trimmingCharacters(in: .whitespaces)
        let handoff = PaletteItem(id: "ask.handoff", icon: "sparkle.magnifyingglass",
                                  title: "Search “\(raw)” in Ask",
                                  subtitle: "Ask",
                                  action: { app.openAsk(query: raw) })
        return matched + [handoff]
    }

    private func move(by delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    private func runSelection() {
        guard results.indices.contains(selection) else { return }
        run(results[selection])
    }

    private func run(_ item: PaletteItem) {
        item.action()
        dismiss()
    }
}

private struct PaletteItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void
}

private struct PaletteRow: View {
    let item: PaletteItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.title3).foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.callout).lineLimit(1)
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if selected {
                Image(systemName: "return")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(selected ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1))
    }
}
