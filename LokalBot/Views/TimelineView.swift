import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// M4 timeline (design doc §4.2): one day at a time, presented in the same
/// native master/detail split as Meetings and Assistant. The day column
/// (`TimelineDayView`: pinned header + summary rail + hour-indexed activity
/// track) drives a tabbed inspector (`TimelineInspectorView`: per-app totals ·
/// screenshots · ask-your-day · LLM digest) in the detail pane. Selecting a
/// block in the track scopes the screenshot tab to that window. Both columns
/// share `TimelineModel`, mirroring the Chat section's model/view split.
@MainActor
final class TimelineModel: ObservableObject {
    @Published var day = Date()
    @Published var blocks: [ActivityBlock] = []
    @Published var shots: [ActivityStore.Screenshot] = []
    @Published var selection: ActivityBlock.ID?
    @Published var inspectorTab: InspectorTab = .totals
    @Published var digest: String?
    @Published var generating = false
    @Published var digestError: String?
    @Published var question = ""
    @Published var answer: String?
    @Published var asking = false

    enum InspectorTab: String, CaseIterable, Identifiable {
        case totals, screenshots, ask, digest
        var id: String { rawValue }
        var title: String {
            switch self {
            case .totals: "Totals"
            case .screenshots: "Screens"
            case .ask: "Ask"
            case .digest: "Digest"
            }
        }
    }

    var selectedBlock: ActivityBlock? {
        guard let selection else { return nil }
        return blocks.first { $0.id == selection }
    }

    func moveDay(by value: Int) {
        day = Calendar.current.date(byAdding: .day, value: value, to: day)
            ?? day.addingTimeInterval(TimeInterval(value) * 86_400)
    }

    func reload(app: AppState) {
        blocks = app.activityStore.blocks(on: day)
        shots = app.activityStore.screenshots(on: day)
        digest = try? String(contentsOf: journalURL(app: app), encoding: .utf8)
        digestError = nil
        selection = nil
    }

    private func journalURL(app: AppState) -> URL {
        let name = day.formatted(.iso8601.year().month().day())
        return app.storage.rootURL.appendingPathComponent("journal/\(name).md")
    }

    /// M6: ask anything about the day — blocks + OCR + meetings as context.
    func ask(app: AppState) async {
        asking = true
        defer { asking = false }
        let lines = blocks.map {
            "\($0.start.formatted(date: .omitted, time: .shortened))–\($0.end.formatted(date: .omitted, time: .shortened)) \($0.app)\($0.title.isEmpty ? "" : ": \($0.title)")"
        }
        let ocr = app.activityStore.ocrText(on: day)
        do {
            let engine = try await app.pipeline.makeTextEngine(app.settings)
            answer = try await engine.generate(
                system: PromptTemplates.timelineQuestionSystem,
                prompt: question,
                context: ["Activity log:\n" + lines.joined(separator: "\n"),
                          ocr.isEmpty ? "" : "Screen text excerpts:\n" + ocr])
        } catch {
            answer = "⚠️ \(error.localizedDescription)"
        }
    }

    func generateDigest(app: AppState) async {
        generating = true
        defer { generating = false }
        let todays = app.meetings.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }
        let ocr = app.activityStore.ocrText(on: day)
        do {
            let (text, _) = try await app.pipeline.generateDayDigest(
                for: day, blocks: blocks, meetings: todays, ocr: ocr, config: app.settings)
            digest = text
        } catch {
            digestError = error.localizedDescription
        }
    }

    /// Copy the raw digest Markdown to the clipboard. The rendered text is
    /// selectable too, but one click grabs the whole document without a
    /// fiddly multi-line drag across the per-line Markdown layout.
    func copyDigest(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Export the digest to a user-chosen `.md` file via the standard save
    /// panel. The digest is already auto-saved to `journal/<date>.md`; this
    /// drops a shareable copy wherever the user picks.
    func exportDigest(_ text: String) {
        let panel = NSSavePanel()
        panel.title = "Export Day Digest"
        panel.nameFieldStringValue = "\(day.formatted(.iso8601.year().month().day())).md"
        panel.canCreateDirectories = true
        if let md = UTType(filenameExtension: "md") { panel.allowedContentTypes = [md] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            digestError = "Export failed — \(error.localizedDescription)"
        }
    }
}

