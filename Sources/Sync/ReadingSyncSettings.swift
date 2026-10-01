import SwiftUI

/// Where your place in a book is kept in step, without a Pocket Daily
/// account or any server to set up. A section of Settings; pairing the reader
/// over Bluetooth lives with the other reader connections in Reader → Connection.
struct ReadingSyncSettingsSection: View {
    @ObservedObject var sync: ReadingSync
    @ObservedObject var model: PocketModel
    @ObservedObject var library: LibraryModel
    @ObservedObject private var link = ReaderBluetoothLink.shared

    var body: some View {
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
                if !model.isDemoMode {
                    if let reader = link.rememberedReader {
                        LabeledContent("Bluetooth", value: "\(reader.model) paired")
                            .accessibilityIdentifier("sync-bluetooth-paired")
                    } else {
                        Text("To also exchange places over Bluetooth, pair the reader once in Reader → Connection.")
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("sync-bluetooth-hint")
                    }
                }
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
        } header: {
            Text("Continue Reading")
        } footer: {
            Text("When another device read more recently, or got further, Pocket Daily offers to jump there; it never moves your page by itself. No Pocket Daily account or server setup is needed. Only a fingerprint of the book and your place in it are shared, in your own iCloud or over the local Wi-Fi or Bluetooth connection to your reader. Each device needs the same book file: share it from the Library.")
        }
    }
}

/// Pairs the reader once so it can exchange reading places over Bluetooth
/// when it closes a book, wakes or goes to sleep. It sits in Reader → Connection with the
/// other ways of reaching the reader.
struct ReaderBluetoothPairingCard: View {
    @ObservedObject var sync: ReadingSync
    @ObservedObject private var link = ReaderBluetoothLink.shared

    var body: some View {
        InspectorCard(title: "Reading sync over Bluetooth", symbol: "arrow.triangle.2.circlepath") {
            Text("A paired reader exchanges places over Bluetooth when it closes a book, wakes or goes to sleep. Background delivery depends on the system and may wait until the next connection. Nothing moves your page until you choose.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("sync-reader-bluetooth")
            if let reader = link.rememberedReader {
                HStack {
                    Label("\(reader.model) paired", systemImage: "checkmark.circle")
                        .font(.callout.weight(.medium))
                        .accessibilityIdentifier("sync-bluetooth-paired")
                    Spacer()
                    Button("Forget", role: .destructive) { link.forget() }
                        .buttonStyle(.borderless).font(.callout)
                }
            } else {
                switch link.setup {
                case .searching:
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Looking for the reader. On the reader, open Pocket Daily → Sync → Direct connection and stay on that screen.")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Cancel") { link.cancelSetup() }
                        .buttonStyle(.bordered)
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try again") { link.beginSetup() }
                        .buttonStyle(.bordered)
                case .idle, .paired:
                    Button("Pair reader") { link.beginSetup() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("sync-bluetooth-setup")
                    Text("Once: on the reader, open Pocket Daily → Sync → Direct connection (Nearby Sync on older firmware), then choose Pair reader. Enter the code the reader shows if asked. Connecting directly pairs it too.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !sync.readerExchangeEnabled {
                Text("Reader sync is off in Settings, so a paired reader does not exchange places.")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
