import SwiftUI

/// The Type pillar — dictation and cotyping merged into one writing-tools
/// surface (spec §2.4), with a segmented control hosting both forms.
struct TypeView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Tool", selection: $app.typeTab) {
                    Text("Autocomplete").tag(AppState.TypeTab.cotyping)
                    Text("Dictation").tag(AppState.TypeTab.dictation)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                .accessibilityIdentifier("type.tab")
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)

            switch app.typeTab {
            case .dictation: DictationView(dictation: app.dictation)
            case .cotyping: AutocompleteExperienceView()
            }
        }
        .navigationTitle("Write")
    }
}