/// Shared timeline styling helpers (block colors, duration labels).
enum TimelineStyle {
    /// Stable per-app color from the name hash.
    static func color(for app: String) -> Color {
        var hash: UInt64 = 5381
        for byte in app.utf8 { hash = hash &* 33 &+ UInt64(byte) }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.78)
    }

    static func hm(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}

// MARK: - Day column — header, summary rail, hour track

struct TimelineDayView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: TimelineModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.blocks.isEmpty {
                ContentUnavailableView(
                    "No activity recorded",
                    systemImage: "clock",
                    description: Text(app.settings.trackingEnabled
                        ? "Blocks appear as you use your Mac (sampled every 5 s, idle-aware)."
                        : "Day tracking is off — enable it in Settings."))
                    .frame(maxHeight: .infinity)
            } else {
                summaryRail
                Divider()
                DayTrackView(blocks: model.blocks, selection: $model.selection)
                    .accessibilityIdentifier("timeline.track")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Timeline")
        .task(id: model.day.formatted(date: .numeric, time: .omitted)) {
            model.reload(app: app)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    app.sampler.isPaused.toggle()
                } label: {
                    Label(app.sampler.isPaused ? "Resume Tracking" : "Pause Tracking",
                          systemImage: app.sampler.isPaused ? "play.fill" : "pause.fill")
                }
                Button {
                    model.reload(app: app)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { model.moveDay(by: -1) } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Previous day")
            DatePicker("", selection: $model.day, displayedComponents: .date)
                .labelsHidden().fixedSize()
            Button { model.moveDay(by: 1) } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel("Next day")
            .disabled(Calendar.current.isDateInToday(model.day))
            Spacer()
        }
    }

    private var summaryRail: some View {
        let total = model.blocks.reduce(0) { $0 + $1.duration }
        let apps = Set(model.blocks.map(\.app)).count
        let meetings = app.meetings.filter {
            Calendar.current.isDate($0.startedAt, inSameDayAs: model.day)
        }.count
        return HStack(spacing: 8) {
            StatTile(icon: "clock", value: TimelineStyle.hm(total), label: "tracked")
            StatTile(icon: "square.grid.2x2", value: "\(apps)", label: apps == 1 ? "app" : "apps")
            StatTile(icon: "camera.viewfinder", value: "\(model.shots.count)", label: "screens")
            if meetings > 0 {
                StatTile(icon: "waveform", value: "\(meetings)",
                         label: meetings == 1 ? "meeting" : "meetings")
            }
            Spacer()
        }
    }
}

// MARK: - Inspector pane — selected block + tabbed detail

