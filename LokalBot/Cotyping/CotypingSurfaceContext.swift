import Foundation

/// "What am I writing in?" context that conditions cotyping's suggestions on the
/// focused app + window. Ported from Cotabby's `AppSurfaceClassifier` +
/// `SurfaceContextComposer`: the window title carries the email subject, doc
/// name, chat channel, or page title — the single strongest situational cue a
/// small local model gets. Suppressed for code editors and terminals, where app
/// metadata biases the model toward code/numbers over prose.
///
/// Pure value logic — no AX, no I/O — so it is unit-testable.

/// The coarse kind of writing surface the focused app presents.
enum CotypingSurfaceClass: Equatable, Sendable {
    case codeEditor, terminal, email, chat, browser, other
}

/// Bundle-identifier → surface classification. Prefix-matched, case-folded.
enum CotypingSurfaceClassifier {
    static func classify(bundleID: String?) -> CotypingSurfaceClass {
        guard let raw = bundleID?.lowercased(), !raw.isEmpty else { return .other }
        if terminalPrefixes.contains(where: raw.hasPrefix) { return .terminal }
        if codeEditorPrefixes.contains(where: raw.hasPrefix) { return .codeEditor }
        if emailPrefixes.contains(where: raw.hasPrefix) { return .email }
        if chatPrefixes.contains(where: raw.hasPrefix) { return .chat }
        if browserPrefixes.contains(where: raw.hasPrefix) { return .browser }
        return .other
    }

    static let terminalPrefixes = [
        "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.",
        "io.alacritty", "net.kovidgoyal.kitty", "co.zeit.hyper", "com.github.wez.wezterm",
    ]
    static let codeEditorPrefixes = [
        "com.apple.dt.xcode", "com.microsoft.vscode", "com.jetbrains.",
        "com.sublimetext.", "com.panic.nova", "dev.zed.", "com.zed.",
    ]
    static let emailPrefixes = [
        "com.apple.mail", "com.readdle.smartemail", "com.airmailapp.airmail",
        "com.microsoft.outlook", "com.superhuman.",
    ]
    static let chatPrefixes = [
        "com.tinyspeck.slackmacgap", "com.microsoft.teams", "com.hnc.discord",
        "com.apple.mobilesms", "ru.keepcoder.telegram", "net.whatsapp.whatsapp",
    ]
    static let browserPrefixes = [
        "com.apple.safari", "com.google.chrome", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.browser", "company.thebrowser.browser",
        "com.operasoftware.opera", "com.vivaldi.vivaldi",
    ]
}

/// A sanitized surface description ready to condition a prompt.
struct CotypingSurfaceContext: Equatable, Sendable {
    let surfaceClass: CotypingSurfaceClass
    let applicationName: String
    let windowTitle: String?
    let fieldPlaceholder: String?
}

enum CotypingSurfaceComposer {
    private static let maxTitleLength = 80
    private static let maxPlaceholderLength = 60

    /// Builds a surface description, or `nil` when there's nothing useful (or
    /// safe) to say — code editors, terminals, and bare generic apps.
    static func compose(
        appName: String, bundleID: String?, windowTitle: String?, fieldPlaceholder: String?
    ) -> CotypingSurfaceContext? {
        let surfaceClass = CotypingSurfaceClassifier.classify(bundleID: bundleID)
        switch surfaceClass {
        case .codeEditor, .terminal:
            return nil
        case .email, .chat, .browser, .other:
            break
        }
        let cleanedApp = collapseWhitespace(appName)
        guard !cleanedApp.isEmpty else { return nil }
        let rawTitle = sanitizedTitle(windowTitle, applicationName: cleanedApp)
        let title = rawTitle.flatMap { isGenericDocumentTitle($0) ? nil : $0 }
        let placeholder = sanitizedPlaceholder(fieldPlaceholder)
        // A generic app with no title or placeholder has nothing useful to add.
        if surfaceClass == .other, title == nil, placeholder == nil { return nil }
        return CotypingSurfaceContext(
            surfaceClass: surfaceClass, applicationName: cleanedApp,
            windowTitle: title, fieldPlaceholder: placeholder)
    }

    /// Declarative conditioning lines for the prompt preface (a continuer
    /// conditions on description, it doesn't obey commands).
    static func prefaceLines(for surface: CotypingSurfaceContext) -> [String] {
        var lines: [String] = []
        switch surface.surfaceClass {
        case .email: lines.append("An email being written in \(surface.applicationName).")
        case .chat: lines.append("A chat message being typed in \(surface.applicationName).")
        case .browser, .other: lines.append("Text being typed in \(surface.applicationName).")
        case .codeEditor, .terminal: return []
        }
        if let title = surface.windowTitle { lines.append("The window is titled \"\(title)\".") }
        if let placeholder = surface.fieldPlaceholder {
            lines.append("The text field is labeled \"\(placeholder)\".")
        }
        return lines
    }

    // MARK: - Sanitization

    /// Strips the app-name suffix apps append (`Inbox - Gmail`, `Doc — Pages`),
    /// drops control chars and quotes (they'd corrupt the quoted line), caps length.
    static func sanitizedTitle(_ rawTitle: String?, applicationName: String) -> String? {
        guard var title = nonEmptyCleaned(rawTitle) else { return nil }
        for separator in [" - ", " — ", " – "] {
            let suffix = separator + applicationName
            if let range = title.range(of: suffix, options: [.caseInsensitive, .anchored, .backwards]) {
                title = String(title[..<range.lowerBound])
                break
            }
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return String(title.prefix(maxTitleLength))
    }

    private static func isGenericDocumentTitle(_ title: String) -> Bool {
        let folded = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if folded == "untitled" || folded == "new document" { return true }
        if folded.hasPrefix("untitled.") || folded.hasPrefix("untitled ") { return true }
        return false
    }

    private static func sanitizedPlaceholder(_ raw: String?) -> String? {
        guard let placeholder = nonEmptyCleaned(raw) else { return nil }
        return String(placeholder.prefix(maxPlaceholderLength))
    }

    private static func nonEmptyCleaned(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = collapseWhitespace(String(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != "\""
        }))
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
