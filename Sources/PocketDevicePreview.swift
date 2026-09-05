import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct PocketDevicePreview: View {
    let hardware: PocketHardware
    let status: CrossPointStatus?
    let screenImageData: Data?

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width, proxy.size.height * hardware.chassisAspect)
            let height = width / hardware.chassisAspect

            ZStack {
                RoundedRectangle(cornerRadius: width * 0.062)
                    .fill(
                        LinearGradient(
                            colors: [PocketPalette.deviceTop, PocketPalette.deviceBottom],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: PocketPalette.ink.opacity(0.2), radius: 18, y: 10)
                RoundedRectangle(cornerRadius: width * 0.046)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    .padding(width * 0.018)

                VStack(spacing: width * 0.022) {
                    HStack {
                        Label(hardware.profileName, systemImage: "rectangle.portrait")
                            .font(.system(size: width * 0.028, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.72))
                        Spacer()
                        Circle()
                            .fill(status == nil ? Color.white.opacity(0.25) : PocketPalette.signal)
                            .frame(width: width * 0.018)
                    }
                    .padding(.horizontal, width * 0.08)

                    EInkSurface(hardware: hardware, status: status, screenImageData: screenImageData)
                        .clipShape(RoundedRectangle(cornerRadius: width * 0.012))
                        .padding(.horizontal, width * 0.067)

                    frontControls(width: width)
                        .frame(height: width * (hardware == .x3 ? 0.105 : 0.095))

                    HStack(spacing: width * 0.018) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(PocketPalette.accent)
                            .frame(width: width * 0.035, height: width * 0.009)
                        Text("POCKET DAILY")
                            .font(.system(size: width * 0.024, weight: .semibold, design: .rounded))
                            .tracking(width * 0.002)
                            .foregroundStyle(Color.white.opacity(0.62))
                    }
                        .padding(.bottom, width * 0.026)
                }
                .padding(.top, width * 0.038)

                chassisEdgeButtons(width: width, height: height)
            }
            .frame(width: width, height: height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(hardware.chassisAspect, contentMode: .fit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            screenImageData == nil
                ? "Pocket Daily \(hardware.rawValue) hardware profile. No reader frame is available."
                : "Pocket Daily \(hardware.rawValue) with the exact reader frame captured before Nearby Sync."
        )
    }

    @ViewBuilder
    private func frontControls(width: CGFloat) -> some View {
        if hardware == .x3 {
            // X3: two wide rocker controls. Each half is a separate raw input,
            // matching firmware centers 91/207 and 321/437 in 528px portrait space.
            HStack(spacing: width * 0.09) {
                rocker(width: width)
                rocker(width: width)
            }
            .padding(.horizontal, width * 0.105)
        } else {
            // X4: four independent front keys at x=78/183/298/403 in the
            // 480px portrait chassis coordinate system.
            HStack(spacing: width * 0.065) {
                ForEach(0 ..< 4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: width * 0.016)
                        .fill(Color.white.opacity(0.055))
                        .overlay { RoundedRectangle(cornerRadius: width * 0.016).stroke(Color.white.opacity(0.16)) }
                }
            }
            .padding(.horizontal, width * 0.09)
        }
    }

    private func rocker(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: width * 0.018)
            .fill(Color.white.opacity(0.05))
            .overlay {
                ZStack {
                    RoundedRectangle(cornerRadius: width * 0.018).stroke(Color.white.opacity(0.16))
                    Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1)
                }
            }
    }

    @ViewBuilder
    private func chassisEdgeButtons(width: CGFloat, height: CGFloat) -> some View {
        if hardware == .x3 {
            // Opposed page keys share y=194; power sits on the top edge at x=473.
            edgeKey(width: width, long: true)
                .position(x: -width * 0.006, y: edgeY(194, screenHeight: 792, bodyHeight: height))
            edgeKey(width: width, long: true)
                .position(x: width * 1.006, y: edgeY(194, screenHeight: 792, bodyHeight: height))
            topKey(width: width)
                .position(x: width * 0.865, y: 0)
        } else {
            // X4 power/page stack: power y=74, previous y=385, next y=465,
            // all on the right edge of the portrait chassis.
            edgeKey(width: width, long: false)
                .position(x: width * 1.006, y: edgeY(74, screenHeight: 800, bodyHeight: height))
            edgeKey(width: width, long: true)
                .position(x: width * 1.006, y: edgeY(385, screenHeight: 800, bodyHeight: height))
            edgeKey(width: width, long: true)
                .position(x: width * 1.006, y: edgeY(465, screenHeight: 800, bodyHeight: height))
        }
    }

    private func edgeY(_ panelY: CGFloat, screenHeight: CGFloat, bodyHeight: CGFloat) -> CGFloat {
        let screenTop = bodyHeight * 0.075
        let screenRegion = bodyHeight * 0.76
        return screenTop + (panelY / screenHeight) * screenRegion
    }

    private func edgeKey(width: CGFloat, long: Bool) -> some View {
        Capsule()
            .fill(Color.black)
            .frame(width: width * 0.019, height: width * (long ? 0.115 : 0.075))
            .overlay { Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5) }
    }

    private func topKey(width: CGFloat) -> some View {
        Capsule()
            .fill(Color.black)
            .frame(width: width * 0.095, height: width * 0.018)
            .overlay { Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.5) }
    }
}

private struct EInkSurface: View {
    let hardware: PocketHardware
    let status: CrossPointStatus?
    let screenImageData: Data?

    var body: some View {
        ZStack {
            Color(red: 0.93, green: 0.92, blue: 0.87)
            if let screenImage {
                screenImage
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                VStack(spacing: 0) {
                    HStack { Text("POCKET DAILY"); Spacer(); Text(hardware.rawValue) }
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .padding(.horizontal, 16).padding(.vertical, 13)
                    Rectangle().fill(Color.black.opacity(0.75)).frame(height: 1)
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack { Text("LOCAL COMPANION"); Spacer(); Text(status?.mode ?? "PROFILE") }
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 15).padding(.vertical, 10)
                        .overlay(alignment: .top) { Rectangle().fill(Color.black.opacity(0.65)).frame(height: 1) }
                }
                .foregroundStyle(Color.black.opacity(0.86))
            }
        }
        .aspectRatio(hardware.screenAspect, contentMode: .fit)
    }

    private var screenImage: Image? {
        guard let screenImageData else { return nil }
#if os(macOS)
        guard let image = NSImage(data: screenImageData) else { return nil }
        return Image(nsImage: image)
#else
        guard let image = UIImage(data: screenImageData) else { return nil }
        return Image(uiImage: image)
#endif
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 15) {
            Spacer()
            Image(systemName: "rectangle.portrait")
                .font(.system(size: hardware == .x3 ? 82 : 74, weight: .ultraLight))
            Text(hardware.rawValue)
                .font(.system(size: hardware == .x3 ? 40 : 36, weight: .medium, design: .rounded))
            Text(status == nil || status?.mode == "DEMO" ? "HARDWARE PROFILE" : "SCREEN PREVIEW UNAVAILABLE")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .tracking(1.1)
                .multilineTextAlignment(.center)
            Rectangle().frame(width: 116, height: 1)
            Text(fallbackDetail)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            Spacer()
        }
    }

    private var fallbackDetail: String {
        if status != nil, status?.mode != "DEMO" {
            return "Open Nearby Sync from Pocket Daily\nto capture the exact frame"
        }
        return "\(hardware.screenWidth) × \(hardware.screenHeight) e-paper\n\(hardware.controlSummary)"
    }
}
