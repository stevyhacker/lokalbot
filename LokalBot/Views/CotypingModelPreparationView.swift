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
            ModelPreparationView(
                presentation: presentation(for: status),
                style: compact ? .compact : .standard,
                action: action(for: status))
            if !CotypingModelPreparer.recommendedIsActive(settings: app.settings) {
                Text("This selects Gemma 4 · E4B and keeps inline suggestions separate from the model used for meetings and Ask.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func presentation(
        for status: CotypingModelPreparationStatus
    ) -> ModelPreparationPresentation {
        switch status {
        case .ready(let entry):
            return .init(
                state: .ready,
                title: "High-quality cotyping model",
                status: "\(entry.displayName) is ready.",
                actionTitle: isReadyAndActive(status) ? nil : "Use")
        case .downloading(let entry, let progress):
            return .init(
                state: .preparing,
                title: "Preparing cotyping model",
                status: "Downloading \(entry.displayName) — \(Int(progress * 100))%",
                progress: progress)
        case .failed(let entry, let message):
            return .init(
                state: .failed,
                title: "Cotyping model needs attention",
                status: "\(entry.displayName): \(message)",
                actionTitle: "Retry")
        case .missing(let entry):
            return .init(
                state: .waiting,
                title: "High-quality cotyping model",
                status: "\(entry.displayName) has not been downloaded yet.",
                actionTitle: "Prepare")
        case .unavailable:
            return .init(
                state: .failed,
                title: "Cotyping model unavailable",
                status: "The recommended model is not in this build.")
        }
    }

    private func action(for status: CotypingModelPreparationStatus) -> (() -> Void)? {
        guard !status.isDownloading, status != .unavailable, !isReadyAndActive(status) else {
            return nil
        }
        return { app.prepareRecommendedCotypingModel() }
    }

    private func isReadyAndActive(_ status: CotypingModelPreparationStatus) -> Bool {
        if case .ready = status {
            return CotypingModelPreparer.recommendedIsActive(settings: app.settings)
        }
        return false
    }

}
