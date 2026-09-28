import SwiftUI

/// Where your place in a book is kept in step, without a Pocket Daily
/// account or any server to set up.
struct SyncSettingsView: View {
    @ObservedObject var sync: ReadingSync
    @ObservedObject var model: PocketModel
    @ObservedObject var library: LibraryModel
    @Environment(\.dismiss) private var dismiss

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
                        Text("A reader you paired with Connect directly also syncs places over Bluetooth by itself when it closes a book, wakes or goes to sleep, even while Pocket Daily is in the background. Nothing moves your page until you choose.")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("sync-reader-bluetooth")
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
