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
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Today")
        .task(id: app.navSection) {
            guard app.navSection == .today else { return }
            // Re-anchor to the current day on every arrival: the model is
            // created once, so a Mac left running past midnight would
            // otherwise keep showing yesterday.
            model.day = Date()
            model.reload(app: app)
            loadDream()
        }
        .onChange(of: app.latestDreamReport) { _, _ in loadDream() }
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

    /// The overnight brief covers yesterday relative to the page's day; an
    /// older leftover report is not shown as if it were fresh.
    private func loadDream() {
        let calendar = Calendar.current
        let yesterday = DreamScheduler.previousDay(of: model.day, calendar: calendar)
        let key = DreamDay.key(for: yesterday, calendar: calendar)
        if let latest = app.latestDreamReport, latest.day == key {
            dream = latest
        } else {
            dream = app.dreamStore.report(forDayKey: key)
        }
    }

    @ViewBuilder private var dreamCard: some View {
        if let dream {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz.fill")
                        .foregroundStyle(Brand.teal)
                    Text("While you were away")
                        .font(.title3.bold())
                        .accessibilityIdentifier("today.dream")
                    Spacer()
                    Text("Dreamed " + dream.generatedAt.formatted(.relative(presentation: .named)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !dream.narrative.isEmpty {
                    Text(dream.narrative)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                if !dream.topActions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Top actions today").font(.headline)
                        ForEach(Array(dream.topActions.enumerated()), id: \.offset) { index, action in
                            Text("\(index + 1). \(action)")
                                .textSelection(.enabled)
                        }
                    }
                }
                DisclosureGroup("Full retrospective") {
                    MarkdownText(dream.markdown())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.top, 6)
                }
                Text(dream.engineName.map { "Dreamed by \($0) from your local library. Nothing left this Mac." }
                    ?? "No model was reachable overnight — this brief lists evidence only. Dream again from Settings → Recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))
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
            MarkdownText(digest)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
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
