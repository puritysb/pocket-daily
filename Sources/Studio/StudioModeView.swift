import SwiftUI

/// Mac studio: Cards (content sent to the Study deck) or Home & Sleep (the
/// Pocket Daily profile). Both keep their unsent edits while switching.
struct StudioModeView: View {
    enum Mode: String, CaseIterable { case cards = "Cards", homeAndSleep = "Home & Sleep" }

    @ObservedObject var model: PocketModel
    @State private var mode: Mode
    @StateObject private var profileEditor = ProfileEditorState()

    init(model: PocketModel, initialMode: Mode = .cards) {
        self.model = model
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Studio", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("studio-mode")
            switch mode {
            case .cards: ContentStudioView(model: model)
            case .homeAndSleep: ProfileStudioView(model: model, editor: profileEditor)
            }
        }
    }
}
