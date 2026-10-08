import SwiftUI

/// Where your place in a book is kept in step, without a Pocket Daily
/// account or any server to set up. A section of Settings; pairing the reader
/// over Bluetooth lives with the other reader connections in My Reader → Reader options → Manage reader.
struct ReadingSyncSettingsSection: View {
    @ObservedObject var sync: ReadingSync
    @ObservedObject var model: PocketModel
    @ObservedObject var library: LibraryModel
    @ObservedObject private var link = ReaderBluetoothLink.shared

    var body: some View {
        Section {
            Toggle(isOn: $sync.iCloudEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Apple devices")
                    Text("Share your place with iCloud").font(.caption).foregroundStyle(.secondary)
                }
            }
                .accessibilityIdentifier("sync-icloud")
            if sync.iCloudEnabled && !sync.isICloudActive {
                Text("Sign in to iCloud in Settings to continue between your iPhone, iPad and Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle(isOn: $sync.readerExchangeEnabled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("X3 / X4 reader")
                    Text("Share your place when connected").font(.caption).foregroundStyle(.secondary)
                }
            }
                .accessibilityIdentifier("sync-reader-exchange")
            if sync.readerExchangeEnabled, !model.isDemoMode, let reader = link.rememberedReader {
                LabeledContent("Bluetooth", value: "\(reader.model) paired")
                    .accessibilityIdentifier("sync-bluetooth-paired")
                Text(link.statusText).font(.caption).foregroundStyle(.secondary)
                if model.readerStatus?.deviceID == reader.readerID,
                   let diagnostic = model.readerStatus?.readSync?.explanation {
                    Text(diagnostic).font(.caption).foregroundStyle(.secondary)
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
            Text("You choose before moving to another device’s place.")
        }
    }
}

/// Pairs the reader once so it can exchange reading places over Bluetooth
/// when it closes a book, wakes or goes to sleep. It sits in My Reader → Reader options → Manage reader with the
/// other ways of reaching the reader.
struct ReaderBluetoothPairingCard: View {
    @ObservedObject var sync: ReadingSync
    @ObservedObject private var link = ReaderBluetoothLink.shared

    var body: some View {
        InspectorCard(title: "Continue reading across devices", symbol: "arrow.triangle.2.circlepath") {
            Text("Bluetooth shares your reading position. Books and other files transfer over Wi-Fi. You choose when to jump to a shared position.")
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
                    Text("On the reader: Pocket Daily → Sync → Direct connection. Then choose Pair reader and confirm its code. A direct Wi-Fi connection pairs it too.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if link.rememberedReader != nil {
                Text(link.statusText).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("sync-bluetooth-status")
                if let date = link.lastCompletedAt {
                    LabeledContent("Last Bluetooth exchange", value: date.formatted(.relative(presentation: .named)))
                        .font(.caption)
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
