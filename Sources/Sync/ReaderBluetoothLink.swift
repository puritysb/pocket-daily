import Combine
import Foundation
import os

/// The reader paired once through Nearby Sync: the system's peripheral
/// identifier and the reader ID from its authenticated status record. The
/// passkey and hotspot credentials are never stored.
struct RememberedBluetoothReader: Codable, Equatable {
    var peripheralID: UUID
    var readerID: String
    var model: String
}

/// Keeps the remembered reader in `UserDefaults`.
final class RememberedBluetoothReaderStore {
    private static let key = "readerLink.remembered.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var reader: RememberedBluetoothReader? {
        get {
            defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(RememberedBluetoothReader.self, from: $0) }
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Self.key)
            } else {
                defaults.removeObject(forKey: Self.key)
            }
        }
    }
}

/// What the link needs from CoreBluetooth; a fake drives the state machine in tests.
@MainActor
protocol ReaderLinkTransport: AnyObject {
    var onEvent: ((ReaderLinkTransportEvent) -> Void)? { get set }
    /// Bluetooth is powered on and allowed.
    var isAvailable: Bool { get }
    /// Starts Bluetooth for the link; reports availability through `onEvent`.
    func activate()
    /// Keeps a pending connection to a known peripheral, completed by the system
    /// whenever it advertises. False when the system does not know the peripheral.
    func connect(to peripheral: UUID) -> Bool
    /// Cancels the pending or active connection.
    func cancelConnection()
    /// Discovers the service, subscribes to events and reads the status record;
    /// answers `.ready(status:)` or `.failed`.
    func prepareSession()
    /// Writes one command record with response; answers `.wrote`.
    func write(_ record: Data)
}

enum ReaderLinkTransportEvent {
    case availabilityChanged(Bool)
    case connected(UUID)
    case ready(status: Data)
    case received(Data)
    case wrote(Error?)
    case failed(Error)
    case disconnected(Error?)
}

/// Delays the link's timeouts and re-arming; tests fire them by hand.
@MainActor
protocol ReaderLinkScheduling {
    /// `keepAwake`: the action must run even if the app is suspended meanwhile
    /// (re-arming); it may then run early. Timeouts need not: a suspended app
    /// is woken by the disconnection when the reader's window ends.
    func schedule(after seconds: TimeInterval, keepAwake: Bool,
                  _ action: @escaping @MainActor () -> Void) -> ReaderLinkTimer
}

@MainActor
protocol ReaderLinkTimer: AnyObject {
    func cancel()
}

/// Exchanges reading places with the paired reader over Bluetooth whenever it
/// opens an exchange window (reading-sync-ble-v1): a book closed, the reader
/// woke or is going to sleep. It keeps a pending connection to that one
/// reader, never scans and never pairs; it stands down while Nearby Sync owns
/// Bluetooth, in demo mode, and when reader exchange is off. Places are merged
/// with the same rules as the Wi-Fi exchange and never move a page.
@MainActor
final class ReaderBluetoothLink: ObservableObject {
    enum Phase: Equatable {
        /// Not armed: nothing remembered, exchange off, demo, Nearby Sync active or Bluetooth off.
        case off
        /// A pending connection waits for the reader to advertise.
        case waiting
        case preparing
        case listing
        case merging
        case offering
        /// After a session, before the pending connection is re-armed.
        case coolingDown
    }

    struct Timing {
        /// Service discovery, subscription and the status read.
        var prepare: TimeInterval = 15
        /// Silence allowed between records once the exchange runs.
        var step: TimeInterval = 10
        /// The whole connection.
        var session: TimeInterval = 60
        /// Before re-arming; longer than the reader's longest window (45 s), so
        /// one window gives one exchange.
        var cooldown: TimeInterval = 60
    }

    static let shared = ReaderBluetoothLink(
        transport: CoreBluetoothReaderTransport(),
        store: RememberedBluetoothReaderStore(),
        sync: .shared,
        books: {
            // A background relaunch starts without the library loaded.
            let library = LibraryModel.shared
            if library.books.isEmpty { await library.load() }
            return library.books
        },
        scheduler: TaskReaderLinkScheduler()
    )

    @Published private(set) var phase: Phase = .off
    @Published private(set) var rememberedReader: RememberedBluetoothReader?

    /// Pairing for reading sync from Settings: the reader's Sync screen is open and
    /// the app connects once (Nearby Sync, authenticated) only to remember it.
    enum Setup: Equatable {
        case idle
        case searching
        case paired(String)
        case failed(String)
    }
    @Published var setup: Setup = .idle
    /// Set by the app shell: starts the explicit Nearby Sync connection.
    var requestSetupConnection: (() -> Void)?
    /// Set by the app shell: ends it once the reader is remembered.
    var endSetupConnection: (() -> Void)?