struct TimelineInspectorView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: TimelineModel

    var body: some View {
        if model.blocks.isEmpty {
            ContentUnavailableView(
                "Nothing to inspect",
                systemImage: "calendar.day.timeline.left",
                description: Text("Totals, screenshots, and the day digest appear once activity is tracked."))
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let block = model.selectedBlock { selectedBlockCard(block) }
                Picker("Inspector", selection: $model.inspectorTab) {
                    ForEach(TimelineModel.InspectorTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityIdentifier("timeline.inspector")
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        switch model.inspectorTab {
                        case .totals: totals
                        case .screenshots: screenshots
                        case .ask: askSection
                        case .digest: digestSection
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func selectedBlockCard(_ block: ActivityBlock) -> some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(color: TimelineStyle.color(for: block.app), size: 10)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(block.app).font(.subheadline.weight(.semibold))
                if !block.title.isEmpty {
                    Text(block.title).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("\(block.start.formatted(date: .omitted, time: .shortened))–\(block.end.formatted(date: .omitted, time: .shortened)) · \(TimelineStyle.hm(block.duration))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Spacer()
            Button { model.selection = nil } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Clear selection")
        }
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: Brand.Radius.control))
    }

    private var totals: some View {
        let perApp = Dictionary(grouping: model.blocks, by: \.app)
            .mapValues { $0.reduce(0) { $0 + $1.duration } }
            .sorted { $0.value > $1.value }
        let total = perApp.reduce(0) { $0 + $1.value }
        let top = perApp.prefix(12)
        let rest = perApp.dropFirst(12)
        let restSeconds = rest.reduce(0) { $0 + $1.value }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Time by app — \(TimelineStyle.hm(total)) tracked").font(.headline)
            ForEach(top, id: \.key) { appName, seconds in
                totalsRow(TimelineStyle.color(for: appName), appName, seconds, of: total)
            }
            if !rest.isEmpty {
                totalsRow(Color(nsColor: .tertiaryLabelColor),
                          "Other (\(rest.count) app\(rest.count == 1 ? "" : "s"))",
                          restSeconds, of: total)
            }
        }
    }

    private func totalsRow(_ swatch: Color, _ label: String, _ seconds: TimeInterval,
                           of total: TimeInterval) -> some View {
        HStack(spacing: 8) {
            StatusDot(color: swatch, size: 9)
            Text(label).font(.body).lineLimit(1)
            Spacer()
            Text(TimelineStyle.hm(seconds)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Text(String(format: "%2.0f%%", seconds / max(total, 1) * 100))
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    /// Decrypted thumbnails, wrapped to the inspector width and scoped to the
    /// selected block's time window when one is picked. Lazy + cached decode
    /// (see `ThumbnailView`) so a full day of shots no longer decrypts eagerly.
    private var screenshots: some View {
        let scoped: [ActivityStore.Screenshot]
        let heading: String
        if let block = model.selectedBlock {
            scoped = model.shots.filter { $0.ts >= block.start && $0.ts <= block.end }
            heading = "Screenshots · \(block.app) (\(scoped.count))"
        } else {
            scoped = model.shots
            heading = "Screenshots (\(scoped.count))"
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(heading).font(.headline)
            if scoped.isEmpty {
                Text(model.selectedBlock == nil ? "None captured today." : "None during this block.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                    ForEach(scoped) { shot in
                        ThumbnailView(path: shot.path)
                            .help("\(shot.app) — \(shot.ts.formatted(date: .omitted, time: .shortened))")
                    }
                }
            }
        }
    }

    private var askSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about this day").font(.headline)
            HStack {
                TextField("e.g. What was I working on before lunch?", text: $model.question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.ask(app: app) } }
                Button(model.asking ? "Thinking…" : "Ask") { Task { await model.ask(app: app) } }
                    .disabled(model.asking || model.question.isEmpty)
            }
            if let answer = model.answer {
                MarkdownText(answer)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private var digestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Day digest").font(.headline)
                if model.generating { ProgressView().controlSize(.small) }
                Spacer()
                if let digest = model.digest {
                    Button { model.copyDigest(digest) } label: { Image(systemName: "doc.on.doc") }
                        .help("Copy the digest to the clipboard")
                    Button { model.exportDigest(digest) } label: { Image(systemName: "square.and.arrow.up") }
                        .help("Save the digest as a Markdown file")
                }
            }
            Button(model.digest == nil ? "Generate digest" : "Regenerate") {
                Task { await model.generateDigest(app: app) }
            }
            .disabled(model.generating)
            if let digestError = model.digestError {
                Label(digestError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let digest = model.digest {
                MarkdownText(digest)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }
}

/// Vertical, hour-indexed activity track (calendar day-view metaphor). Time
/// runs top→bottom at a fixed scale, so a busy day simply grows taller and
/// scrolls instead of being crushed into one screen-width bar; every block
/// keeps the full lane width for its label and a real, tappable height.
private struct DayTrackView: View {
    let blocks: [ActivityBlock]
    @Binding var selection: ActivityBlock.ID?

    private let pointsPerHour: CGFloat = 100
    private let gutter: CGFloat = 56

    var body: some View {
        let start = trackStart
        let hours = hourCount(from: start)
        let height = CGFloat(hours) * pointsPerHour
        ScrollView {
            GeometryReader { geo in
                let laneWidth = max(40, geo.size.width - gutter)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(0..<hours), id: \.self) { i in
                        let y = CGFloat(i) * pointsPerHour
                        Rectangle().fill(.quaternary.opacity(0.4))
                            .frame(width: laneWidth, height: 1)
                            .offset(x: gutter, y: y)
                        Text(hourLabel(start, i))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            .frame(width: gutter - 8, alignment: .trailing)
                            .offset(y: y - 6)
                    }
                    ForEach(blocks) { block in
                        blockView(block, start: start, laneWidth: laneWidth)
                    }
                }
                .frame(width: geo.size.width, height: height, alignment: .topLeading)
            }
            .frame(height: height)
        }
    }

    @ViewBuilder
    private func blockView(_ block: ActivityBlock, start: Date, laneWidth: CGFloat) -> some View {
        let y = CGFloat(block.start.timeIntervalSince(start) / 3600) * pointsPerHour
        let h = max(5, CGFloat(block.duration / 3600) * pointsPerHour)
        let isSelected = selection == block.id
        RoundedRectangle(cornerRadius: 4)
            .fill(TimelineStyle.color(for: block.app).opacity(isSelected ? 1 : 0.85))
            .overlay(alignment: .topLeading) {
                if h >= 20 {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(block.app).font(.caption.weight(.medium)).lineLimit(1)
                        if !block.title.isEmpty && h >= 38 {
                            Text(block.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 6).padding(.top, 3)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
            .frame(width: laneWidth, height: h, alignment: .topLeading)
            .offset(x: gutter, y: y)
            .help("\(block.app)\(block.title.isEmpty ? "" : " — \(block.title)")\n\(block.start.formatted(date: .omitted, time: .shortened))–\(block.end.formatted(date: .omitted, time: .shortened)) · \(TimelineStyle.hm(block.duration))")
            .onTapGesture { selection = isSelected ? nil : block.id }
    }

    private var trackStart: Date {
        let first = blocks.first?.start ?? Calendar.current.startOfDay(for: Date())
        return Calendar.current.dateInterval(of: .hour, for: first)?.start ?? first
    }

    private func hourCount(from start: Date) -> Int {
        let last = blocks.map(\.end).max() ?? start.addingTimeInterval(3600)
        return max(1, Int(ceil(last.timeIntervalSince(start) / 3600)))
    }

    private func hourLabel(_ start: Date, _ i: Int) -> String {
        start.addingTimeInterval(Double(i) * 3600).formatted(date: .omitted, time: .shortened)
    }
}

/// Decoded-thumbnail cache, keyed by encrypted-file path. Decoding a HEIC and
/// AES-opening it is not free; caching means each screenshot is decrypted once
/// per session no matter how often the grid is rebuilt or scrolled.
private enum ThumbnailCache {
    static let shared = NSCache<NSString, NSImage>()
}

/// One screenshot thumbnail: decrypts off the main actor on first appearance,
/// caches the result, and shows a placeholder until it's ready. Combined with
/// `LazyVGrid`, only on-screen thumbnails are ever decoded.
private struct ThumbnailView: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: path) { await load() }
    }

    private func load() async {
        if let cached = ThumbnailCache.shared.object(forKey: path as NSString) {
            image = cached
            return
        }
        guard let key = try? ScreenshotService.encryptionKey() else { return }
        let filePath = path
        let data = await Task.detached(priority: .utility) {
            ScreenshotService.decryptedData(path: filePath, key: key)
        }.value
        guard let data, let decoded = NSImage(data: data) else { return }
        ThumbnailCache.shared.setObject(decoded, forKey: path as NSString)
        image = decoded
    }
}
