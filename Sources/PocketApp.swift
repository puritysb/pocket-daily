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
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands { PocketSettingsCommands() }
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

#if os(macOS)
private struct SettingsPresentationKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var settingsPresentation: Binding<Bool>? {
        get { self[SettingsPresentationKey.self] }
        set { self[SettingsPresentationKey.self] = newValue }
    }
}

private struct PocketSettingsCommands: Commands {
    @FocusedBinding(\.settingsPresentation) private var showingSettings: Bool?

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { showingSettings = true }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(showingSettings == nil)
        }
    }
}
#endif
