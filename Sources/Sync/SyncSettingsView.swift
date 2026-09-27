import SwiftUI

/// Where your place in a book is kept in step. Both work without an account.
struct SyncSettingsView: View {
    @ObservedObject var sync: ReadingSync
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
                    Toggle("Your X3/X4 reader, when connected", isOn: $sync.readerExchangeEnabled)
                        .accessibilityIdentifier("sync-reader-exchange")
                    if let last = sync.lastReaderExchange {
                        LabeledContent("Last exchange", value: "\(last.device) · \(last.date.formatted(.relative(presentation: .named)))")
                    }
                } footer: {
                    Text("When another device has read further, Pocket Daily offers to jump there; it never moves your page by itself. Only a fingerprint of the book and your place in it are shared, in your own iCloud or over the local connection to your reader.")
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
