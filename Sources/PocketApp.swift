import SwiftUI

@main
struct PocketApp: App {
    @StateObject private var fleet: ReaderFleet

    init() {
        // Before any scene: a background relaunch for a restored Bluetooth
        // connection must recreate the reading-sync central at once.
        let fleet = ReaderFleet()
        _fleet = StateObject(wrappedValue: fleet)
#if DEBUG
        ReaderDevelopmentContext.model = fleet.selected?.model
#endif
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
        ReaderFleetView(fleet: fleet)
            // Selection is amber on every platform; iOS switches otherwise
            // stay system green while macOS follows the accent color.
            .tint(PocketPalette.accent)
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
