import SwiftUI

/// The default landing surface: one glanceable page composing today's
/// answers — what's capturing right now, what happened, where the time
/// went, and a way to ask about any of it. Today summarizes; the Timeline
/// stays the forensic, hour-indexed view of the same day.
struct TodayView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var model = CaptureModel()
    @AppStorage("lokalbotv3.gettingStartedDismissed")
    private var gettingStartedDismissed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !gettingStartedDismissed {
                    GettingStartedCard()
                }
                dreamCard
                nowCard
                daySoFar
                meetingsSection
                askSection
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("Today")
        .task(id: app.navSection) {
            guard app.navSection == .today else { return }
            reloadCurrentDay(at: Date())
        }
        .onChange(of: app.latestDreamReport) { _, _ in
            guard app.navSection == .today else { return }
            // A report normally arrives after midnight while this view may
            // have remained mounted since yesterday. Re-anchor every section,
            // not just the dream card, before selecting the new report.
            reloadCurrentDay(at: Date())
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Today")
                .font(.largeTitle.bold())
                .accessibilityIdentifier("today.header")
            Text(Date().formatted(date: .complete, time: .omitted))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    @State private var question = ""

    // MARK: Dream (morning brief)

    @State private var dream: DreamReport?
    @State private var showingDreamInfo = false

    /// The overnight brief covers yesterday relative to the page's day; an
    /// older leftover report is not shown as if it were fresh.
    private func reloadCurrentDay(at date: Date) {
        model.selectDay(date, app: app)
        dream = TodayDreamSelection.report(
            referenceDate: date,
            latest: app.latestDreamReport,
            store: app.dreamStore)
    }

    @ViewBuilder private var dreamCard: some View {
        if let dream {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz.fill")
                        .foregroundStyle(Brand.teal)
                    Text(dreamDayLabel(dream))
                        .font(.title3.bold())
                        .accessibilityIdentifier("today.dream")
                    Spacer()
                    Text("Morning brief")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Button {
                        showingDreamInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("About this morning brief")
                        .accessibilityLabel("About this morning brief")
                        .popover(isPresented: $showingDreamInfo) {
                            Text(dream.provenanceDescription)
                                .font(.callout)
                                .padding(14)
                                .frame(width: 300, alignment: .leading)
                        }
                }
                if !dream.topActions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Priorities for today").font(.headline)
                        ForEach(Array(dream.topActions.enumerated()), id: \.offset) { index, action in
                            Text("\(index + 1). \(action)")
                                .textSelection(.enabled)
                        }
                    }
                }
                if !dream.narrative.isEmpty {
                    Text(displayedNarrative(dream))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if let retrospective = retrospectiveMarkdown(dream) {
                    DisclosureGroup("More from yesterday") {
                        MarkdownText(retrospective)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.top, 6)
                    }
                }
                dreamInferenceNotice(dream)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))
        }
    }

    private func displayedNarrative(_ dream: DreamReport) -> String {
        let dateReference: String
        if TodayDreamSelection.isCurrent(dream, referenceDate: model.day) {
            dateReference = "yesterday"
        } else {
            dateReference = DreamDay.date(fromKey: dream.day)
                .map { "on " + $0.formatted(date: .abbreviated, time: .omitted) }
                ?? "on a previous workday"
        }
        return dream.narrative
            .replacingOccurrences(of: "on \(dream.day)", with: dateReference)
            .replacingOccurrences(of: ", and no work goals were recorded", with: "")
    }

    private func dreamDayLabel(_ dream: DreamReport) -> String {
        if TodayDreamSelection.isCurrent(dream, referenceDate: model.day) {
            return "Yesterday"
        }
        return DreamDay.date(fromKey: dream.day)
            .map { $0.formatted(date: .abbreviated, time: .omitted) }
            ?? "Previous workday"
    }

    private func retrospectiveMarkdown(_ dream: DreamReport) -> String? {
        let groups: [(String, [String])] = [
            ("Needs attention", dream.attention),
            ("Repeated work worth automating", dream.repeatedWork),
            ("Suggested recurring checks", dream.suggestedChecks),
            ("Friction to smooth out", dream.frictions),
        ]
        let sections = groups.compactMap { title, items -> String? in
            guard !items.isEmpty else { return nil }
            return "### \(title)\n" + items.map { "- \($0)" }.joined(separator: "\n")
        }
        guard !sections.isEmpty else { return nil }
        return sections.joined(separator: "\n\n")
    }

    @ViewBuilder private func dreamInferenceNotice(_ dream: DreamReport) -> some View {
        if dream.isFallback {
            Label(
                dream.provenanceDescription + " Dream again from Settings → Recording.",
                systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if dream.inferenceProvenance?.location == .remote {
            Label("Generated using approved remote inference", systemImage: "network")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(dream.provenanceDescription)
        }
    }

    // MARK: Now

    /// What's happening right now: the live recording front and center,
    /// otherwise the most recent capture of the day, otherwise an
    /// invitation to record.
    @ViewBuilder private var nowCard: some View {
        if let live = app.currentMeeting {
            HeroPanel(radius: Brand.Radius.panel) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        StatusDot(color: Brand.recording, size: 9)
                        Text("Recording — \(live.title)")
                            .font(.headline).foregroundStyle(.white)
                        Spacer()
                        LiveWaveform(barCount: 7, barWidth: 3, maxHeight: 14)
                    }
                    HStack(spacing: 8) {
                        Button {
                            app.showLiveMeeting()
                        } label: {
                            Label("Live transcript & notes", systemImage: "text.bubble")
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Stop recording") { app.stopRecording() }
                            .buttonStyle(.bordered)
                    }
                }
            }
        } else {
            HStack(spacing: 10) {
                Label("Nothing recording right now", systemImage: "record.circle")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Record now") {
                    app.startRecording(
                        context: app.recordingContext(for: app.detector.activeApp))
                }
            }
        }
    }

    // MARK: Day so far

    private var perApp: [(key: String, value: TimeInterval)] {
        Dictionary(grouping: model.blocks, by: \.app)
            .mapValues { $0.reduce(0) { $0 + $1.duration } }
            .sorted { $0.value > $1.value }
    }

    @ViewBuilder private var daySoFar: some View {
        let apps = perApp
        let todaysMeetings = model.meetings(in: app)
        if !model.blocks.isEmpty || !model.shots.isEmpty || model.digest != nil {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Day so far").font(.title3.bold())
                    Spacer()
                    Button("Open timeline") { app.navSection = .timeline }
                        .buttonStyle(.plain)
                        .foregroundStyle(Brand.teal)
                }
                DayStatRow(
                    trackedSeconds: apps.reduce(0) { $0 + $1.value },
                    appCount: apps.count,
                    momentCount: model.shots.count,
                    meetingCount: todaysMeetings.count)
                if !apps.isEmpty {
                    ProportionBar(segments: ProportionBarMath.segments(
                        perApp: apps.map { (label: $0.key, seconds: $0.value) }
                    ).map {
                        ($0, $0.label == "Other" ? Color(nsColor: .tertiaryLabelColor)
                                                 : CaptureStyle.color(for: $0.label))
                    })
                }
                digestBlock
            }
        }
    }

    @ViewBuilder private var digestBlock: some View {
        if let digest = model.digest {
            DayDigestView(digest, mode: .today)
                .accessibilityIdentifier("today.dayDigest.text")
        } else {
            HStack(spacing: 8) {
                Button("Write day digest") {
                    Task { await model.generateDigest(app: app) }
                }
                .disabled(model.generating)
                if model.generating { ProgressView().controlSize(.small) }
            }
        }
        if let digestError = model.digestError {
            Label(digestError, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
        }
    }

    // MARK: Meetings

    private var meetingsSection: some View {
        let todays = model.meetings(in: app)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Today's meetings")
                .font(.title3.bold())
                .accessibilityIdentifier("today.meetings")
            if todays.isEmpty {
                Text("No meetings captured today. LokalBot detects meeting apps automatically — or choose Record now.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(todays) { meeting in
                    Button {
                        app.openMeeting(meeting.id)
                    } label: {
                        MeetingRowView(meeting: meeting)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Ask

    private var askSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask about today").font(.title3.bold())
            HStack(spacing: 8) {
                TextField("What did we decide about…", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitQuestion)
                    .accessibilityIdentifier("today.ask")
                Button("Ask") { submitQuestion() }
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func submitQuestion() {
        let text = question.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        question = ""
        app.openAsk(query: text, dayScope: model.day, submit: true)
    }
}

/// Pure report selection keeps the overnight/current-day boundary testable
/// without mounting SwiftUI or relying on a stale `CaptureModel.day` value.
enum TodayDreamSelection {
    /// How many days back (yesterday included) the card will reach for a
    /// substantive brief before going quiet.
    static let lookbackDays = 5

    /// Yesterday's brief when there is one; otherwise the newest substantive
    /// brief within the lookback. Empty-day stubs exist only to mark their day
    /// dreamed — they are never surfaced, and a returning user sees their last
    /// real morning brief instead of "nothing was recorded".
    static func report(
        referenceDate: Date,
        latest: DreamReport?,
        store: DreamStore,
        calendar: Calendar = .current
    ) -> DreamReport? {
        var day = DreamScheduler.previousDay(of: referenceDate, calendar: calendar)
        for _ in 0..<lookbackDays {
            let key = DreamDay.key(for: day, calendar: calendar)
            let candidate = (latest?.day == key) ? latest : store.report(forDayKey: key)
            if let candidate, candidate.fallbackReason != .emptyDay { return candidate }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else {
                return nil
            }
            day = previous
        }
        return nil
    }

    /// False when the report covers an older day than yesterday, so the card
    /// can label it instead of presenting it as fresh.
    static func isCurrent(
        _ report: DreamReport,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> Bool {
        let yesterday = DreamScheduler.previousDay(of: referenceDate, calendar: calendar)
        return report.day == DreamDay.key(for: yesterday, calendar: calendar)
    }
}
