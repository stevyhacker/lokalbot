import SwiftUI

/// Human-first rendering of the lossless Markdown day journal. Summary and
/// focus stay visible; the forensic activity/evidence trail is available on
/// demand without making every captured moment compete for attention.
struct DayDigestView: View {
    let presentation: DayDigestPresentation

    @State private var fullActivityExpanded = false
    @State private var extraFocusExpanded = false

    init(_ markdown: String) {
        presentation = DayDigestPresentation(markdown: markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !presentation.atAGlanceMarkdown.isEmpty {
                digestSection("At a glance", icon: "sparkles") {
                    SelectableDigestText(presentation.atAGlanceMarkdown)
                }
            }

            if !presentation.focusBlocks.isEmpty {
                digestSection("Focus blocks", icon: "scope") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(presentation.focusBlocks) { block in
                            focusBlock(block)
                        }
                        if !presentation.additionalFocusBlocks.isEmpty {
                            DisclosureGroup(
                                isExpanded: $extraFocusExpanded,
                                content: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(presentation.additionalFocusBlocks) { block in
                                            focusBlock(block)
                                        }
                                    }
                                    .padding(.top, 8)
                                },
                                label: {
                                    Text("More summary details · \(presentation.additionalFocusBlocks.count)")
                                        .font(.callout.weight(.medium))
                                })
                            .accessibilityIdentifier("dayDigest.moreSummaryDetails")
                        }
                    }
                }
            }

            if let decisions = presentation.decisionsMarkdown {
                digestSection("Decisions and next steps", icon: "checklist") {
                    SelectableDigestText(decisions)
                }
            }

            if let meetings = presentation.meetingsMarkdown {
                digestSection("Meetings", icon: "person.2") {
                    SelectableDigestText(meetings)
                }
            }

            if !presentation.timeAllocations.isEmpty {
                timeAllocationSection
            }

            if presentation.activityCount > 0 {
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
                            .font(.headline)
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
                .font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func focusBlock(_ block: DayDigestPresentation.FocusBlock) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SelectableDigestText(block.markdown)
            if block.sourceCount > 0 {
                Label(
                    "\(block.sourceCount) captured source\(block.sourceCount == 1 ? "" : "s")",
                    systemImage: "rectangle.and.text.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }

    private var timeAllocationSection: some View {
        let total = presentation.timeAllocations.reduce(0) { $0 + $1.seconds }
        let segments = ProportionBarMath.segments(perApp: presentation.timeAllocations.map {
            (label: $0.app, seconds: $0.seconds)
        })
        return digestSection("Time allocation", icon: "chart.bar.xaxis") {
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
        }
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