    func beginSetup() {
        guard !isDemoMode, let requestSetupConnection else { return }
        setup = .searching
        requestSetupConnection()
    }

    func cancelSetup() {
        guard setup == .searching else { return }
        setup = .idle
        endSetupConnection?()
    }

    /// Stops reading sync with the remembered reader (a new pairing replaces it).
    func forget() {
        if session != nil { endSession(error: nil, report: false) }
        cooldownTimer?.cancel()
        cooldownTimer = nil
        if phase != .off { transport.cancelConnection() }
        phase = .off
        store.reader = nil
        rememberedReader = nil
        setup = .idle
    }

    /// The explicit Sync flow owns Bluetooth while this is set.
    var nearbySessionActive = false {
        didSet { if oldValue != nearbySessionActive { update() } }
    }
    var isDemoMode = false {
        didSet { if oldValue != isDemoMode { update() } }
    }

    private let transport: ReaderLinkTransport
    private let store: RememberedBluetoothReaderStore
    private let sync: ReadingSync
    private let books: @MainActor () async -> [LibraryBook]
    private let scheduler: ReaderLinkScheduling
    private let timing: Timing
    private let log = Logger(subsystem: "bound.serendipity.pocket.daily", category: "ReaderBluetoothLink")
    private var exchangeEnabled: Bool
    private var enabledObserver: AnyCancellable?
    private var started = false
    private var session: Session?
    private var generation = 0
    private var sessionTimer: ReaderLinkTimer?
    private var stepTimer: ReaderLinkTimer?
    private var cooldownTimer: ReaderLinkTimer?
    /// The merge step waits for the library; tests await it.
    private(set) var mergeTask: Task<Void, Never>?

    private struct Session {
        let reader: RememberedBluetoothReader
        let generation: Int
        var readerName: String
        var requestID: String?
        var assembler: ReadingListAssembler?
        /// `ReadingSync.exchange` ran, so `exchangeFinished` is owed.
        var exchanged = false
        var offers: [PositionRecord] = []
        var nextOffer = 0
        var records: [Data] = []
        var writing = false
        var acknowledged = false
        var sent = 0
    }

    init(transport: ReaderLinkTransport, store: RememberedBluetoothReaderStore, sync: ReadingSync,
         books: @escaping @MainActor () async -> [LibraryBook], scheduler: ReaderLinkScheduling,
         timing: Timing = Timing()) {
        self.transport = transport
        self.store = store
        self.sync = sync
        self.books = books
        self.scheduler = scheduler
        self.timing = timing
        exchangeEnabled = sync.readerExchangeEnabled
        rememberedReader = store.reader
        transport.onEvent = { [weak self] event in self?.handle(event) }
        enabledObserver = sync.$readerExchangeEnabled.dropFirst().removeDuplicates().sink { [weak self] enabled in
            guard let self else { return }
            exchangeEnabled = enabled
            update()
        }
    }

    /// Called at launch (including a background relaunch that restores the
    /// pending connection) and when the app becomes active. Bluetooth is only
    /// started once a reader was paired, so this never prompts for permission.
    func start() {
        started = true
        update()
    }

    /// Remembers a reader after an authenticated Nearby Sync connection.
    func remember(peripheral: UUID, readerID: String, model: String) {
        let reader = RememberedBluetoothReader(peripheralID: peripheral, readerID: readerID, model: model)
        if setup == .searching {
            setup = .paired(model)
            endSetupConnection?()
        }
        guard reader != rememberedReader else { return }
        if session != nil { endSession(error: nil, report: false) }
        store.reader = reader
        rememberedReader = reader
        cooldownTimer?.cancel()
        cooldownTimer = nil
        if phase != .off { transport.cancelConnection() }
        phase = .off
        update()
    }

    private var shouldArm: Bool {
        started && exchangeEnabled && !isDemoMode && !nearbySessionActive && rememberedReader != nil
    }

    /// Arms the pending connection when allowed; stands down at once otherwise.
    private func update() {
        guard shouldArm, let reader = rememberedReader else {
            if session != nil { endSession(error: ReadingSyncBLEError.interrupted, report: false, rearm: false) }
            cooldownTimer?.cancel()
            cooldownTimer = nil
            if phase != .off {
                transport.cancelConnection()
                phase = .off
            }
            return
        }
        guard phase == .off else { return }
        transport.activate()
        guard transport.isAvailable else { return }
        // Waiting before connecting: a restored connection reports at once.
        phase = .waiting
        if !transport.connect(to: reader.peripheralID) {
            phase = .off
            log.info("Paired reader is unknown to Bluetooth; waiting for a new pairing")
        }
    }

