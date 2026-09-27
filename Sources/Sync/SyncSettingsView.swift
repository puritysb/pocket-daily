import SwiftUI

struct SyncSettingsView: View {
    @ObservedObject var sync: ReadingSync
    @ObservedObject var model: PocketModel
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @State private var confirmingSignOut = false
    @State private var readerPassword = ""
    @State private var readerSetup: String?
    @State private var settingUpReader = false

    private var canSetUpReader: Bool { sync.isConnected && !model.isDemoMode && model.readerStatus != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Continue where you left off on your X3/X4 reader, in KOReader on other e-readers, and in Pocket Daily on your other devices. Sync is optional, and we recommend it.")
                        .font(.callout)
                }
                if sync.isConnected { connected } else { signIn }
                Section("What is shared") {
                    Text("For each book you open: a fingerprint of the book file, your position in it, and this device's name (\(sync.deviceName)). Books, notes and reading history stay on this device.")
                    Text("Your password is not stored. Pocket Daily keeps only the key KOReader sync uses, in this device's Keychain.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Section("On your reader") {
                    if canSetUpReader {
                        SecureField("Password again", text: $readerPassword)
                            .textContentType(.password)
                            .accessibilityIdentifier("sync-reader-password")
                        Button("Set up the connected reader") { setUpReader() }
                            .disabled(readerPassword.isEmpty || settingUpReader)
                            .accessibilityIdentifier("sync-reader-setup")
                        if let readerSetup { Text(readerSetup).font(.callout) }
                        Text("Sends this server and account to the connected reader over the local connection. The reader stores the password itself; Pocket Daily does not keep it.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Connect your reader to set it up from here, or in the reader's settings under KOReader Sync enter the same server, username and password, and set Document matching to \(sync.matching == .binary ? "Binary" : "Filename"). Books you send from the Library then match automatically.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Sync")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Sign out of sync?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    do { try sync.disconnect() } catch { self.error = error.localizedDescription }
                }
            } message: {
                Text("Reading positions stay on this device. Other devices keep their own copies.")
            }
        }
        .onAppear { if server.isEmpty { server = sync.serverAddress } }
#if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
#endif
    }

    private var connected: some View {
        Section {
            LabeledContent("Server", value: sync.serverAddress)
            LabeledContent("Account", value: sync.username ?? "")
            if let status = sync.statusLine {
                Label(status, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else if let last = sync.lastSynced {
                LabeledContent("Last synced", value: last.formatted(.relative(presentation: .named)))
            }
            Picker("Match books by", selection: $sync.matching) {
                ForEach(ReadingSync.DocumentMatching.allCases) { Text($0.title).tag($0) }
            }
            Button("Sign out", role: .destructive) { confirmingSignOut = true }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        } header: {
            Label("Connected", systemImage: "checkmark.circle.fill")
        }
    }

    private var signIn: some View {
        Section {
            TextField("Server", text: $server)
                .textContentType(.URL)
                .autocorrectionDisabled()
#if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
#endif
                .accessibilityIdentifier("sync-server")
            TextField("Username", text: $username)
                .textContentType(.username)
                .autocorrectionDisabled()
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif
                .accessibilityIdentifier("sync-username")
            SecureField("Password", text: $password)
                .textContentType(.password)
                .accessibilityIdentifier("sync-password")
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Sign in") { connect(create: false) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("sync-sign-in")
                Button("Create account") { connect(create: true) }
                    .accessibilityIdentifier("sync-create")
                if working { ProgressView().padding(.leading, 6) }
            }
            .disabled(working || username.isEmpty || password.isEmpty || server.isEmpty)
        } header: {
            Text("KOReader sync account")
        } footer: {
            Text("The default is the public KOReader sync server. You can also use your own.")
        }
    }

    private func setUpReader() {
        guard let username = sync.username else { return }
        settingUpReader = true
        readerSetup = nil
        Task {
            defer { settingUpReader = false }
            do {
                try await model.configureReaderSync(server: sync.serverAddress, username: username, password: readerPassword,
                                                    matchByContent: sync.matching == .binary)
                readerPassword = ""
                readerSetup = "The reader now syncs with the same account."
            } catch {
                readerSetup = error.localizedDescription
            }
        }
    }

    private func connect(create: Bool) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await sync.connect(server: server, username: username, password: password, create: create)
                password = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
