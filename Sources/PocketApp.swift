import SwiftUI

@main
struct PocketApp: App {
    @StateObject private var model = PocketModel()

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
            .preferredColorScheme(.light)
#if os(macOS)
            .frame(minWidth: 1080, minHeight: 720)
#endif
    }
}
