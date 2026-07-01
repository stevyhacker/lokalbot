import SwiftUI

struct CotypingModelPreparationView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var downloads = ModelDownloadManager.shared

    var compact = false

    var body: some View {
        let status = CotypingModelPreparer.status(
            settings: app.settings,
            storage: app.storage,
            downloads: downloads)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: iconName(for: status))
                    .foregroundStyle(color(for: status))
                VStack(alignment: .leading, spacing: 1) {
                    Text("High-quality cotyping model")
                        .font(compact ? .caption : .callout)
                    Text(status.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if case .downloading(_, let progress) = status {
                    ProgressView(value: progress)
                        .frame(width: compact ? 58 : 80)
                }
                Button(actionTitle(for: status)) {
                    app.prepareRecommendedCotypingModel()
                }
                .controlSize(compact ? .mini : .small)
                .disabled(status.isDownloading || status == .unavailable || isReadyAndActive(status))
            }
            if !CotypingModelPreparer.recommendedIsActive(settings: app.settings) {
                Text("This switches cotyping to its own llama.cpp server and selects Gemma 4 E4B Q5 XL for high-quality suggestions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func actionTitle(for status: CotypingModelPreparationStatus) -> String {
        switch status {
        case .ready:
            CotypingModelPreparer.recommendedIsActive(settings: app.settings) ? "Ready" : "Use"
        case .downloading:
            "Downloading"
        case .failed:
            "Retry"
        case .missing:
            "Prepare"
        case .unavailable:
            "Unavailable"
        }
    }

    private func isReadyAndActive(_ status: CotypingModelPreparationStatus) -> Bool {
        if case .ready = status {
            return CotypingModelPreparer.recommendedIsActive(settings: app.settings)
        }
        return false
    }

    private func iconName(for status: CotypingModelPreparationStatus) -> String {
        switch status {
        case .ready: "checkmark.circle.fill"
        case .downloading: "arrow.down.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .missing: "arrow.down.circle"
        case .unavailable: "xmark.circle"
        }
    }

    private func color(for status: CotypingModelPreparationStatus) -> Color {
        switch status {
        case .ready: .green
        case .downloading: .accentColor
        case .failed, .missing: .orange
        case .unavailable: .secondary
        }
    }
}
