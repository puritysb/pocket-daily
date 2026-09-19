import SwiftUI

/// Live Studio M3: a minimal theme-pack editor. Values layer over the
/// reader's selected theme; Apply ships a `.uipack` and asks the reader to
/// re-render, and the live frame (M2) shows the result on the canvas.
struct ThemePackInspector: View {
    @ObservedObject var model: PocketModel

    @State private var headerHeight = 44
    @State private var listRowHeight = 56
    @State private var menuRowHeight = 60
    @State private var menuSpacing = 8
    @State private var tabBarHeight = 40
    @State private var contentSidePadding = 20
    @State private var popupCornerRadius = 8
    @State private var popupTextBold = true

    private var packCapable: Bool { model.readerStatus?.liveStudio?.uiPacks == true }

    private var overrides: [String: Int] {
        [
            "headerHeight": headerHeight,
            "listRowHeight": listRowHeight,
            "menuRowHeight": menuRowHeight,
            "menuSpacing": menuSpacing,
            "tabBarHeight": tabBarHeight,
            "contentSidePadding": contentSidePadding,
            "popupCornerRadius": popupCornerRadius,
            "popupTextBold": popupTextBold ? 1 : 0,
        ]
    }

    var body: some View {
        InspectorCard(title: "THEME PACK", symbol: "paintpalette") {
            if !packCapable {
                Text("Connect to a reader with live-studio firmware to compose theme packs.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Stepper("Header \(headerHeight)", value: $headerHeight, in: 20...120)
                Stepper("List rows \(listRowHeight)", value: $listRowHeight, in: 30...120)
                Stepper("Menu rows \(menuRowHeight)", value: $menuRowHeight, in: 30...120)
                Stepper("Menu spacing \(menuSpacing)", value: $menuSpacing, in: 0...32)
                Stepper("Tab bar \(tabBarHeight)", value: $tabBarHeight, in: 20...80)
                Stepper("Side padding \(contentSidePadding)", value: $contentSidePadding, in: 0...64)
                Stepper("Popup radius \(popupCornerRadius)", value: $popupCornerRadius, in: 0...32)
                Toggle("Bold popup text", isOn: $popupTextBold)
                if let pack = model.readerStatus?.liveStudio?.activePack {
                    Text("Active on reader: \(pack)\(model.readerStatus?.liveStudio?.activePackVersion.map { " v\($0)" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Apply live") { model.applyThemePack(overrides) }
                        .buttonStyle(.borderedProminent).disabled(model.isWorking || model.isDemoMode)
                    Button("Revert") { model.revertThemePack() }
                        .buttonStyle(.bordered).disabled(model.isWorking || model.isDemoMode)
                }
                Text("Applies as a data pack; the reader re-renders and the frame updates. Flashing is never involved.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
