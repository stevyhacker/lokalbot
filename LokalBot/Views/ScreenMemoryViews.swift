import AppKit
import SwiftUI

/// Session-local cache for decrypted screen-memory pixels. The encrypted file
/// stays the source of truth; only decoded `NSImage`s are retained in memory.
private enum ScreenThumbnailCache {
    static let shared = NSCache<NSNumber, NSImage>()
}

/// A reusable private screenshot thumbnail. Pixel loading goes through
/// `ScreenshotService`, so views never learn or expose an encrypted file path.
struct ScreenThumbnailView: View {
    @EnvironmentObject private var app: AppState

    let snapshotID: Int64
    var height: CGFloat = 84
    var contentMode: ContentMode = .fill
    var cornerRadius: CGFloat = Brand.Radius.control

    @State private var image: NSImage?
    @State private var finishedLoading = false

    private var hasPixels: Bool {
        app.activityStore.screenshot(id: snapshotID)?.hasPixels ?? false
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.45))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if finishedLoading {
                VStack(spacing: 5) {
                    Image(systemName: hasPixels ? "rectangle.slash" : "text.viewfinder")
                        .font(.title3)
                    if !hasPixels, height >= 70 {
                        Text("Text context")
                            .font(.caption2.weight(.medium))
                    }
                }
                .foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityLabel(hasPixels ? "Captured screen" : "Captured text context")
        .task(id: snapshotID) { await load() }
    }

    private func load() async {
        image = nil
        finishedLoading = false
        let key = NSNumber(value: snapshotID)
        if let cached = ScreenThumbnailCache.shared.object(forKey: key) {
            image = cached
            finishedLoading = true
            return
        }
        guard hasPixels else {
            finishedLoading = true
            return
        }
        let data = await app.screenshots.decryptedData(for: snapshotID)
        guard !Task.isCancelled else { return }
        if let data, let decoded = NSImage(data: data) {
            ScreenThumbnailCache.shared.setObject(decoded, forKey: key)
            image = decoded
        }
        finishedLoading = true
    }
}

/// Screen result anatomy: optional pixels, app/window metadata, highlighted
/// captured-text excerpt, exact time, and a separate context-pin action.
struct ScreenSearchResultRow: View {
    let hit: ActivityStore.OCRHit
    let isPinned: Bool
    let open: () -> Void
    let togglePin: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: open) {
                HStack(alignment: .top, spacing: 10) {
                    ScreenThumbnailView(snapshotID: hit.snapshotID, height: 72)
                        .frame(width: 116)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Text(hit.app)
                                .font(.headline)
                                .lineLimit(1)
                            Text(hit.ts.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                        }
                        if !hit.windowTitle.isEmpty {
                            Text(hit.windowTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        highlightedSnippet
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open this moment in Timeline")

            Button(action: togglePin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(isPinned ? AnyShapeStyle(Brand.teal)
                                              : AnyShapeStyle(.secondary))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(isPinned ? "Remove from Ask context" : "Use as Ask context")
            .accessibilityLabel(isPinned ? "Unpin screen from context" : "Pin screen as context")
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("screen.hit.\(hit.snapshotID)")
    }

    private var highlightedSnippet: Text {
        SnippetHighlighter.segments(hit.snippet).reduce(Text("")) { text, segment in
            text + (segment.isMatch
                ? Text(segment.text).bold().foregroundStyle(.primary)
                : Text(segment.text))
        }
    }
}

/// One visual source card under an assistant answer. Missing/expired captures
/// remain identifiable instead of silently removing a citation from history.
struct ScreenCitationCard: View {
    @EnvironmentObject private var app: AppState
    let snapshotID: Int64

    var body: some View {
        if let screenshot = app.activityStore.screenshot(id: snapshotID) {
            Button {
                app.openScreenSnapshot(snapshotID)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    ScreenThumbnailView(snapshotID: snapshotID, height: 72)
                    HStack(spacing: 5) {
                        Image(systemName: "camera.viewfinder")
                        Text(screenshot.app).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(screenshot.ts.formatted(date: .omitted, time: .shortened))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(7)
                .frame(width: 184)
                .background(.quaternary.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: Brand.Radius.panel))
                .overlay {
                    RoundedRectangle(cornerRadius: Brand.Radius.panel)
                        .strokeBorder(.quaternary)
                }
            }
            .buttonStyle(.plain)
            .help("Open \(screenshot.app) at \(screenshot.ts.formatted(date: .abbreviated, time: .shortened))")
            .accessibilityIdentifier("chat.citation.screen.\(snapshotID)")
        } else {
            Label("Screen \(snapshotID) expired", systemImage: "rectangle.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .chipChrome()
                .accessibilityIdentifier("chat.citation.screen.missing.\(snapshotID)")
        }
    }
}
