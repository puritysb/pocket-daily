import Combine
import Foundation

struct ReaderRegistration: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var deviceID: String?
    var host: String?
    var port = 80
    var hardware: String? = nil
    var usesLegacyStorage = false

    static func validIdentity(_ identity: String) -> Bool {
        identity.utf8.count == 8 && identity.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) }
    }
}

struct ReaderRegistryStore {
    struct Archive: Codable {
        var schema = 1
        var readers: [ReaderRegistration]
    }
    let file: URL

    func load() throws -> [ReaderRegistration]? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try Data(contentsOf: file)
        guard data.count <= 128 * 1024 else { throw ReaderRegistrationError.invalidRegistry }
        let archive = try JSONDecoder().decode(Archive.self, from: data)
        let readers = archive.readers
        let identities = readers.compactMap(\.deviceID)
        guard archive.schema == 1, !readers.isEmpty, readers.count <= 32,
              Set(readers.map(\.id)).count == readers.count,
              Set(identities).count == identities.count, identities.allSatisfy(ReaderRegistration.validIdentity),
              readers.filter(\.usesLegacyStorage).count <= 1,
              readers.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 64 && (1...65535).contains($0.port) }) else {
            throw ReaderRegistrationError.invalidRegistry
        }
        return readers
    }

    func save(_ readers: [ReaderRegistration]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Archive(readers: readers)).write(to: file, options: .atomic)
    }
}

enum ReaderRegistrationError: LocalizedError {
    case invalidRegistry, duplicate, mismatch, unidentified, busy, limit
    var errorDescription: String? {
        switch self {
        case .invalidRegistry: "Saved readers could not be loaded. Their records are preserved. Restore the registry before adding or connecting readers."
        case .duplicate: "This reader is already registered. Select it in My Readers."
        case .mismatch: "This is a different reader. Select its registration or choose Add Reader."
        case .unidentified: "This firmware does not report a reader ID. Additional readers need compatible firmware that reports a unique device ID."
        case .busy: "End this reader’s connection and wait for its current task before removing it."
        case .limit: "You can register up to 32 readers. Remove an unused registration first."
        }
    }
}

@MainActor
final class RegisteredReader: Identifiable {
    let id: UUID
    var registration: ReaderRegistration
    let model: PocketModel
    var workspace: ReaderWorkspace?
    init(registration: ReaderRegistration, model: PocketModel) {
        self.id = registration.id
        self.registration = registration
        self.model = model
    }
}

/// Every reader keeps its own transport, work lane and durable drafts. Selection
/// only changes the visible workspace; it never redirects an in-flight request.
@MainActor
final class ReaderFleet: ObservableObject {
    @Published private(set) var readers: [RegisteredReader] = []
    @Published var selectedID: UUID?
    @Published var error: String?
    private let store: ReaderRegistryStore
    private let root: URL
    private let isolated: Bool
    private let startBluetooth: Bool
    private let modelFactory: ((ReaderSessionStorage, ReaderBluetoothLink) -> PocketModel)?
    private var loadFailed = false
    private var observations: [UUID: AnyCancellable] = [:]

