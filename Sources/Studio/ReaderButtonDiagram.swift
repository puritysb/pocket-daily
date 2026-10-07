import SwiftUI

/// Physical locations are in the chassis' portrait position. Rotation affects
/// the shown chassis; firmware page actions come from ReaderPreferences.
struct ReaderButtonLayout: Equatable {
    let firstKey: String
    let secondKey: String
    let frontControls: String
    let powerKey: String
    /// Physical panel coordinates audited in firmware HomeDrawing.cpp.
    let firstKeyPanelY: Int
    let secondKeyPanelY: Int
    let panelHeight: Int

    init(hardware: PocketHardware) {
        firstKeyPanelY = hardware == .x3 ? 194 : 385
        secondKeyPanelY = hardware == .x3 ? 194 : 465
        panelHeight = hardware == .x3 ? 792 : 800
        firstKey = hardware == .x3 ? "Left edge" : "Upper right-edge key"
        secondKey = hardware == .x3 ? "Right edge" : "Lower right-edge key"
        frontControls = hardware == .x3 ? "Two front rocker controls" : "Four front keys"
        powerKey = hardware == .x3 ? "Top power switch" : "Upper-right power switch"
    }
}

struct ReaderButtonDiagram: View {
    let hardware: PocketHardware
    let preferences: ReaderPreferences

    private var angle: Double {
        switch preferences.orientation ?? .portrait {
        case .portrait: 0
        case .landscape: -90
        case .inverted: 180
        case .landscapeReversed: 90
        }
    }

    var body: some View {
        let layout = ReaderButtonLayout(hardware: hardware)
        let actions = preferences.sideButtonActions
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(PocketPalette.deviceTop)
                    .frame(width: 122, height: 174)
                RoundedRectangle(cornerRadius: 3).fill(Color.white)
                    .frame(width: 102, height: 130).offset(y: -10)
                Text("Aa").font(.title2).foregroundStyle(.black)
                    .rotationEffect(.degrees(-angle)).offset(y: -10)
                key(actions.first).offset(x: hardware == .x3 ? -70 : 70, y: panelY(layout.firstKeyPanelY, height: layout.panelHeight))
                key(actions.second).offset(x: 70, y: panelY(layout.secondKeyPanelY, height: layout.panelHeight))
                Capsule().fill(Color.secondary).frame(width: hardware == .x3 ? 18 : 6, height: hardware == .x3 ? 5 : 18)
                    .offset(x: hardware == .x3 ? -51 + 102 * 473.0 / 528 : 64,
                            y: hardware == .x3 ? -88 : panelY(74, height: 800))
                HStack(spacing: 5) {
                    ForEach(0..<(hardware == .x3 ? 2 : 4), id: \.self) { _ in
                        Capsule().fill(Color.secondary).frame(width: hardware == .x3 ? 35 : 16, height: 8)
                    }
                }.offset(y: 69)
            }
            .rotationEffect(.degrees(angle))
            .frame(width: 280, height: 190)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(hardware.rawValue) buttons, \(preferences.orientation?.title ?? "Portrait")")
            .accessibilityValue("\(layout.firstKey): \(actions.first). \(layout.secondKey): \(actions.second). \(layout.frontControls). \(layout.powerKey).")
            .accessibilityIdentifier("reader-button-diagram")

        }
    }

    private func panelY(_ coordinate: Int, height: Int) -> CGFloat {
        // White panel spans y=-75...55 in this compact chassis diagram.
        -75 + 130 * CGFloat(coordinate) / CGFloat(height)
    }

    private func key(_ action: String) -> some View {
        Text(action == "Previous page" ? "Previous" : action == "Next page" ? "Next" : "Off")
            .font(.caption.weight(.bold))
            .foregroundStyle(.primary)
            .frame(minWidth: 65, minHeight: 24)
            .background(PocketPalette.panel, in: Capsule())
            .rotationEffect(.degrees(-angle))
    }
}
