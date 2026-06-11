import SwiftUI

/// M4 timeline (design doc §4.2): one day at a time — colored blocks on a
/// time axis, per-app totals, and an on-demand LLM day digest saved to
/// journal/<date>.md.
struct TimelineView: View {
    @EnvironmentObject var app: AppState

    @State private var day = Date()
    @State private var blocks: [ActivityBlock] = []
    @State private var shots: [ActivityStore.Screenshot] = []
    @State private var digest: String?
    @State private var generating = false
    @State private var digestError: String?
    @State private var question = ""
    @State private var answer: String?
    @State private var asking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if blocks.isEmpty {
                    ContentUnavailableView(
                        "No activity recorded",
                        systemImage: "clock",
                        description: Text(app.settings.trackingEnabled
                            ? "Blocks appear as you use your Mac (sampled every 5 s, idle-aware)."
                            : "Day tracking is off — enable it in Settings."))
                        .frame(minHeight: 240)
                } else {
                    timelineBar
                    totals
                    if !shots.isEmpty { filmstrip }
                    askSection
                    digestSection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task(id: day.formatted(date: .numeric, time: .omitted)) { reload() }
        .navigationTitle("Timeline")
    }

    private var header: some View {
        HStack {
            Button { day = day.addingTimeInterval(-86_400) } label: { Image(systemName: "chevron.left") }
            DatePicker("", selection: $day, displayedComponents: .date)
                .labelsHidden().fixedSize()
            Button { day = day.addingTimeInterval(86_400) } label: { Image(systemName: "chevron.right") }
                .disabled(Calendar.current.isDateInToday(day))
            Spacer()
            Button(app.sampler.isPaused ? "Resume tracking" : "Pause tracking") {
                app.sampler.isPaused.toggle()
            }
            Button("Refresh") { reload() }
        }
    }

    // One horizontal bar spanning the active part of the day.
    private var timelineBar: some View {
        let span = activeSpan
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.4))
                    ForEach(blocks) { block in
                        let x = offset(block.start, in: span, width: geo.size.width)
                        let w = max(2, offset(block.end, in: span, width: geo.size.width) - x)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Self.color(for: block.app))
                            .frame(width: w, height: 36)
                            .offset(x: x)
                            .help("\(block.app)\(block.title.isEmpty ? "" : " — \(block.title)")\n\(block.start.formatted(date: .omitted, time: .shortened))–\(block.end.formatted(date: .omitted, time: .shortened))")
                    }
                }
            }
            .frame(height: 36)
            HStack {
                Text(span.lowerBound.formatted(date: .omitted, time: .shortened))
                Spacer()
                Text(span.upperBound.formatted(date: .omitted, time: .shortened))
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var totals: some View {
        let perApp = Dictionary(grouping: blocks, by: \.app)
            .mapValues { $0.reduce(0) { $0 + $1.duration } }
            .sorted { $0.value > $1.value }
        let total = perApp.reduce(0) { $0 + $1.value }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Time by app — \(Self.hm(total)) tracked").font(.headline)
            ForEach(perApp.prefix(12), id: \.key) { appName, seconds in
                HStack(spacing: 8) {
                    Circle().fill(Self.color(for: appName)).frame(width: 9, height: 9)
                    Text(appName).font(.system(size: 13))
                    Spacer()
                    Text(Self.hm(seconds)).font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(String(format: "%2.0f%%", seconds / max(total, 1) * 100))
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
    }

    /// M5: hourly-ish strip of decrypted thumbnails.
    private var filmstrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Screenshots (\(shots.count))").font(.headline)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(shots) { shot in
                        if let image = ScreenshotService.decrypt(path: shot.path) {
                            Image(nsImage: image)
                                .resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 148, height: 92)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .help("\(shot.app) — \(shot.ts.formatted(date: .omitted, time: .shortened))")
                        }
                    }
                }
            }
        }
    }

    /// M6: ask anything about the day — blocks + OCR + meetings as context.
    private var askSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about this day").font(.headline)
            HStack {
                TextField("e.g. What was I working on before lunch?", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await ask() } }
                Button(asking ? "Thinking…" : "Ask") { Task { await ask() } }
                    .disabled(asking || question.isEmpty)
            }
            if let answer {
                MarkdownText(answer)
                    .frame(maxWidth: 720, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private func ask() async {
        asking = true
        defer { asking = false }
        let lines = blocks.map {
            "\($0.start.formatted(date: .omitted, time: .shortened))–\($0.end.formatted(date: .omitted, time: .shortened)) \($0.app)\($0.title.isEmpty ? "" : ": \($0.title)")"
        }
        let ocr = app.activityStore.ocrText(on: day)
        do {
            let engine = try await app.pipeline.makeTextEngine(app.settings)
            answer = try await engine.generate(
                system: "Answer the user's question about their workday using ONLY the provided activity log and screen text. Be concrete and brief (Markdown). If the answer isn't in the data, say so.",
                prompt: question,
                context: ["Activity log:\n" + lines.joined(separator: "\n"),
                          ocr.isEmpty ? "" : "Screen text excerpts:\n" + ocr])
        } catch {
            answer = "⚠️ \(error.localizedDescription)"
        }
    }

    private var digestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Day digest").font(.headline)
                if generating { ProgressView().controlSize(.small) }
                Spacer()
                Button(digest == nil ? "Generate digest" : "Regenerate") {
                    Task { await generateDigest() }
                }
                .disabled(generating)
            }
            if let digestError {
                Label(digestError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if let digest {
                MarkdownText(digest)
                    .frame(maxWidth: 720, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: helpers

    private func reload() {
        blocks = app.activityStore.blocks(on: day)
        shots = app.activityStore.screenshots(on: day)
        digest = try? String(contentsOf: journalURL, encoding: .utf8)
        digestError = nil
    }

    private var journalURL: URL {
        let name = day.formatted(.iso8601.year().month().day())
        return app.storage.rootURL.appendingPathComponent("journal/\(name).md")
    }

    private func generateDigest() async {
        generating = true
        defer { generating = false }
        let todays = app.meetings.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: day) }
        do {
            let (text, _) = try await app.pipeline.generateDayDigest(
                for: day, blocks: blocks, meetings: todays, config: app.settings)
            digest = text
        } catch {
            digestError = error.localizedDescription
        }
    }

    private var activeSpan: ClosedRange<Date> {
        let first = blocks.first?.start ?? Calendar.current.startOfDay(for: day)
        let last = blocks.last?.end ?? first.addingTimeInterval(3600)
        return first...max(last, first.addingTimeInterval(1800))
    }

    private func offset(_ date: Date, in span: ClosedRange<Date>, width: CGFloat) -> CGFloat {
        let total = span.upperBound.timeIntervalSince(span.lowerBound)
        let position = date.timeIntervalSince(span.lowerBound)
        return CGFloat(max(0, min(1, position / max(total, 1)))) * width
    }

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
