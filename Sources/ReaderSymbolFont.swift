import SwiftUI

/// The reader's glyph-fallback font (emoji and symbols), bundled with the app
/// and sent like any other prepared file. Firmware discovers it at boot under
/// `/.fonts/PocketSymbols/` (sibling assets/fonts/PocketSymbols/README.md).
enum ReaderSymbolFont {
    static let fileName = "PocketSymbols_12.cpfont"
    static let byteCount = 413_062

    static var bundledURL: URL? {
        Bundle.main.url(forResource: "ReaderFonts", withExtension: nil)?
            .appendingPathComponent("PocketSymbols/\(fileName)")
    }
}

struct ReaderSymbolFontOffer: View {
    @ObservedObject var model: PocketModel
    @AppStorage("readerSymbolFont.hidden") private var hidden = false

    private var isPrepared: Bool {
        model.preparedTransfers.contains { $0.filename == ReaderSymbolFont.fileName }
    }

    var body: some View {
        if !hidden, ReaderSymbolFont.bundledURL != nil {
            VStack(alignment: .leading, spacing: 8) {
                Label("Emoji and symbols on the reader", systemImage: "face.smiling")
                    .font(.callout.weight(.medium))
                Text("Books often use emoji, arrows or math symbols the reading font lacks. Send this free symbol font once (400 KB) and the reader draws them instead of blank marks, after it restarts.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(isPrepared ? "Ready to send" : "Prepare symbol font") { prepare() }
                        .disabled(isPrepared || !model.canPrepareFiles)
                        .accessibilityIdentifier("prepare-symbol-font")
                    Spacer()
                    Button("Hide") { hidden = true }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(PocketPalette.selection.opacity(0.5)))
        }
    }

    private func prepare() {
        guard let url = ReaderSymbolFont.bundledURL else { return }
        model.upload(url)
    }
}
