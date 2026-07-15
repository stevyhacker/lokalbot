import AppKit
import SwiftUI

private final class ScreenThumbnailCacheEntry {
    let image: CGImage

    init(image: CGImage) {
        self.image = image
    }
}

/// Session-local cache for bounded, downsampled screen-memory pixels. The
/// encrypted file stays the source of truth and NSCache can evict under memory
/// pressure instead of retaining every full-resolution capture indefinitely.
private enum ScreenThumbnailCache {
    static let shared: NSCache<NSString, ScreenThumbnailCacheEntry> = {
        let cache = NSCache<NSString, ScreenThumbnailCacheEntry>()
        cache.countLimit = 160
        cache.totalCostLimit = 96 * 1_024 * 1_024
        return cache
    }()

    static func key(snapshotID: Int64, maxPixelSize: Int) -> NSString {
        "\(snapshotID)-\(maxPixelSize)" as NSString
    }
}

enum ScreenThumbnailSizing {
    static func maxPixelSize(forHeight height: CGFloat) -> Int {
        let requested = max(128, Int((height * 4).rounded(.up)))
        switch requested {
        case ...256: return 256
        case ...512: return 512
        case ...1_024: return 1_024
        default: return 1_600
        }
    }
}

/// A reusable private screenshot thumbnail. Pixel loading goes through
/// `ScreenshotService`, so views never learn or expose an encrypted file path.
struct ScreenThumbnailView: View {
    @EnvironmentObject private var app: AppState

    let snapshotID: Int64
    private let screenshot: ActivityStore.Screenshot?
    let height: CGFloat
    let contentMode: ContentMode
    let cornerRadius: CGFloat

    @State private var image: CGImage?
    @State private var resolvedHasPixels: Bool?
    @State private var finishedLoading = false

    init(
        snapshotID: Int64,
        height: CGFloat = 84,
        contentMode: ContentMode = .fill,
        cornerRadius: CGFloat = Brand.Radius.control
    ) {
        self.snapshotID = snapshotID
        self.screenshot = nil
        self.height = height
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
        _resolvedHasPixels = State(initialValue: nil)
    }

    init(
        screenshot: ActivityStore.Screenshot,
        height: CGFloat = 84,
        contentMode: ContentMode = .fill,
        cornerRadius: CGFloat = Brand.Radius.control
    ) {
        self.snapshotID = screenshot.id
        self.screenshot = screenshot
        self.height = height
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
        _resolvedHasPixels = State(initialValue: screenshot.hasPixels)
    }

    private var hasPixels: Bool {
        screenshot?.hasPixels ?? resolvedHasPixels ?? true
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.quaternary.opacity(0.45))
            if let image {
                Image(
                    image,
                    scale: 1,
                    orientation: .up,
                    label: Text(hasPixels ? "Captured screen" : "Captured text context"))
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(hasPixels ? "Captured screen" : "Captured text context")
        .task(id: snapshotID) { await load() }
    }

    private func load() async {
        image = nil
        finishedLoading = false
        let resolvedScreenshot = screenshot ?? app.activityStore.screenshot(id: snapshotID)
        resolvedHasPixels = resolvedScreenshot?.hasPixels ?? false
        guard let resolvedScreenshot, resolvedScreenshot.hasPixels else {
            finishedLoading = true
            return
        }

        let maxPixelSize = ScreenThumbnailSizing.maxPixelSize(forHeight: height)
        let key = ScreenThumbnailCache.key(
            snapshotID: resolvedScreenshot.id,
            maxPixelSize: maxPixelSize)
        if let cached = ScreenThumbnailCache.shared.object(forKey: key) {
            image = cached.image
            finishedLoading = true
            return
        }

        let thumbnail = await app.screenshots.decryptedThumbnail(
            for: resolvedScreenshot,
            maxPixelSize: maxPixelSize)
        guard !Task.isCancelled else { return }
        if let thumbnail {
            ScreenThumbnailCache.shared.setObject(
                ScreenThumbnailCacheEntry(image: thumbnail.image),
                forKey: key,
                cost: thumbnail.byteCost)
            image = thumbnail.image
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
                    ScreenThumbnailView(screenshot: screenshot, height: 72)
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
