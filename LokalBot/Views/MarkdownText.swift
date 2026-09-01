import SwiftUI

/// A selectable Markdown renderer backed by one SwiftUI `Text`. Keeping the
/// whole document in one attributed string gives macOS one continuous
/// selection range, so users can drag across lines and copy only the portion
/// they need. Editorial mode preserves Ask's compact type hierarchy and
/// citation treatment without splitting the answer into selection islands.
struct SelectableDigestText: View {
    enum Style: Equatable {
        case standard
        case editorial
    }

    let text: String
    var font: Font = .body
    var searchQuery: String = ""
    var activeMatchIndex: Int?
    var style: Style = .standard

    init(
        _ text: String,
        font: Font = .body,
        searchQuery: String = "",
        activeMatchIndex: Int? = nil,
        style: Style = .standard
    ) {
        self.text = text
        self.font = font
        self.searchQuery = searchQuery
        self.activeMatchIndex = activeMatchIndex
        self.style = style
    }

    var body: some View {
        Text(Self.attributedText(
            from: text,
            font: font,
            searchQuery: searchQuery,
            activeMatchIndex: activeMatchIndex,
            style: style))
            .lineSpacing(style == .editorial ? 4 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .help("Select any part and press ⌘C to copy")
    }

    static func attributedText(
        from markdown: String,
        font: Font = .body,
        searchQuery: String = "",
        activeMatchIndex: Int? = nil,
        style: Style = .standard
    ) -> AttributedString {
        let lines = markdown.components(separatedBy: "\n")
        var document = AttributedString()
        for (index, line) in lines.enumerated() {
            document.append(attributedLine(line, font: font, style: style))
            if index < lines.count - 1 {
                document.append(AttributedString("\n"))
            }
        }
        return MeetingSearchHighlighting.apply(
            to: document,
            query: searchQuery,
            activeMatchIndex: activeMatchIndex)
    }

    static func searchableText(from markdown: String) -> String {
        String(attributedText(from: markdown).characters)
    }

    private static func attributedLine(
        _ line: String,
        font: Font,
        style: Style
    ) -> AttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let baseFont = style == .editorial ? WorkspaceTypography.body : font
        if trimmed.isEmpty { return AttributedString() }
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            return styled("────────────────────", font: baseFont,
                          foreground: .secondary)
        }
        if trimmed.hasPrefix("### ") {
            let headingFont = style == .editorial
                ? WorkspaceTypography.bodyEmphasis
                : Font.headline
            return styledInline(
                String(trimmed.dropFirst(4)),
                font: headingFont,
                style: style)
        }
        if trimmed.hasPrefix("## ") {
            let headingFont = style == .editorial
                ? WorkspaceTypography.sectionTitle
                : Font.title3.bold()
            return styledInline(
                String(trimmed.dropFirst(3)),
                font: headingFont,
                style: style)
        }
        if trimmed.hasPrefix("# ") {
            let headingFont = style == .editorial
                ? WorkspaceTypography.conversationTitle
                : Font.title2.bold()
            return styledInline(
                String(trimmed.dropFirst(2)),
                font: headingFont,
                style: style)
        }
        if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") {
            return prefixed(trimmed.hasPrefix("- [x] ") ? "☑ " : "☐ ",
                            content: String(trimmed.dropFirst(6)),
                            font: baseFont,
                            style: style)
        }
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            return prefixed(
                "• ",
                content: String(trimmed.dropFirst(2)),
                font: baseFont,
                style: style)
        }
        if let ordered = orderedListItem(trimmed) {
            return prefixed(
                "\(ordered.number). ",
                content: ordered.rest,
                font: baseFont,
                style: style)
        }
        if trimmed.hasPrefix("> ") {
            return prefixed("▎ ", content: String(trimmed.dropFirst(2)),
                            font: baseFont.italic(),
                            foreground: .secondary,
                            style: style)
        }
        return styledInline(trimmed, font: baseFont, style: style)
    }

    private static func prefixed(_ prefix: String, content: String,
                                 font: Font = .body,
                                 foreground: Color? = nil,
                                 style: Style) -> AttributedString {
        var result = styled(prefix, font: font, foreground: foreground)
        result.append(styledInline(
            content,
            font: font,
            foreground: foreground,
            style: style))
        return result
    }

    private static func styledInline(_ source: String, font: Font,
                                     foreground: Color? = nil,
                                     style: Style) -> AttributedString {
        var result = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
        result.font = font
        if let foreground { result.foregroundColor = foreground }
        if style == .editorial { styleNumericCitations(in: &result) }
        return result
    }

    private static func styleNumericCitations(in attributedText: inout AttributedString) {
        let plainText = String(attributedText.characters)
        var searchStart = plainText.startIndex

        while searchStart < plainText.endIndex,
              let open = plainText[searchStart...].firstIndex(of: "[") {
            let afterOpen = plainText.index(after: open)
            guard let close = plainText[afterOpen...].firstIndex(of: "]") else { break }
            let digits = plainText[afterOpen..<close]
            let afterClose = plainText.index(after: close)

            if !digits.isEmpty,
               digits.allSatisfy(\.isNumber),
               let lowerBound = AttributedString.Index(open, within: attributedText),
               let upperBound = AttributedString.Index(afterClose, within: attributedText) {
                attributedText[lowerBound..<upperBound].font = WorkspaceTypography.metadataEmphasis
                attributedText[lowerBound..<upperBound].foregroundColor = Brand.teal
            }

            searchStart = afterClose
        }
    }

    private static func styled(_ source: String, font: Font,
                               foreground: Color? = nil) -> AttributedString {
        var result = AttributedString(source)
        result.font = font
        if let foreground { result.foregroundColor = foreground }
        return result
    }

    private static func orderedListItem(_ trimmed: String) -> (number: Int, rest: String)? {
        guard let dot = trimmed.firstIndex(of: "."),
              trimmed[..<dot].allSatisfy(\.isNumber),
              let number = Int(trimmed[..<dot]),
              trimmed.index(after: dot) < trimmed.endIndex,
              trimmed[trimmed.index(after: dot)] == " " else { return nil }
        return (number, String(trimmed[trimmed.index(dot, offsetBy: 2)...]))
    }
}

