import SwiftUI

@main
struct PocketApp: App {
    @StateObject private var model = PocketModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}
