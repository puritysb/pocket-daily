import Foundation

enum PocketHardware: String, CaseIterable, Identifiable, Sendable {
    case x3 = "X3"
    case x4 = "X4"

    var id: Self { self }
    var displayName: String { "Xteink \(rawValue)" }

    var screenWidth: Int {
        switch self { case .x3: 528; case .x4: 480 }
    }

    var screenHeight: Int {
        switch self { case .x3: 792; case .x4: 800 }
    }

    var screenAspect: CGFloat { CGFloat(screenWidth) / CGFloat(screenHeight) }

    /// Chassis aspect used only by the app preview. X4 reserves more lower
    /// bezel for four discrete front keys; X3 uses two wider rocker controls.
    var chassisAspect: CGFloat {
        switch self { case .x3: 0.60; case .x4: 0.55 }
    }

    var controlSummary: String {
        switch self {
        case .x3: "top power · opposed page keys · two front rockers"
        case .x4: "right-side power/page stack · four front keys"
        }
    }

    init?(deviceName: String) {
        let normalized = deviceName.uppercased().replacingOccurrences(of: "XTEINK", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(rawValue: normalized)
    }
}