    init(store: ReaderRegistryStore? = nil, root: URL? = nil, startBluetooth: Bool = true,
         modelFactory: ((ReaderSessionStorage, ReaderBluetoothLink) -> PocketModel)? = nil) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pocket/Readers")
        self.root = base
        self.startBluetooth = startBluetooth
        self.modelFactory = modelFactory
        let isolated = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--ui-test") || $0 == "--demo" }
            || (ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
                && ProcessInfo.processInfo.environment["POCKET_HARDWARE_ENABLED"] != "1")
        self.isolated = isolated
        self.store = store ?? ReaderRegistryStore(file: (isolated ? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) : base)
            .appendingPathComponent("readers.json"))
        do {
            let entries: [ReaderRegistration]
            if let saved = try self.store.load() { entries = saved }
            else {
                let paired = RememberedBluetoothReaderStore().reader
                entries = [ReaderRegistration(name: paired?.model ?? "Your Reader",
                    deviceID: isolated ? nil : UserDefaults.standard.string(forKey: "Pocket.lastReaderDeviceID") ?? paired?.readerID,
                    host: isolated ? nil : UserDefaults.standard.string(forKey: "Pocket.lastReaderHost"), usesLegacyStorage: true)]
                if ProcessInfo.processInfo.arguments.contains("--ui-test-multiple-readers") {
                    var fixtures = entries
                    fixtures[0].name = "Desk X3"
                    fixtures.append(ReaderRegistration(name: "Travel X4", hardware: "X4"))
                    try self.store.save(fixtures)
                    for entry in fixtures { try append(entry, startBluetooth: false) }
                } else { try self.store.save(entries) }
            }
            if readers.isEmpty { for entry in entries { try append(entry, startBluetooth: startBluetooth) } }
        } catch {
            loadFailed = true
            self.error = error.localizedDescription
            // Reading in the app remains available even when registry recovery is needed.
            if readers.isEmpty { try? append(ReaderRegistration(name: "Your Reader"), startBluetooth: false) }
        }
        selectedID = readers.first?.id
    }

    var connectedCount: Int { readers.filter { $0.model.device.isConnected && !$0.model.isDemoMode }.count }
    var selected: RegisteredReader? { readers.first { $0.id == selectedID } }

    @discardableResult
    func add() throws -> UUID {
        guard !loadFailed else { throw ReaderRegistrationError.invalidRegistry }
        if let empty = readers.first(where: { $0.registration.deviceID == nil && $0.registration.host == nil && $0.model.bluetoothLink.rememberedReader == nil && !$0.model.isDemoMode }) {
            selectedID = empty.id
            return empty.id
        }
        guard readers.count < 32 else { throw ReaderRegistrationError.limit }
        let entry = ReaderRegistration(name: "New Reader")
        try store.save(readers.map(\.registration) + [entry])
        do { try append(entry, startBluetooth: startBluetooth) }
        catch { try? store.save(readers.map(\.registration)); throw error }
        selectedID = entry.id
        return entry.id
    }

    func rename(_ reader: RegisteredReader, to name: String) throws {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
        guard !name.isEmpty else { return }
        var entry = reader.registration
        entry.name = name
        try save(entry)
    }

    func remove(_ reader: RegisteredReader) throws {
        guard !loadFailed else { throw ReaderRegistrationError.invalidRegistry }
        guard reader.model.canRemoveRegistration else { throw ReaderRegistrationError.busy }
        var entries = readers.filter { $0.id != reader.id }.map(\.registration)
        if entries.isEmpty { entries = [ReaderRegistration(name: "Your Reader")] }
        try store.save(entries)
        reader.workspace?.saveNow()
        reader.model.pauseForBackground()
        reader.model.bluetoothLink.forget()
        reader.model.bluetoothLink.requestSetupConnection = nil
        reader.model.bluetoothLink.endSetupConnection = nil
        observations.removeValue(forKey: reader.id)
        readers.removeAll { $0.id == reader.id }
        if readers.isEmpty, let first = entries.first { try append(first, startBluetooth: startBluetooth) }
        if selectedID == reader.id { selectedID = readers.first?.id }
        // Keep old files for recovery; removing a registration never erases books/drafts.
    }

    private func append(_ entry: ReaderRegistration, startBluetooth: Bool) throws {
        let storage: ReaderSessionStorage
        let link: ReaderBluetoothLink
        if entry.usesLegacyStorage {
            storage = .legacy
            if isolated {
                guard let defaults = UserDefaults(suiteName: "Pocket.reader." + entry.id.uuidString) else {
                    throw ReaderRegistrationError.invalidRegistry
                }
                link = ReaderBluetoothLink(transport: CoreBluetoothReaderTransport(restoresState: false),
                    store: RememberedBluetoothReaderStore(defaults: defaults), sync: .shared,
                    books: { LibraryModel.shared.books }, scheduler: TaskReaderLinkScheduler())
            } else { link = .shared }
        } else {
            guard let defaults = UserDefaults(suiteName: "Pocket.reader." + entry.id.uuidString) else {
                throw ReaderRegistrationError.invalidRegistry
            }
            storage = ReaderSessionStorage(root: root.appendingPathComponent(entry.id.uuidString), defaults: defaults)
            link = ReaderBluetoothLink(transport: CoreBluetoothReaderTransport(restorationIdentifier: "PocketReaderReadingSync." + entry.id.uuidString),
                store: RememberedBluetoothReaderStore(defaults: defaults), sync: .shared, books: {
                    let library = LibraryModel.shared
                    if library.books.isEmpty { await library.load() }
                    return library.books
                }, scheduler: TaskReaderLinkScheduler())
        }
        if let identity = entry.deviceID { storage.defaults.set(identity, forKey: "Pocket.lastReaderDeviceID") }
        if let host = entry.host { storage.defaults.set(host, forKey: "Pocket.lastReaderHost") }
        storage.defaults.set(entry.port, forKey: "Pocket.lastReaderPort")
        let model = modelFactory?(storage, link) ?? PocketModel(sessionStorage: storage, bluetoothLink: link)
        model.registrationName = entry.name
        if let hardware = entry.hardware ?? link.rememberedReader?.model { model.selectHardware(named: hardware) }
        let reader = RegisteredReader(registration: entry, model: model)
        model.acceptsReader = { [weak self, weak reader] status, host, port in
            guard let self, let reader else { return false }
            return (try? validate(reader, deviceID: status.deviceID, host: host, port: port)) != nil
        }
        model.registerReader = { [weak self, weak reader] status, host, port in
            guard let self, let reader else { throw ReaderRegistrationError.invalidRegistry }
            try validate(reader, deviceID: status.deviceID, host: host, port: port)
            var entry = reader.registration
            entry.deviceID = status.deviceID
            entry.host = host
            entry.port = port
            entry.hardware = status.device
            if entry.name == "Your Reader" || entry.name == "New Reader" {
                entry.name = readers.contains(where: { $0.id != reader.id && $0.registration.name == status.device })
                    ? status.device + " · " + String((status.deviceID ?? entry.id.uuidString).suffix(4)) : status.device
            }
            try save(entry)
        }
        model.acceptsBluetoothReader = { [weak self, weak reader] identity, peripheral in
            guard let self, let reader else { throw ReaderRegistrationError.invalidRegistry }
            try validate(reader, deviceID: identity, host: nil, port: 80)
            guard !readers.contains(where: { $0.id != reader.id && $0.model.bluetoothLink.rememberedReader?.peripheralID == peripheral }) else {
                throw ReaderRegistrationError.duplicate
            }
            var entry = reader.registration
            entry.deviceID = identity
            try save(entry)
        }
        model.acceptsPeripheral = { [weak self, weak reader] peripheral in
            guard let self, let reader else { return false }
            if let remembered = reader.model.bluetoothLink.rememberedReader { return remembered.peripheralID == peripheral }
            return !readers.contains { $0.id != reader.id && $0.model.bluetoothLink.rememberedReader?.peripheralID == peripheral }
        }
        model.networkAdmission = { [weak self, weak reader] direct in
            guard let self, let reader else { return ReaderRegistrationError.invalidRegistry.localizedDescription }
            if loadFailed { return ReaderRegistrationError.invalidRegistry.localizedDescription }
            let others = readers.filter { $0.id != reader.id }
            if let other = others.first(where: { $0.model.hasDirectSession }) {
                return "End the direct connection to \(other.registration.name) first. Direct Wi-Fi serves one reader at a time."
            }
            if direct, let other = others.first(where: { $0.model.readerStatus != nil || $0.model.hasNetworkActivity || $0.model.canCancelConnection }) {
                return "End the connection to \(other.registration.name) first. Direct connection changes Wi-Fi. Use Same Wi-Fi to keep multiple readers connected."
            }
            return nil
        }
        observations[entry.id] = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        readers.append(reader)
        reader.workspace = ReaderWorkspace(model: model)
        ReadingSync.shared.attachReader(model: model, library: .shared)
        link.bindAppState(to: model)
        if startBluetooth { link.start() }
    }

    private func validate(_ reader: RegisteredReader, deviceID: String?, host: String?, port: Int) throws {
        guard !loadFailed else { throw ReaderRegistrationError.invalidRegistry }
        let entry = reader.registration
        if let expected = entry.deviceID, deviceID != expected { throw ReaderRegistrationError.mismatch }
        if let deviceID {
            guard ReaderRegistration.validIdentity(deviceID) else { throw ReaderRegistrationError.unidentified }
            guard !readers.contains(where: { $0.id != reader.id && $0.registration.deviceID == deviceID }) else { throw ReaderRegistrationError.duplicate }
        } else {
            guard entry.usesLegacyStorage || readers.count == 1 else { throw ReaderRegistrationError.unidentified }
            if let knownHost = entry.host, host != knownHost || port != entry.port { throw ReaderRegistrationError.mismatch }
        }
        if let host, readers.contains(where: { $0.id != reader.id && $0.registration.host == host && $0.registration.port == port && ($0.registration.deviceID == nil || $0.model.readerStatus != nil) }) {
            throw ReaderRegistrationError.duplicate
        }
    }

    private func save(_ entry: ReaderRegistration) throws {
        guard !loadFailed else { throw ReaderRegistrationError.invalidRegistry }
        let updated = readers.map { $0.id == entry.id ? entry : $0.registration }
        try store.save(updated)
        if let reader = readers.first(where: { $0.id == entry.id }) {
            reader.registration = entry
            reader.model.registrationName = entry.name
        }
        objectWillChange.send()
    }
}