/// Plain transcript text with the same find highlighting used by summary
/// Markdown. Attributes preserve text selection and accessibility value.
struct SearchHighlightedText: View {
    let text: String
    let query: String
    let activeMatchIndex: Int?

    init(_ text: String, query: String, activeMatchIndex: Int? = nil) {
        self.text = text
        self.query = query
        self.activeMatchIndex = activeMatchIndex
    }

    var body: some View {
        Text(MeetingSearchHighlighting.apply(
            to: AttributedString(text),
            query: query,
            activeMatchIndex: activeMatchIndex))
    }
}

private enum MeetingSearchHighlighting {
    static func apply(
        to attributedText: AttributedString,
        query: String,
        activeMatchIndex: Int?
    ) -> AttributedString {
        var result = attributedText
        let plainText = String(result.characters)
        for (index, range) in MeetingPageSearch.ranges(
            in: plainText,
            query: query).enumerated() {
            guard let lowerBound = AttributedString.Index(range.lowerBound, within: result),
                  let upperBound = AttributedString.Index(range.upperBound, within: result) else {
                continue
            }
            result[lowerBound..<upperBound].backgroundColor = index == activeMatchIndex
                ? Color.orange.opacity(0.58)
                : Color.yellow.opacity(0.34)
        }
        return result
    }
}

/// Minimal line-based Markdown renderer — headings, bullets, checkboxes,
/// ordered lists, blockquotes, and horizontal rules, with inline
/// bold/italic/code via AttributedString. Enough for summary.md.
struct MarkdownText: View {
    enum Style {
        case standard
        case editorial
    }

    let text: String
    let style: Style

    init(_ text: String, style: Style = .standard) {
        self.text = text
        self.style = style
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .editorial ? 8 : 7) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                render(line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func render(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 2)
        } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            Divider().padding(.vertical, 4)
        } else if trimmed.hasPrefix("### ") {
            inline(String(trimmed.dropFirst(4)))
                .font(style == .editorial ? WorkspaceTypography.editorialBodyEmphasis : .headline)
                .padding(.top, 4)
        } else if trimmed.hasPrefix("## ") {
            inline(String(trimmed.dropFirst(3)))
                .font(style == .editorial ? WorkspaceTypography.editorialSectionTitle : .title3.bold())
                .padding(.top, 8)
        } else if trimmed.hasPrefix("# ") {
            inline(String(trimmed.dropFirst(2)))
                .font(style == .editorial ? WorkspaceTypography.conversationTitle : .title2.bold())
        } else if trimmed.hasPrefix("- [ ] ") || trimmed.hasPrefix("- [x] ") {
            HStack(alignment: .top, spacing: style == .editorial ? 8 : 6) {
                Image(systemName: trimmed.hasPrefix("- [x]") ? "checkmark.square" : "square")
                    .font(.system(size: style == .editorial ? 13 : 12)).padding(.top, 2)
                inline(String(trimmed.dropFirst(6)))
            }
            .font(baseFont)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .top, spacing: style == .editorial ? 8 : 6) {
                Text("•")
                inline(String(trimmed.dropFirst(2)))
            }
            .font(baseFont)
        } else if let ordered = Self.orderedListItem(trimmed) {
            HStack(alignment: .top, spacing: 6) {
                Text("\(ordered.number).").font(baseFont.monospacedDigit())
                inline(ordered.rest)
            }
            .font(baseFont)
        } else if trimmed.hasPrefix("> ") {
            HStack(alignment: .top, spacing: 8) {
                // A thin accent rule reads as a quote bar without a custom shape.
                Rectangle().fill(.tint.opacity(0.6)).frame(width: 2)
                inline(String(trimmed.dropFirst(2)))
                    .italic().foregroundStyle(.secondary)
            }
            .font(baseFont)
        } else {
            inline(trimmed)
                .font(baseFont)
                .lineSpacing(style == .editorial ? 3 : 0)
        }
    }

    private var baseFont: Font {
        style == .editorial ? WorkspaceTypography.editorialBody : .body
    }

    /// Matches "1. text", "12. text" — returns the number and the remainder.
    private static func orderedListItem(_ trimmed: String) -> (number: Int, rest: String)? {
        guard let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber),
              let number = Int(trimmed[..<dot]),
              trimmed.index(after: dot) < trimmed.endIndex,
              trimmed[trimmed.index(after: dot)] == " " else { return nil }
        let rest = String(trimmed[trimmed.index(dot, offsetBy: 2)...])
        return (number, rest)
    }

    private func inline(_ s: String) -> Text {
        var remainder = s[...]
        var rendered = Text("")

        while let open = remainder.firstIndex(of: "[") {
            let afterOpen = remainder.index(after: open)
            guard let close = remainder[afterOpen...].firstIndex(of: "]"),
                  Int(remainder[afterOpen..<close]) != nil else { break }

            rendered = rendered + inlineMarkdown(String(remainder[..<open]))
            rendered = rendered + Text(String(remainder[open...close]))
                .font(WorkspaceTypography.metadataEmphasis)
                .foregroundColor(Brand.teal)
            remainder = remainder[remainder.index(after: close)...]
        }

        return rendered + inlineMarkdown(String(remainder))
    }

    private func inlineMarkdown(_ source: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(source)
    }
}
