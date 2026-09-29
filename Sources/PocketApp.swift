import SwiftUI

@main
struct PocketApp: App {
    @StateObject private var model: PocketModel

    init() {
        // Before any scene: a background relaunch for a restored Bluetooth
        // connection must recreate the reading-sync central at once.
        let model = PocketModel()
        _model = StateObject(wrappedValue: model)
        ReaderBluetoothLink.shared.bindAppState(to: model)
        ReaderBluetoothLink.shared.start()
    }

    var body: some Scene {
        WindowGroup {
#if DEBUG && os(iOS)
            if ProcessInfo.processInfo.arguments.contains("--ui-test-article-share") {
                ArticleShareTestHost()
            } else {
                mainView
            }
#else
            mainView
#endif
        }
#if os(macOS)
        .defaultSize(width: 1180, height: 780)
#endif
    }

    private var mainView: some View {
        ContentView()
            .environmentObject(model)
#if os(macOS)
            .frame(minWidth: 1080, minHeight: 720)
#endif
    }
}
