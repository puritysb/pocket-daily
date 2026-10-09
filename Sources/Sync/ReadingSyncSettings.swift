import SwiftUI

/// Where your place in a book is kept in step, without a Pocket Daily
/// account or any server to set up. A section of Settings; pairing the reader
/// over Bluetooth lives with the other reader connections in My Reader → Reader Options → Manage Reader.
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
                PocketStatusLabel("Last exchange failed · \(error)", tone: .failure)
                    .font(.caption)
            }
            if sync.readerExchangeEnabled && model.canExchangeReadingPositions {
                Button("Exchange Positions Now") {
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
/// when it closes a book, wakes or goes to sleep. It sits in My Reader → Reader Options → Manage Reader with the
/// other ways of reaching the reader.
struct ReaderBluetoothPairingCard: View {
    @ObservedObject var sync: ReadingSync
    @ObservedObject private var link = ReaderBluetoothLink.shared
    @State private var confirmingForget = false

    var body: some View {
        InspectorCard(title: "Continue reading across devices", symbol: "arrow.triangle.2.circlepath") {
            Text("Bluetooth shares your reading position. Books and other files transfer over Wi-Fi. You choose when to jump to a shared position.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("sync-reader-bluetooth")
            if let reader = link.rememberedReader {
                HStack {
                    PocketStatusLabel("\(reader.model) paired", tone: .success, symbol: "checkmark.circle")
                        .font(.callout.weight(.medium))
                        .accessibilityIdentifier("sync-bluetooth-paired")
                    Spacer()
                    Button("Forget…", role: .destructive) { confirmingForget = true }
                        .buttonStyle(.borderless).font(.callout)
                }
                .confirmationDialog("Forget \(reader.model)?", isPresented: $confirmingForget, titleVisibility: .visible) {
                    Button("Forget \(reader.model)", role: .destructive) { link.forget() }
                } message: {
                    Text("Positions stop moving over Bluetooth until you pair again on the reader. Books and settings are not changed.")
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
                    PocketStatusLabel(message, tone: .failure)
                        .font(.caption)
                    Button("Try Again") { link.beginSetup() }
                        .buttonStyle(.bordered)
                case .idle, .paired:
                    Button("Pair Reader") { link.beginSetup() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("sync-bluetooth-setup")
                    Text("On the reader: Pocket Daily → Sync → Direct connection. Then choose Pair Reader and confirm its code. A direct Wi-Fi connection pairs it too.")
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
                PocketStatusLabel("Reader sync is off, so a paired reader does not exchange places.", tone: .pending,
                                  symbol: "exclamationmark.triangle")
                    .font(.caption)
                Button("Turn On Reader Sync") { sync.readerExchangeEnabled = true }
                    .buttonStyle(.bordered)
            }
        }
    }
}
