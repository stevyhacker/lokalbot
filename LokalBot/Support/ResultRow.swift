import SwiftUI

/// One run of an FTS5 snippet: matched runs render bold/primary.
struct SnippetSegment: Equatable {
    let text: String
    let isMatch: Bool
}

/// Splits an FTS5 snippet on «» match markers into runs. Pure; unit-tested.
enum SnippetHighlighter {
    static func segments(_ snippet: String) -> [SnippetSegment] {
        var result: [SnippetSegment] = []
        var rest = Substring(snippet)
        while let open = rest.firstIndex(of: "«") {
            if open > rest.startIndex {
                result.append(SnippetSegment(text: String(rest[..<open]), isMatch: false))
            }
            rest = rest[rest.index(after: open)...]
            if let close = rest.firstIndex(of: "»") {
                if close > rest.startIndex {
                    result.append(SnippetSegment(text: String(rest[..<close]), isMatch: true))
                }
                rest = rest[rest.index(after: close)...]
            } else {
                // Unmatched « — drop the marker, emit the tail as plain text.
                break
            }
        }
        if !rest.isEmpty {
            result.append(SnippetSegment(text: String(rest), isMatch: false))
        }
        return result
    }
}

/// Unified Ask result row (spec §3.2): title · kind chip · highlighted
/// snippet · timestamp — one anatomy for FTS, semantic, and screen hits.
struct ResultRow: View {
    let title: String
    let kind: String
    let snippet: String
    var timestamp: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).font(.headline).lineLimit(1)
                if let timestamp {
                    Text(timestamp).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                BrandChip(text: kind, size: .compact)
            }
            highlighted
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 3)
    }

    private var highlighted: Text {
        SnippetHighlighter.segments(snippet).reduce(Text("")) { acc, seg in
            acc + (seg.isMatch
                   ? Text(seg.text).bold().foregroundStyle(.primary)
                   : Text(seg.text))
        }
    }
}
