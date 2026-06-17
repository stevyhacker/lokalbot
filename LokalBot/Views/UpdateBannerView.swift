import SwiftUI

/// Quiet banner shown when the opt-in once-a-day background check finds a
/// newer release. Manual checks use an `NSAlert` instead.
struct UpdateBannerView: View {
    let versionTitle: String
    let onDownload: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("Update available").font(.callout).bold().lineLimit(1)
                Text("\(versionTitle) is ready to download")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)

            Button("Download", action: onDownload).buttonStyle(.borderedProminent)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.tint.opacity(0.35)))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        .frame(maxWidth: 480)
    }
}
