import SwiftUI

/// The pipeline writes a bold inline provenance line under the summary title
/// ("**Duration:** 32m · **App:** Zoom · … · **Model:** …"). Rendered as body
/// markdown it reads like debug output. These helpers lift that line out so
/// views can show it as a quiet metadata row while the raw `summary.md`
/// (exports, CLI, MCP) keeps the full header.
enum SummaryPresentation {
    struct MetadataItem: Equatable {
        let label: String
        let value: String
    }

    struct Parts: Equatable {
        var metadata: [MetadataItem]
        var body: String
    }

    /// Extracts the provenance line: the first non-empty, non-heading line
    /// among the leading lines, consisting of at least two `**Label:** value`
    /// pairs joined by "·". Requiring two pairs keeps a body that opens with
    /// ordinary bold text ("**Next steps:** …") intact.
    static func split(_ markdown: String) -> Parts {
        var lines = markdown.components(separatedBy: "\n")
        for (index, line) in lines.enumerated().prefix(4) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("#") { continue }
            guard let items = parseMetadataLine(trimmed), items.count >= 2 else { break }
            lines.remove(at: index)
            return Parts(
                metadata: items,
                body: lines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Parts(metadata: [], body: markdown)
    }

    private static func parseMetadataLine(_ line: String) -> [MetadataItem]? {
        var items: [MetadataItem] = []
        for piece in line.components(separatedBy: " · ") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("**"),
                  let labelEnd = trimmed.range(of: ":**") else { return nil }
            let label = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<labelEnd.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[labelEnd.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !value.isEmpty else { return nil }
            items.append(MetadataItem(label: label, value: value))
        }
        return items.isEmpty ? nil : items
    }
}

/// One quiet, wrapping metadata line for a generated summary's provenance.
struct SummaryMetadataRow: View {
    let items: [SummaryPresentation.MetadataItem]

    var body: some View {
        Text(items.map { "\($0.label) \($0.value)" }.joined(separator: "  ·  "))
            .font(WorkspaceTypography.metadata)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("summary.metadata")
    }
}
