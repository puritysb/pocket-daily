import SwiftUI

struct PocketDevicePreview: View {
    let hardware: PocketHardware
    let section: PocketSection
    let status: CrossPointStatus?

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width, proxy.size.height * hardware.chassisAspect)
            let height = width / hardware.chassisAspect

            ZStack {
                RoundedRectangle(cornerRadius: width * 0.062)
                    .fill(Color(red: 0.09, green: 0.09, blue: 0.085))
                    .shadow(color: .black.opacity(0.24), radius: 16, y: 8)
                RoundedRectangle(cornerRadius: width * 0.046)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    .padding(width * 0.018)

                VStack(spacing: width * 0.022) {
                    HStack {
                        Text(hardware.rawValue)
                            .font(.system(size: width * 0.034, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.55))
                        Spacer()
                        Circle()
                            .fill(status == nil ? Color.white.opacity(0.25) : Color.green.opacity(0.8))
                            .frame(width: width * 0.018)
                    }
                    .padding(.horizontal, width * 0.08)

                    EInkSurface(hardware: hardware, section: section, status: status)
                        .clipShape(RoundedRectangle(cornerRadius: width * 0.012))
                        .padding(.horizontal, width * 0.067)

                    frontControls(width: width)
                        .frame(height: width * (hardware == .x3 ? 0.105 : 0.095))

                    Text("Xteink")
                        .font(.system(size: width * 0.028, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.52))
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
        .accessibilityLabel("\(hardware.displayName) device preview")
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
    let section: PocketSection
    let status: CrossPointStatus?

    var body: some View {
        ZStack {
            Color(red: 0.93, green: 0.92, blue: 0.87)
            VStack(spacing: 0) {
                HStack { Text(header); Spacer(); Text("08.29") }
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .padding(.horizontal, 16).padding(.vertical, 13)
                Rectangle().fill(Color.black.opacity(0.75)).frame(height: 1)
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack { Text(footerLeft); Spacer(); Text(status?.mode ?? "PREVIEW") }
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 15).padding(.vertical, 10)
                    .overlay(alignment: .top) { Rectangle().fill(Color.black.opacity(0.65)).frame(height: 1) }
            }
            .foregroundStyle(Color.black.opacity(0.86))
        }
        .aspectRatio(hardware.screenAspect, contentMode: .fit)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .today:
            VStack(spacing: 14) {
                Spacer()
                Text("継").font(.system(size: hardware == .x3 ? 116 : 106, weight: .regular, design: .serif)).minimumScaleFactor(0.7)
                Text("つぐ").font(.system(size: 27, design: .serif))
                Rectangle().frame(width: 128, height: 1)
                Text("이어가다, 계승하다\n잇다, 계속하다")
                    .font(.system(size: 17, design: .serif)).multilineTextAlignment(.center).lineSpacing(5)
                Spacer()
                Text("오늘 한 번 보고 · 저녁에 다시")
                    .font(.system(size: 10, weight: .medium)).padding(.bottom, 12)
            }
        case .japanese:
            VStack(spacing: 15) {
                Spacer()
                Text("継ぐ").font(.system(size: hardware == .x3 ? 66 : 60, design: .serif))
                Text("다음 읽기를 고르세요").font(.system(size: 13, weight: .medium))
                HStack(spacing: 8) { answer("つぐ", selected: true); answer("そそぐ", selected: false) }
                HStack(spacing: 8) { answer("かせぐ", selected: false); answer("つなぐ", selected: false) }
                Spacer()
                Text("JLPT N3 · REVIEW 12")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced)).padding(.bottom, 12)
            }
            .padding(.horizontal, 16)
        case .books:
            VStack(alignment: .leading, spacing: 14) {
                Text("이어 읽기").font(.system(size: 14, weight: .semibold))
                Text("吾輩は猫である").font(.system(size: hardware == .x3 ? 33 : 29, design: .serif))
                Text("夏目漱石").font(.system(size: 15, design: .serif))
                Rectangle().frame(height: 1)
                Text("吾輩は猫である。名前はまだ無い。どこで生れたか頓と見当がつかぬ。")
                    .font(.system(size: 18, design: .serif)).lineSpacing(8)
                Spacer()
                Text("42% · 18 min left").font(.system(size: 10, design: .monospaced))
            }
            .padding(22)
        case .firmware:
            VStack(spacing: 18) {
                Spacer()
                Image(systemName: "arrow.down.circle").font(.system(size: 58, weight: .light))
                Text("Firmware ready").font(.system(size: 22, weight: .semibold))
                Text("The universal file is staged on SD.\nInstallation starts only on \(hardware.rawValue).")
                    .font(.system(size: 13)).multilineTextAlignment(.center).lineSpacing(4)
                Spacer()
            }
        }
    }

    private func answer(_ text: String, selected: Bool) -> some View {
        Text(text)
            .font(.system(size: 15, weight: selected ? .bold : .regular, design: .serif))
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(selected ? Color.black.opacity(0.12) : Color.clear)
            .overlay { RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.7)) }
    }

    private var header: String {
        switch section { case .today: "今日の漢字"; case .japanese: "N3 REVIEW"; case .books: "READING"; case .firmware: "UPDATE" }
    }
    private var footerLeft: String {
        switch section { case .today: "12 / 20"; case .japanese: "3 / 10"; case .books: "PAGE 84"; case .firmware: "SAFE STAGING" }
    }
}
