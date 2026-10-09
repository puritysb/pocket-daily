import SwiftUI

private struct ReaderFleetKey: EnvironmentKey {
    static let defaultValue: ReaderFleet? = nil
}
extension EnvironmentValues {
    var readerFleet: ReaderFleet? {
        get { self[ReaderFleetKey.self] }
        set { self[ReaderFleetKey.self] = newValue }
    }
}

/// Only one workspace is presented. Its session and editor outlive the view,
/// so accessibility and navigation expose exactly one copy of each control.
struct ReaderFleetView: View {
    @ObservedObject var fleet: ReaderFleet
    @Environment(\.scenePhase) private var scenePhase
    @State private var firstPresentation = true
    var body: some View {
        Group {
            if let reader = fleet.selected {
                ContentView(initialSection: firstPresentation ? .library : .reader,
                            initialPreview: reader.workspace?.preview ?? .home,
                            bluetoothLink: reader.model.bluetoothLink,
                            profileStore: reader.model.profileEditStore, workspace: reader.workspace)
                    .environmentObject(reader.model)
                    .id(reader.id)
            }
        }
        .environment(\.readerFleet, fleet)
        .onAppear { firstPresentation = false }
        .onChange(of: scenePhase) { _, phase in
            for reader in fleet.readers {
                if phase == .active {
                    reader.model.resumeForForeground()
                    reader.model.bluetoothLink.start()
                }
#if os(iOS)
                if phase == .background {
                    reader.workspace?.nearby.disconnect()
                    reader.model.pauseForBackground()
                }
#endif
            }
        }
        .task {
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            while !Task.isCancelled {
                for reader in fleet.readers { reader.model.reconnectRememberedReader() }
                try? await Task.sleep(for: .seconds(8))
            }
        }
        .alert("Readers", isPresented: Binding(get: { fleet.error != nil }, set: { if !$0 { fleet.error = nil } })) {
            Button("OK") { fleet.error = nil }
        } message: { Text(fleet.error ?? "") }
    }
}

struct ReaderPicker: View {
    @ObservedObject var fleet: ReaderFleet
    @State private var showingReaders = false
    var body: some View {
        Button { showingReaders = true } label: {
            HStack(spacing: 8) {
                PocketSymbol("rectangle.portrait.on.rectangle.portrait", role: .accessory)
                Text("Readers…").lineLimit(1)
                if fleet.connectedCount > 0 {
                    Text("\(fleet.connectedCount) Connected").foregroundStyle(.secondary)
                }
                PocketSymbol("chevron.down", role: .accessory)
            }
            .font(.subheadline)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Manage Readers")
        .accessibilityIdentifier("reader-picker")
        .sheet(isPresented: $showingReaders) { ReaderManager(fleet: fleet) }
    }
}

private struct ReaderManager: View {
    @ObservedObject var fleet: ReaderFleet
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: RegisteredReader?
    @State private var removing: RegisteredReader?
    @State private var ending: RegisteredReader?
    @State private var name = ""
    @State private var host = ""
    @State private var showAddress = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PocketDesign.sectionSpacing) {
                    Text("Choose a reader to see its books, settings and transfers. Other readers stay connected.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(fleet.readers) { reader in
                        readerRow(reader)
                    }
                    Button("Add Reader", systemImage: "plus") {
                        do {
                            _ = try fleet.add()
                            fleet.selected?.model.startConnectionSearch()
                            dismiss()
                        } catch { failure = error.localizedDescription }
                    }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("reader-add")
                    .disabled(fleet.readers.contains { $0.model.isDemoMode })
                    Text("For simultaneous connections, put each reader in Sync → Same Wi-Fi. Direct Wi-Fi connects one reader at a time.")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Connect by Address", isExpanded: $showAddress) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Connect the selected registration to a reader on your current Wi-Fi.")
                                .font(.caption).foregroundStyle(.secondary)
                            TextField("Reader IP Address", text: $host).textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled()
                            Button("Connect") {
                                let address = host.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard let model = fleet.selected?.model else { return }
                                Task { await model.verify(host: address, port: 80) }
                                dismiss()
                            }.disabled(!validAddress || fleet.selected?.model.isWorking == true)
                        }.padding(.top, 8)
                    }
                }.padding(PocketDesign.pageInset)
            }
            .navigationTitle("Manage Readers")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
#if os(macOS)
        .frame(width: 540, height: 440)
#endif
        .alert("Reader Could Not Be Changed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
        .alert("Rename Reader", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $name)
            Button("Save") {
                if let reader = renaming { perform { try fleet.rename(reader, to: name) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("End session with \(ending?.registration.name ?? "Reader")?",
                            isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }),
                            titleVisibility: .visible) {
            Button("End Session", role: .destructive) {
                ending?.model.endConnection()
                ending = nil
            }
        } message: {
            Text("This closes Sync on the reader. To connect again, reopen Sync → Same Wi-Fi. Bluetooth wake requires supported standby mode.")
        }
        .confirmationDialog("Remove \(removing?.registration.name ?? "Reader")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove Reader", role: .destructive) {
                if let reader = removing { perform { try fleet.remove(reader) } }
                removing = nil
            }
        } message: {
            Text("This stops automatic connections and Bluetooth sync for this registration. Your library and files on the reader are kept. Saved drafts remain on this device for recovery.")
        }
    }

    private var validAddress: Bool {
        let parts = host.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber) && UInt8(part) != nil
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { failure = error.localizedDescription }
    }

    private func readerRow(_ reader: RegisteredReader) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Button {
                    fleet.selectedID = reader.id
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        PocketSymbol("rectangle.portrait", role: .navigation)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(reader.registration.name).font(.headline)
                            DeviceStatusLabel(device: reader.model.device, showsReader: false)
                            if reader.model.isWorking { Text("Task in Progress").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if fleet.selectedID == reader.id { Image(systemName: "checkmark").foregroundStyle(PocketPalette.accent) }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("reader-select-" + reader.id.uuidString)
                Menu {
                    Button("Rename…") { name = reader.registration.name; renaming = reader }
                    Button("Remove Reader…", role: .destructive) { removing = reader }
                        .disabled(!reader.model.canRemoveRegistration)
                } label: { PocketActionGlyph(name: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Options for " + reader.registration.name)
            }
            if !reader.model.isDemoMode {
                HStack {
                    if reader.model.readerStatus != nil {
                        Button("End Session…", role: .destructive) { ending = reader }.disabled(reader.model.isWorking)
                    } else if reader.model.canCancelConnection {
                        Button("Cancel Connection") { reader.model.cancelConnectionAttempt() }
                    } else {
                        Button("Connect") { reader.model.startConnectionSearch() }.disabled(reader.model.isWorking)
                    }
                }.buttonStyle(.bordered)
            }
        }
        .padding(16).background(PocketPalette.panel, in: RoundedRectangle(cornerRadius: PocketDesign.controlRadius))
    }
}
