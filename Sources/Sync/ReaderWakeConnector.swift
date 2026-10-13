import Foundation
import os

/// Foreground connection only. Reuses an existing bond and briefly rediscovers
/// its service if connection stalls. Never pairs or changes the Apple network.
@MainActor
final class ReaderWakeConnector {
    enum Observation: String { case connecting, connectionReset, pendingConnectionCancelled, discoveryStarted, knownAdvertisement, reconnectRequested, connected, authenticated, commandSent, accepted }
    // Bounded, identifier-free milestones for opted-in hardware verification.
    var observe: ((Observation) -> Void)?
    enum Phase: String { case idle, waiting, connecting, preparing, requesting }
    enum Failure: LocalizedError, Equatable {
        case unavailable, unsupported, wrongReader, timedOut(Phase), rejected
        case wifiOutcomeUnknown(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Bluetooth is unavailable or the paired reader is no longer known."
            case .unsupported: return "The reader is not offering Bluetooth wake."
            case .wrongReader: return "Bluetooth connected to a different reader."
            case .timedOut(let phase):
                switch phase {
                case .idle, .waiting: return "Bluetooth did not become ready."
                case .connecting: return "Could not establish a Bluetooth connection to the paired reader within 20 seconds."
                case .preparing: return "The reader connected, but its secure wake service did not become ready."
                case .requesting: return "The reader did not confirm the wake command. It may already be joining Wi-Fi."
                }
            case .wifiOutcomeUnknown: return "Wi-Fi details may have been accepted. Check the reader before sending again."
            case .rejected: return "The reader rejected the wake command."
            }
        }
    }
    private let transport: ReaderLinkTransport
    private let scheduler: ReaderLinkScheduling
    private var phase = Phase.idle {
        didSet {
            if oldValue != phase { ReadingSyncTrace.note("wake \(oldValue.rawValue) -> \(phase.rawValue)") }
        }
    }
    private var reader: RememberedBluetoothReader?
    private var pending: CheckedContinuation<Void, Error>?
    private var timeout: ReaderLinkTimer?
    private var discoveryTimer: ReaderLinkTimer?
    private var requestID = ""
    private var wifiCredentials: ReaderWiFiCredentials?
    private var configuringWiFi = false

    init(transport: ReaderLinkTransport? = nil, scheduler: ReaderLinkScheduling? = nil) {
        self.transport = transport ?? CoreBluetoothReaderTransport(restoresState: false)
        self.scheduler = scheduler ?? TaskReaderLinkScheduler()
        self.transport.onEvent = { [weak self] event in self?.handle(event) }
    }

    func configureWiFi(_ reader: RememberedBluetoothReader, credentials: ReaderWiFiCredentials) async throws -> String {
        guard credentials.validationMessage == nil, pending == nil else { throw Failure.rejected }
        wifiCredentials = credentials
        configuringWiFi = true
        defer { wifiCredentials = nil; configuringWiFi = false }
        try await wake(reader)
        return requestID
    }

    /// Check the Apple radio before asking an online reader to leave Wi-Fi.
    /// This requests no peripheral connection and sends no reader command.
    func ensureAvailable() async throws {
        guard pending == nil else { throw Failure.unavailable }
        reader = nil
        try await begin()
    }

    func wake(_ reader: RememberedBluetoothReader) async throws {
        guard pending == nil else { throw Failure.unavailable }
        self.reader = reader
        try await begin()
    }

    private func begin() async throws {
        try Task.checkCancellation()
        requestID = ""
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                phase = .waiting
                timeout = scheduler.schedule(after: 20, keepAwake: false) { [weak self] in
                    guard let self else { return }
                    self.finish(.failure(Failure.timedOut(self.phase)))
                }
                transport.activate()
                connectIfReady()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func connectIfReady() {
        guard phase == .waiting, transport.isAvailable else { return }
        guard let reader else { finish(.success(())); return }
        phase = .connecting
        observe?(.connecting)
        discoveryTimer = scheduler.schedule(after: 8, keepAwake: false) { [weak self] in
            guard let self, self.pending != nil, self.phase == .connecting else { return }
            ReadingSyncTrace.note("wake connection pending; discovering bonded service")
            self.transport.discoverKnownReader(reader.peripheralID)
        }
        if !transport.connect(to: reader.peripheralID) { finish(.failure(Failure.unavailable)) }
    }

    private func handle(_ event: ReaderLinkTransportEvent) {
        guard pending != nil else { return }
        if case .availabilityChanged(let available) = event {
            if available { connectIfReady() } else { finish(.failure(Failure.unavailable)) }
            return
        }
        guard let reader else { return }
        switch event {
        case .connectionReset: observe?(.connectionReset)
        case .pendingConnectionCancelled: observe?(.pendingConnectionCancelled)
        case .reconnectRequested: observe?(.reconnectRequested)
        case .discoveryStarted: observe?(.discoveryStarted)
        case .knownAdvertisement: observe?(.knownAdvertisement)
        case .availabilityChanged: break // Handled before the reader-specific events.
        case .connected(let identifier):
            guard phase == .connecting else { return }
            guard identifier == reader.peripheralID else { finish(.failure(Failure.wrongReader)); return }
            discoveryTimer?.cancel()
            discoveryTimer = nil
            observe?(.connected)
            phase = .preparing
            transport.prepareSession()
        case .ready(let bytes):
            guard phase == .preparing else { return }
            guard let text = String(data: bytes, encoding: .utf8),
                  let status = try? PocketDeviceStatus(record: text) else {
                finish(.failure(Failure.unsupported)); return
            }
            guard status.deviceID == reader.readerID else { finish(.failure(Failure.wrongReader)); return }
            guard status.protocolVersion == 1, status.capabilities.contains(wifiCredentials == nil ? "WAKE1" : "WIFI1") else {
                finish(.failure(Failure.unsupported)); return
            }
            observe?(.authenticated)
            requestID = NearbySyncProtocol.requestID()
            let record: Data?
            if let wifiCredentials { record = wifiCredentials.command(requestID: requestID) }
            else { record = NearbySyncProtocol.startWifi(requestID: requestID) }
            guard let command = record else {
                finish(.failure(Failure.unsupported)); return
            }
            phase = .requesting
            observe?(.commandSent)
            transport.write(command)
            wifiCredentials = nil
        case .received(let bytes):
            guard phase == .requesting, let text = String(data: bytes, encoding: .utf8) else { return }
            if text == "OK \(requestID)" { finish(.success(())) }
            else if text.hasPrefix("ERR \(requestID) ") { finish(.failure(Failure.rejected)) }
        case .wrote(let error):
            if let error { finish(.failure(error)) }
        case .failed(let error): finish(.failure(error))
        case .disconnected(let error): finish(.failure(error ?? Failure.unavailable))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation = pending else { return }
        switch result {
        case .success:
            observe?(.accepted)
            ReadingSyncTrace.note("wake accepted")
        case .failure(let error):
            // Only our bounded categories; platform error text can contain identifiers.
            let category = error is CancellationError ? "cancelled"
                : (error as? Failure).map { String(describing: $0) } ?? "transport-error"
            ReadingSyncTrace.note("wake failed at \(phase.rawValue): \(category)")
            Logger(subsystem: "bound.serendipity.pocket.daily", category: "ReaderWake")
                .error("Wake failed at \(self.phase.rawValue, privacy: .public): \(category, privacy: .public)")
        }
        pending = nil
        phase = .idle
        timeout?.cancel()
        timeout = nil
        discoveryTimer?.cancel()
        discoveryTimer = nil
        transport.cancelConnection()
        if configuringWiFi, case .failure(let error) = result,
           !(error is CancellationError), (error as? Failure) != .rejected, !requestID.isEmpty {
            continuation.resume(throwing: Failure.wifiOutcomeUnknown(requestID))
        } else {
            continuation.resume(with: result)
        }
    }
}
