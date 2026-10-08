import SwiftUI

struct AppearanceSettingsSection: View {
    @Binding var appearance: AppAppearance

    var body: some View {
        Section("Appearance") {
            AppAppearancePicker(appearance: $appearance)
        }
    }
}

struct ReaderConnectionSettingsSection: View {
    @AppStorage(PocketModel.autoReconnectKey) private var reconnect = true

    var body: some View {
        Section("Reader connection") {
            Toggle(isOn: $reconnect) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto-reconnect")
                    Text("On the same Wi-Fi").font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("reader-auto-reconnect")
        }
    }
}

/// Shared controls stay one tap away on every platform. Explanations are optional;
/// actionable sync status remains beside the controls in Continue Reading.
private struct AppSettingsForm: View {
    @ObservedObject var model: PocketModel
    @Binding var appearance: AppAppearance
    var openDevice: (() -> Void)?
    @State private var showingAbout = false

    var body: some View {
        Form {
            AppearanceSettingsSection(appearance: $appearance)
            ReadingSyncSettingsSection(sync: .shared, model: model, library: .shared)
            ReaderConnectionSettingsSection()
            if let openDevice {
                Section("Reader management") {
                    Button("Connection and Bluetooth pairing", action: openDevice)
                        .accessibilityIdentifier("settings-open-device")
                }
            }
            Section("Help and privacy") {
                Button("About & Privacy") { showingAbout = true }
                Link("Support", destination: PocketLinks.support)
                Link("Privacy policy", destination: PocketLinks.privacy)
                DisclosureGroup("Sync & connection guide") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Each device needs the same book file. Share it from the Library.")
                        Text("Reading positions are shared when you connect. While the app is open, they also update as you open or close a book or return to the app with a previously connected reader in Same Wi-Fi mode.")
                        Text("Auto-reconnect checks your reader’s last address when it opens Sync → Same Wi-Fi. Your Wi-Fi never changes. For direct connection or Bluetooth pairing, open My Reader → Reader options → Manage reader.")
                            .accessibilityIdentifier("sync-bluetooth-hint")
                        Text("Only a book fingerprint and your reading position are shared through your own iCloud or a local Wi-Fi or Bluetooth connection. No Pocket Daily account is needed.")
                        Text("Book page colors are chosen separately in Text & Page.")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
                }
                .accessibilityIdentifier("settings-guide")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(PocketPalette.workspace)
        .tint(PocketPalette.accent)
        .sheet(isPresented: $showingAbout) { ProjectInformationSheet() }
    }
}

struct AppSettingsSheet: View {
    @ObservedObject var model: PocketModel
    @Environment(\.dismiss) private var dismiss
    @Binding var appearance: AppAppearance
    var openDevice: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            AppSettingsForm(model: model, appearance: $appearance, openDevice: openDevice)
                .navigationTitle("Settings")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .preferredColorScheme(appearance.colorScheme)
#if os(macOS)
        .frame(width: 520, height: 620)
#endif
    }
}
