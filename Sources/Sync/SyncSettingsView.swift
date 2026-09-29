import SwiftUI

/// Where your place in a book is kept in step, without a Pocket Daily
/// account or any server to set up.
struct SyncSettingsView: View {
    @ObservedObject var sync: ReadingSync
    @ObservedObject var model: PocketModel
    @ObservedObject var library: LibraryModel
    @ObservedObject private var link = ReaderBluetoothLink.shared
    @Environment(\.dismiss) private var dismiss

    @ViewBuilder private var bluetoothPairing: some View {
        if let reader = link.rememberedReader {
            LabeledContent("Bluetooth", value: "\(reader.model) paired")
                .accessibilityIdentifier("sync-bluetooth-paired")
            Button("Forget this reader", role: .destructive) { link.forget() }
        } else {
            switch link.setup {
            case .searching:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for the reader. On the reader, open Pocket Daily → Sync and keep it on that screen.")
                        .font(.caption)
                }
                Button("Cancel") { link.cancelSetup() }
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                Button("Try again") { link.beginSetup() }
            case .idle, .paired:
                Button("Set up Bluetooth sync") { link.beginSetup() }
                    .accessibilityIdentifier("sync-bluetooth-setup")
                Text("Once: open Pocket Daily → Sync on the reader, then choose this. Enter the code the reader shows if asked.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Your Apple devices (iCloud)", isOn: $sync.iCloudEnabled)
                        .accessibilityIdentifier("sync-icloud")
                    if sync.iCloudEnabled && !sync.isICloudActive {
                        Text("Sign in to iCloud in Settings to continue between your iPhone, iPad and Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Your X3/X4 reader", isOn: $sync.readerExchangeEnabled)
                        .accessibilityIdentifier("sync-reader-exchange")
                    if sync.readerExchangeEnabled {
                        Text("Places are exchanged when you connect, and automatically whenever a reader you connected before is in Same Wi-Fi mode while Pocket Daily is open: as you open or close a book, or return to the app.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("A paired reader can exchange places over Bluetooth when it closes a book, wakes or goes to sleep. Background delivery depends on the system and may wait until the next connection. Nothing moves your page until you choose.")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("sync-reader-bluetooth")
                        if !model.isDemoMode { bluetoothPairing }
                    }
                    if let last = sync.lastReaderExchange {
                        LabeledContent("Last exchange", value: "\(last.device) · \(last.date.formatted(.relative(presentation: .named)))")
                            .accessibilityIdentifier("sync-last-exchange")
                    }
                    if let error = sync.readerExchangeError {
                        Label("The last exchange with the reader failed: \(error)", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if sync.readerExchangeEnabled && model.canExchangeReadingPositions {
                        Button("Exchange positions now") {
                            sync.exchangeWithReader(model: model, library: library, force: true)
                        }
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("sync-exchange-now")
                    }
                } footer: {
                    Text("When another device read more recently, or got further, Pocket Daily offers to jump there; it never moves your page by itself. No Pocket Daily account or server setup is needed. Only a fingerprint of the book and your place in it are shared, in your own iCloud or over the local Wi-Fi or Bluetooth connection to your reader. Each device needs the same book file: share it from the Library.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Continue Reading")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
#if os(macOS)
        .frame(minWidth: 420, minHeight: 320)
#endif
    }
}
