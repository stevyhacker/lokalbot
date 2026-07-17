import SwiftUI

/// The default landing surface: one glanceable page composing today's
/// answers — what's capturing right now, what happened, where the time
/// went, and a way to ask about any of it. Today summarizes; the Timeline
/// stays the forensic, hour-indexed view of the same day.
struct TodayView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var model = CaptureModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Today")
        .task { model.reload(app: app) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Today")
                .font(.largeTitle.bold())
                .accessibilityIdentifier("today.header")
            Text(Date().formatted(date: .complete, time: .omitted))
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