    private func rearmLater() {
        phase = .coolingDown
        cooldownTimer?.cancel()
        cooldownTimer = scheduler.schedule(after: timing.cooldown, keepAwake: true) { [weak self] in
            guard let self, phase == .coolingDown else { return }
            cooldownTimer = nil
            phase = .off
            update()
        }
    }

    // MARK: Transport events

    private func handle(_ event: ReaderLinkTransportEvent) {
        switch event {
        case let .availabilityChanged(available):
            if available {
                update()
            } else {
                if session != nil { endSession(error: ReadingSyncBLEError.interrupted, report: false, rearm: false) }
                cooldownTimer?.cancel()
                cooldownTimer = nil
                phase = .off
            }
        case let .connected(peripheral):
            guard phase == .waiting, let reader = rememberedReader, reader.peripheralID == peripheral else {
                if session == nil { transport.cancelConnection() }
                return
            }
            generation += 1
            session = Session(reader: reader, generation: generation, readerName: reader.model)
            phase = .preparing
            let generation = generation
            sessionTimer = scheduler.schedule(after: timing.session, keepAwake: false) { [weak self] in
                self?.timedOut(generation)
            }
            resetStepTimer(timing.prepare)
            transport.prepareSession()
        case let .ready(status):
            guard phase == .preparing, session != nil else { return }
            begin(statusRecord: status)
        case let .received(record):
            guard session != nil else { return }
            received(record)
        case let .wrote(error):
            guard session != nil else { return }
            if let error { endSession(error: error, report: session?.exchanged == true); return }
            wrote()
        case let .failed(error):
            guard session != nil else { return }
            endSession(error: error, report: session?.exchanged == true)
        case let .disconnected(error):
            if session != nil {
                endSession(error: error ?? ReadingSyncBLEError.interrupted, report: session?.exchanged == true,
                           disconnected: true)
            } else if phase == .waiting {
                // A failed pending connection: try again after the window.
                rearmLater()
            }
        }
    }

    private func begin(statusRecord: Data) {
        guard let text = String(data: statusRecord, encoding: .utf8),
              let status = try? PocketDeviceStatus(record: text), var session else {
            endSession(error: NearbySyncError.malformedRecord, report: false)
            return
        }
        guard status.deviceID == session.reader.readerID else {
            log.info("Paired peripheral reported another reader ID; disconnecting")
            endSession(error: nil, report: false)
            return
        }
        guard status.capabilities.contains(ReadingSyncBLE.capability) else {
            log.info("Reader firmware does not offer reading sync over Bluetooth")
            endSession(error: nil, report: false)
            return
        }
        let requestID = NearbySyncProtocol.requestID()
        guard let command = ReadingSyncBLE.readList(requestID: requestID) else {
            endSession(error: NearbySyncError.malformedRecord, report: false)
            return
        }
        session.readerName = status.model
        session.requestID = requestID
        session.assembler = ReadingListAssembler(requestID: requestID)
        session.writing = true
        self.session = session
        phase = .listing
        resetStepTimer(timing.step)
        transport.write(command)
    }

    private func received(_ record: Data) {
        guard var session, let requestID = session.requestID else { return }
        let event: ReadingSyncBLE.Event?
        do { event = try ReadingSyncBLE.parseEvent(record) }
        catch {
            endSession(error: phase == .listing ? ReadingSyncBLEError.corruptList : error, report: true)
            return
        }
        guard let event else { return }
        switch (phase, event) {
        case let (.listing, .data(id, seq, chunk)) where id == requestID:
            do {
                try session.assembler?.add(seq: seq, chunk: chunk)
                self.session = session
                resetStepTimer(timing.step)
            } catch {
                endSession(error: error, report: true)
            }
        case let (.listing, .end(id, total, crc)) where id == requestID:
            do {
                guard let body = try session.assembler?.finish(total: total, crc: crc) else { return }
                let list = try ReaderReadingList.decode(body, deviceID: session.reader.readerID)
                merge(list)
            } catch {
                endSession(error: error, report: true)
            }
        case let (.listing, .error(id, code)) where id == requestID:
            endSession(error: ReadingSyncBLEError.rejected(code), report: true)
        case let (.offering, .ok(id)) where id == requestID:
            session.acknowledged = true
            self.session = session
            resetStepTimer(timing.step)
            if !session.writing && session.records.isEmpty { offerNext() }
        case let (.offering, .error(id, code)) where id == requestID:
            if code == "UNKNOWN_DOCUMENT" {
                // As over HTTP (404): the reader no longer has that book. Any
                // chunks left are dropped; the next offer waits for a write in flight.
                session.records = []
                session.acknowledged = true
                session.sent -= 1
                self.session = session
                if !session.writing { offerNext() }
            } else {
                endSession(error: ReadingSyncBLEError.rejected(code), report: true)
            }
        default:
            break
        }
    }

