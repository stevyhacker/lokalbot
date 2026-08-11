import SwiftUI

/// Human-first rendering of the lossless Markdown day journal. Summary and
/// focus stay visible; the forensic activity/evidence trail is available on
/// demand without making every captured moment compete for attention.
struct DayDigestView: View {
    enum Mode: Equatable {
        case standalone
        case timeline
        case today

        var showsMeetings: Bool { self != .today }
        var showsTimeAllocation: Bool { self == .standalone }
        var showsFullActivityLog: Bool { self != .today }
    }

    let presentation: DayDigestPresentation
    let mode: Mode

    @State private var fullActivityExpanded = false
    @State private var extraFocusExpanded = false
    @State private var otherActivityExpanded = false
    @State private var timeAllocationExpanded = false

    init(_ markdown: String, mode: Mode = .standalone) {
        presentation = DayDigestPresentation(markdown: markdown)
        self.mode = mode
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !presentation.atAGlanceMarkdown.isEmpty {
                digestSection("Highlights", icon: "sparkles") {
                    SelectableDigestText(presentation.atAGlanceMarkdown)
                }
            }

            if !presentation.focusBlocks.isEmpty {
                digestSection("Tasks", icon: "briefcase") {
                    VStack(alignment: .leading, spacing: 8) {
                        sessionList(Array(presentation.focusBlocks.prefix(3)))
                        let additional = Array(presentation.focusBlocks.dropFirst(3))
                        if !additional.isEmpty {
                            DisclosureGroup(
                                isExpanded: $extraFocusExpanded,
                                content: {
                                    sessionList(additional)
                                    .padding(.top, 8)
                                },
                                label: {
                                    Text(extraFocusExpanded
                                         ? "Hide additional sessions"
                                         : "Show \(additional.count) more session\(additional.count == 1 ? "" : "s")")
                                        .font(.callout.weight(.medium))
                                })
                            .accessibilityIdentifier("dayDigest.moreSummaryDetails")
                        }
                    }
                }
            }

            if !presentation.otherActivityBlocks.isEmpty {
                DisclosureGroup(isExpanded: $otherActivityExpanded) {
                    sessionList(presentation.otherActivityBlocks)
                        .padding(.top, 8)
                } label: {
                    HStack(spacing: 8) {
                        Label("Other activity", systemImage: "ellipsis.circle")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(presentation.otherActivityBlocks.count) item\(presentation.otherActivityBlocks.count == 1 ? "" : "s")")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("dayDigest.otherActivity")
                .accessibilityHint("Shorter activities that used a smaller share of the recorded day")
            }

            if let decisions = presentation.decisionsMarkdown {
                digestSection("Decisions and next steps", icon: "checklist") {
                    SelectableDigestText(decisions)
                }
            }

            if mode.showsMeetings, let meetings = presentation.meetingsMarkdown {
                digestSection("Meetings", icon: "person.2") {
                    SelectableDigestText(meetings)
                }
            }

            if mode.showsTimeAllocation, !presentation.timeAllocations.isEmpty {
                timeAllocationDisclosure
            }

            if mode.showsFullActivityLog, presentation.activityCount > 0 {
                DisclosureGroup(isExpanded: $fullActivityExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(presentation.activityGroups) { group in
                            DayDigestActivityHourView(group: group)
                        }
                    }
                    .padding(.top, 10)
                } label: {
                    HStack(spacing: 8) {
                        Label("Full activity log", systemImage: "clock.arrow.circlepath")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(presentation.activityCount) events")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("dayDigest.fullActivityLog")
                .accessibilityHint("Contains the complete activity log grouped by hour")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func digestSection<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionList(_ blocks: [DayDigestPresentation.FocusBlock]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { block in
                focusBlock(block)
                    .padding(.vertical, 10)
                if block.id != blocks.last?.id {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 12)
        .background(.quaternary.opacity(0.24),
                    in: RoundedRectangle(cornerRadius: Brand.Radius.control))
    }

    private func focusBlock(_ block: DayDigestPresentation.FocusBlock) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if block.timeRange != nil || block.title != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let timeRange = block.timeRange {
                        Text(timeRange)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let title = block.title {
                        Text(title)
                            .font(.body.weight(.semibold))
                            .textSelection(.enabled)
                    }
                }
            }
            if !block.summaryMarkdown.isEmpty {
                SelectableDigestText(block.summaryMarkdown)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeAllocationDisclosure: some View {
        let total = presentation.timeAllocations.reduce(0) { $0 + $1.seconds }
        let segments = ProportionBarMath.segments(perApp: presentation.timeAllocations.map {
            (label: $0.app, seconds: $0.seconds)
        })
        return DisclosureGroup(isExpanded: $timeAllocationExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                if total > 0 {
                    ProportionBar(segments: segments.map {
                        ($0, $0.label == "Other"
                            ? Color(nsColor: .tertiaryLabelColor)
                            : CaptureStyle.color(for: $0.label))
                    })
                    .padding(.vertical, 2)
                }
                ForEach(presentation.timeAllocations.prefix(12)) { allocation in
                    HStack(spacing: 8) {
                        StatusDot(color: CaptureStyle.color(for: allocation.app), size: 8)
                        Text(allocation.app).lineLimit(1)
                        Spacer(minLength: 12)
                        Text(allocation.detail)
                            .font(allocation.seconds > 0
                                ? .callout.monospacedDigit() : .callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                        }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Label("Time allocation", systemImage: "chart.bar.xaxis")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Activity details")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("dayDigest.timeAllocation")
        .accessibilityHint("Tracked app time shown as optional supporting detail")
    }
}

private struct DayDigestActivityHourView: View {
    let group: DayDigestPresentation.ActivityHourGroup
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(group.entries) { entry in
                    DayDigestActivityEntryView(entry: entry)
                    if entry.id != group.entries.last?.id {
                        Divider().padding(.vertical, 7)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.leading, 4)
        } label: {
            HStack {
                Text(group.label)
                    .font(.callout.weight(.medium).monospacedDigit())
                Spacer()
                Text("\(group.entries.count) event\(group.entries.count == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("dayDigest.activityHour.\(group.id)")
    }
}

private struct DayDigestActivityEntryView: View {
    let entry: DayDigestPresentation.ActivityEntry
    @State private var evidenceExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SelectableDigestText(entry.headlineMarkdown)
            if !entry.evidenceMarkdown.isEmpty {
                DisclosureGroup(isExpanded: $evidenceExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(entry.evidenceMarkdown.enumerated()), id: \.offset) { _, line in
                            SelectableDigestText("- " + line)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Captured evidence · \(entry.evidenceMarkdown.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("dayDigest.activityEvidence.\(entry.id)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
