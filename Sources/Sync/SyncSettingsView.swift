import SwiftUI

/// Three ways to keep your place, from no setup to an account: iCloud for your
/// Apple devices, your X3/X4 reader when connected, and a KOReader sync server.
struct SyncSettingsView: View {
    @ObservedObject var sync: ReadingSync
    @ObservedObject var model: PocketModel
    @Environment(\.dismiss) private var dismiss
    @State private var customServer = false
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
    private var serverAddress: String { customServer ? server : KOSyncServer.standard.baseURL.absoluteString }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Continue where you left off on your other Apple devices, on your X3/X4 reader, and in KOReader. Pocket Daily only offers to jump; it never moves your page by itself.")
                        .font(.callout)
                }
                appleDevices
                reader
                if sync.isConnected { connected } else { signIn }
                Section("What is shared") {
                    Text("For each book you open: a fingerprint of the book file, your position in it, and this device's name (\(sync.deviceName)). Books, notes and reading history stay on this device.")
                    Text("iCloud keeps these in your own iCloud account. A KOReader sync server receives them only after you sign in; your password is not stored, only the key KOReader sync uses, in this device's Keychain.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle("Sync")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Sign out of the sync server?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    do { try sync.disconnect() } catch { self.error = error.localizedDescription }
                }
            } message: {
                Text("Reading positions stay on this device. iCloud and your reader keep syncing.")
            }
        }
        .task {
            if server.isEmpty { server = sync.serverAddress }
            customServer = sync.serverAddress != KOSyncServer.standard.baseURL.absoluteString
#if DEBUG
            // scripts/e2e_sync.sh points both simulators at its local server.
            if !sync.isConnected, let development = ProcessInfo.processInfo.environment["KOSYNC_E2E_SERVER"] {
                server = development
                customServer = true
            }
#endif
            if !sync.isConnected { await sync.checkServer(serverAddress) }
        }
#if os(macOS)
        .frame(minWidth: 460, minHeight: 600)
#endif
    }

    // MARK: Channels

    private var appleDevices: some View {
        Section {
            Toggle("Sync with iCloud", isOn: $sync.iCloudEnabled)
                .accessibilityIdentifier("sync-icloud")
            if sync.iCloudEnabled && !sync.isICloudActive {
                Text("Sign in to iCloud in Settings to sync between your iPhone, iPad and Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Your Apple devices")
        } footer: {
            Text("No account or setup. Uses your iCloud; nothing goes to Pocket Daily.")
        }
    }

    private var reader: some View {
        Section {
            Toggle("Exchange positions when connected", isOn: $sync.readerExchangeEnabled)
                .accessibilityIdentifier("sync-reader-exchange")
            if let last = sync.lastReaderExchange {
                LabeledContent("Last exchange", value: "\(last.device) · \(last.date.formatted(.relative(presentation: .named)))")
            }
            if canSetUpReader {
                SecureField("Server password again", text: $readerPassword)
                    .textContentType(.password)
                    .accessibilityIdentifier("sync-reader-password")
                Button("Also sync the connected reader through the server") { setUpReader() }
                    .disabled(readerPassword.isEmpty || settingUpReader)
                    .accessibilityIdentifier("sync-reader-setup")
                if let readerSetup { Text(readerSetup).font(.callout) }
            }
        } header: {
            Text("Your X3/X4 reader")
        } footer: {
            Text(canSetUpReader
                 ? "Positions are exchanged over the local connection without a server; the reader asks before it moves. The server setup sends this account to the connected reader, which stores the password itself."
                 : "Positions are exchanged over the local connection without a server whenever the reader's firmware supports it; the reader asks before it moves.")
        }
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
            Label("KOReader sync server", systemImage: "checkmark.circle.fill")
        } footer: {
            Text("On the reader, KOReader Sync must use the same account and Document matching set to \(sync.matching == .binary ? "Binary" : "Filename").")
        }
    }

    private var signIn: some View {
        Section {
            health
            TextField("Username", text: $username)
                .textContentType(.username)
                .autocorrectionDisabled()
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif
                .accessibilityIdentifier("sync-username")
            SecureField("Password", text: $password)
                .textContentType(.newPassword)
                .accessibilityIdentifier("sync-password")
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Create account") { connect(create: true) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("sync-create")
                Button("Sign in") { connect(create: false) }
                    .accessibilityIdentifier("sync-sign-in")
                if working { ProgressView().padding(.leading, 6) }
            }
            .disabled(working || username.isEmpty || password.isEmpty || serverAddress.isEmpty)
            Toggle("Use another server", isOn: $customServer)
                .accessibilityIdentifier("sync-custom-server")
            if customServer {
                TextField("https://sync.example.com", text: $server)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
#if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
#endif
                    .onSubmit { Task { await sync.checkServer(serverAddress) } }
                    .accessibilityIdentifier("sync-server")
            }
        } header: {
            Text("KOReader sync server (optional)")
        } footer: {
            Text("For KOReader devices and for your reader when it is not connected. New here? Choose a username and password and tap Create account on the free public KOReader server.")
        }
        .onChange(of: customServer) { _, _ in Task { await sync.checkServer(serverAddress) } }
    }

    @ViewBuilder private var health: some View {
        let name = customServer ? "Server" : "KOReader public server"
        switch sync.serverHealth {
        case .unknown:
            LabeledContent(name, value: customServer ? server : "sync.koreader.rocks")
        case .checking:
            LabeledContent(name) { ProgressView().controlSize(.small) }
        case .available:
            LabeledContent(name) { Label("Available", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                .accessibilityIdentifier("sync-health")
        case .unavailable(let message):
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent(name) { Label("Not responding", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("Check again") { Task { await sync.checkServer(serverAddress) } }
                    .font(.caption)
            }
            .accessibilityIdentifier("sync-health")
        }
    }

    // MARK: Actions

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
                try await sync.connect(server: serverAddress, username: username, password: password, create: create)
                password = ""
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