    private func merge(_ list: ReaderReadingList) {
        phase = .merging
        stepTimer?.cancel()
        let generation = session?.generation
        mergeTask = Task { [weak self] in
            guard let self else { return }
            let library = await books()
            guard var session, session.generation == generation, phase == .merging else { return }
            let offers = sync.exchange(with: list, readerName: session.readerName, library: library)
            session.exchanged = true
            session.offers = Array(offers.prefix(ReadingSyncBLE.maximumOffers))
            self.session = session
            phase = .offering
            offerNext()
        }
    }

    /// Sends the next offer, or finishes once every offer was answered.
    private func offerNext() {
        guard var session else { return }
        while session.nextOffer < session.offers.count {
            let record = session.offers[session.nextOffer]
            session.nextOffer += 1
            let requestID = NearbySyncProtocol.requestID()
            guard let body = try? CrossPointClient.readingOfferBody(record, identity: session.reader.readerID),
                  var records = ReadingSyncBLE.offerRecords(requestID: requestID, body: body) else {
                continue
            }
            session.requestID = requestID
            session.acknowledged = false
            session.sent += 1
            session.writing = true
            let first = records.removeFirst()
            session.records = records
            self.session = session
            resetStepTimer(timing.step)
            transport.write(first)
            return
        }
        self.session = session
        endSession(error: nil, report: true)
    }

    private func wrote() {
        guard var session else { return }
        session.writing = false
        resetStepTimer(timing.step)
        guard phase == .offering else {
            self.session = session
            return
        }
        if !session.records.isEmpty {
            session.writing = true
            let next = session.records.removeFirst()
            self.session = session
            transport.write(next)
        } else {
            self.session = session
            if session.acknowledged { offerNext() }
        }
    }

    // MARK: Ending

    private func resetStepTimer(_ seconds: TimeInterval) {
        stepTimer?.cancel()
        guard let generation = session?.generation else { return }
        stepTimer = scheduler.schedule(after: seconds, keepAwake: false) { [weak self] in self?.timedOut(generation) }
    }

    private func timedOut(_ generation: Int) {
        guard let session, session.generation == generation else { return }
        endSession(error: ReadingSyncBLEError.timedOut, report: session.exchanged)
    }

    /// Ends the connection. The exchange is reported once it began merging (the
    /// places received are kept either way), and a failure of the reader's
    /// list is reported; a reader that is simply gone, another reader or older
    /// firmware is left quietly. The pending connection is re-armed afterwards.
    private func endSession(error: Error?, report: Bool, rearm: Bool = true, disconnected: Bool = false) {
        guard let session else { return }
        self.session = nil
        sessionTimer?.cancel()
        sessionTimer = nil
        stepTimer?.cancel()
        stepTimer = nil
        mergeTask?.cancel()
        mergeTask = nil
        if session.exchanged {
            sync.exchangeFinished(readerName: session.readerName, sent: session.sent, error: error)
        } else if report, let error {
            sync.exchangeFinished(readerName: session.readerName, sent: 0, error: error)
        }
        if let error { log.info("Bluetooth reading exchange ended: \(error.localizedDescription, privacy: .public)") }
        if !disconnected { transport.cancelConnection() }
        if rearm { rearmLater() } else { phase = .off }
    }
}

/// Timers on the main actor. On iOS a `keepAwake` timer holds a background
/// task; when the system grants none or ends it early, the action runs at once,
/// so the pending connection is always re-armed before the app is suspended.
@MainActor
final class TaskReaderLinkScheduler: ReaderLinkScheduling {
    func schedule(after seconds: TimeInterval, keepAwake: Bool,
                  _ action: @escaping @MainActor () -> Void) -> ReaderLinkTimer {
        TaskReaderLinkTimer(after: seconds, keepAwake: keepAwake, action: action)
    }
}

@MainActor
private final class TaskReaderLinkTimer: ReaderLinkTimer {
    private var task: Task<Void, Never>?
    private var action: (@MainActor () -> Void)?
    private var background = BackgroundActivity()

    init(after seconds: TimeInterval, keepAwake: Bool, action: @escaping @MainActor () -> Void) {
        self.action = action
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.fire()
        }
        if keepAwake, !background.begin(expired: { [weak self] in self?.fire() }) {
            // No background time left: run now rather than never.
            Task { [weak self] in self?.fire() }
        }
    }

    private func fire() {
        guard let action else { return }
        self.action = nil
        task?.cancel()
        background.end()
        action()
    }

    func cancel() {
        action = nil
        task?.cancel()
        background.end()
    }
}
