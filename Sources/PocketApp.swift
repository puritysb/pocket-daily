import SwiftUI

@main
struct PocketApp: App {
    @StateObject private var model = PocketModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .preferredColorScheme(.light)
#if os(macOS)
                .frame(minWidth: 1080, minHeight: 720)
#endif
        }
#if os(macOS)
        .defaultSize(width: 1180, height: 780)
#endif
    }
}
