import SwiftUI

struct ContentCardPreview: View {
    let draft: ContentDraft
    let hardware: PocketHardware
    var style: PreviewStyle = .reference
    @StateObject private var preview = ContentPreviewModel()
    @State private var selectedID = ""
    @State private var orientation = HostRendererBridge.Orientation.portrait
    @State private var showingNotices = false
    @State private var notices = "Loading font notices…"

    private var card: ContentCard? { draft.cards.first { $0.id == selectedID } ?? draft.cards.first }
    private var request: ContentPreviewRequest {
        .init(card: card, image: card.flatMap { draft.images[$0.imagePath] }, hardware: hardware, orientation: orientation,
              style: style)
    }

    var body: some View {
        Section("Offline reader preview") {
            if draft.cards.count > 1 {
                Picker("Preview card", selection: Binding(get: { card?.id ?? "" }, set: { selectedID = $0 })) {
                    ForEach(draft.cards, id: \.id) { card in
                        Text(card.title.isEmpty ? "Untitled card" : card.title).tag(card.id)
                    }
                }
            }
            Picker("Orientation", selection: $orientation) {
                Text("Portrait").tag(HostRendererBridge.Orientation.portrait)
                Text("Clockwise").tag(HostRendererBridge.Orientation.clockwise)
                Text("Inverted").tag(HostRendererBridge.Orientation.inverted)
                Text("Counterclockwise").tag(HostRendererBridge.Orientation.counterclockwise)
            }
            .accessibilityIdentifier("content-preview-orientation")
            if let image = preview.image {
                Image(decorative: image, scale: 1).resizable().interpolation(.none)
                    .scaledToFit().frame(maxWidth: 400, maxHeight: 360)
                    .background(Color.white).border(Color.secondary.opacity(0.4))
                    .accessibilityHidden(false)
                    .accessibilityLabel("Offline reader preview, \(image.width) by \(image.height) pixels")
                    .accessibilityIdentifier("content-reader-preview")
            } else if let error = preview.error {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("content-preview-error")
            } else if preview.isRendering {
                ProgressView("Rendering reader preview…")
            }
            Text("\(hardware.rawValue) · PocketSansWorld 12 px · \(style.caption)")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Preview font notices") { showingNotices = true }
                .font(.caption)
        }
        .task(id: request) { await preview.update(request) }
        .onDisappear { preview.cancel() }
        .sheet(isPresented: $showingNotices) {
            NavigationStack {
                ScrollView { Text(notices).font(.caption).textSelection(.enabled).padding() }
                    .navigationTitle("Preview font notices")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingNotices = false } } }
                    .task {
                        do { notices = try await PreviewFontStore.shared.notices() }
                        catch { notices = "Font notices are unavailable: \(error.localizedDescription)" }
                    }
            }.frame(minWidth: 320, minHeight: 360)
        }
    }
}
