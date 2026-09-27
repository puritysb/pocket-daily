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
#if os(macOS)
        WindowGroup("Reader", id: "reader", for: UUID.self) { $bookID in
            if let bookID {
                MacReaderWindow(bookID: bookID)
            }
        }
        .defaultSize(width: 760, height: 900)
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

#if os(macOS)
private struct MacReaderWindow: View {
    let bookID: UUID
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ReaderContainer(bookID: bookID, library: .shared, sync: .shared) {
            dismissWindow(id: "reader", value: bookID)
        }
        .frame(minWidth: 420, minHeight: 560)
    }
}
#endif
