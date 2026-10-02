import SwiftUI

/// How the app itself looks. Book pages keep their own paper, white or night
/// color from Text & Page.
struct AppearanceSettingsSection: View {
    var body: some View {
        Section {
            AppAppearancePicker()
        } footer: {
            Text("Book pages use the color you choose in Text & Page.")
        }
    }
}

/// Whether the app reopens a session on its own with the reader it connected
/// to before (docs/SYNC_SESSIONS.md).
struct ReaderConnectionSettingsSection: View {
    @AppStorage(PocketModel.autoReconnectKey) private var reconnect = true

    var body: some View {
        Section {
            Toggle("Reconnect on the same Wi-Fi", isOn: $reconnect)
                .accessibilityIdentifier("reader-auto-reconnect")
        } header: {
            Text("Your reader")
        } footer: {
            Text("When the reader you connected before opens Sync → Same Wi-Fi, Pocket Daily connects to it again. Only the reader’s last address is asked; your Wi-Fi never changes. Direct connection always starts in Reader → Connection.")
        }
    }
}

/// App-wide preferences in one place: how the app looks and where your place
/// in a book is kept in step. A sheet on iPhone and iPad; macOS shows the same
/// sections in its Settings window.
struct AppSettingsSheet: View {
    @ObservedObject var model: PocketModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                AppearanceSettingsSection()
                ReaderConnectionSettingsSection()
                ReadingSyncSettingsSection(sync: .shared, model: model, library: .shared)
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

#if os(macOS)
/// The Settings window (⌘,).
struct AppSettingsWindow: View {
    @EnvironmentObject private var model: PocketModel
    @AppStorage("appAppearance") private var appearance = AppAppearance.system

    var body: some View {
        TabView {
            Form {
                AppearanceSettingsSection()
                ReaderConnectionSettingsSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }
            Form { ReadingSyncSettingsSection(sync: .shared, model: model, library: .shared) }
                .formStyle(.grouped)
                .tabItem { Label("Continue Reading", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 520, height: 480)
        .preferredColorScheme(appearance.colorScheme)
    }
}
#endif
