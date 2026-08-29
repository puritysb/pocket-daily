import SwiftUI

struct X3DevicePreview: View {
    let section: PocketSection
    let status: CrossPointStatus?

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width, proxy.size.height * 0.67)
            let height = width * 1.52

            ZStack {
                RoundedRectangle(cornerRadius: width * 0.065)
                    .fill(Color(red: 0.09, green: 0.09, blue: 0.085))
                    .shadow(color: .black.opacity(0.24), radius: 16, y: 8)
                RoundedRectangle(cornerRadius: width * 0.045)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    .padding(width * 0.018)
                VStack(spacing: width * 0.025) {
                    HStack {
                        Text("X3")
                            .font(.system(size: width * 0.035, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.55))
                        Spacer()
                        Circle()
                            .fill(status == nil ? Color.white.opacity(0.25) : Color.green.opacity(0.8))
                            .frame(width: width * 0.018)
                    }
                    .padding(.horizontal, width * 0.08)
                    EInkSurface(section: section, status: status)
                        .clipShape(RoundedRectangle(cornerRadius: width * 0.012))
                        .padding(.horizontal, width * 0.067)
                    Text("Xteink")
                        .font(.system(size: width * 0.03, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.52))
                        .padding(.bottom, width * 0.035)
                }
                .padding(.top, width * 0.04)
                sideButtons(width: width)
            }
            .frame(width: width, height: height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(0.66, contentMode: .fit)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Xteink X3 device preview")
    }

    private func sideButtons(width: CGFloat) -> some View {
        VStack(spacing: width * 0.18) {
            Capsule().fill(Color.black).frame(width: width * 0.018, height: width * 0.12)
            Capsule().fill(Color.black).frame(width: width * 0.018, height: width * 0.12)
            Capsule().fill(Color.black).frame(width: width * 0.018, height: width * 0.12)
        }
        .offset(x: width * 0.505, y: -width * 0.05)
    }
}

private struct EInkSurface: View {
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
        .aspectRatio(528.0 / 792.0, contentMode: .fit)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .today:
            VStack(spacing: 14) {
                Spacer()
                Text("継").font(.system(size: 116, weight: .regular, design: .serif)).minimumScaleFactor(0.7)
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
                Text("継ぐ").font(.system(size: 66, design: .serif))
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
                Text("吾輩は猫である").font(.system(size: 33, design: .serif))
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
                Text("The file is staged on SD.\nInstallation starts only on X3.")
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
