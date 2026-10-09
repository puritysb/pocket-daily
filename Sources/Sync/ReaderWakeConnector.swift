import Foundation

/// Foreground connection only. Reuses an existing bond, never scans, pairs,
/// joins a hotspot or changes the Apple device's network.
@MainActor
final class ReaderWakeConnector {
    enum Failure: Error, Equatable { case unavailable, unsupported, wrongReader, timedOut, rejected }
    private enum Phase { case idle, waiting, connecting, preparing, requesting }
    private let transport: ReaderLinkTransport
    private let scheduler: ReaderLinkScheduling
    private var phase = Phase.idle
    private var reader: RememberedBluetoothReader?
    private var pending: CheckedContinuation<Void, Error>?
    private var timeout: ReaderLinkTimer?
    private var requestID = ""

    init(transport: ReaderLinkTransport? = nil, scheduler: ReaderLinkScheduling? = nil) {
        self.transport = transport ?? CoreBluetoothReaderTransport(restoresState: false)
        self.scheduler = scheduler ?? TaskReaderLinkScheduler()
        self.transport.onEvent = { [weak self] event in self?.handle(event) }
    }

    func wake(_ reader: RememberedBluetoothReader) async throws {
        guard pending == nil else { throw Failure.unavailable }
        try Task.checkCancellation()
        self.reader = reader
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                phase = .waiting
                timeout = scheduler.schedule(after: 20, keepAwake: false) { [weak self] in
                    self?.finish(.failure(Failure.timedOut))
                }
                transport.activate()
                connectIfReady()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func connectIfReady() {
        guard phase == .waiting, transport.isAvailable, let reader else { return }
        phase = .connecting
        if !transport.connect(to: reader.peripheralID) { finish(.failure(Failure.unavailable)) }
    }

    private func handle(_ event: ReaderLinkTransportEvent) {
        guard pending != nil, let reader else { return }
        switch event {
        case .availabilityChanged(let available):
            if available { connectIfReady() } else { finish(.failure(Failure.unavailable)) }
        case .connected(let identifier):
            guard phase == .connecting else { return }
            guard identifier == reader.peripheralID else { finish(.failure(Failure.wrongReader)); return }
            phase = .preparing
            transport.prepareSession()
        case .ready(let bytes):
            guard phase == .preparing else { return }
            guard let text = String(data: bytes, encoding: .utf8),
                  let status = try? PocketDeviceStatus(record: text) else {
                finish(.failure(Failure.unsupported)); return
            }
            guard status.deviceID == reader.readerID else { finish(.failure(Failure.wrongReader)); return }
            guard status.protocolVersion == 1, status.capabilities.contains("WAKE1") else {
                finish(.failure(Failure.unsupported)); return
            }
            requestID = NearbySyncProtocol.requestID()
            guard let command = NearbySyncProtocol.startWifi(requestID: requestID) else {
                finish(.failure(Failure.unsupported)); return
            }
            phase = .requesting
            transport.write(command)
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
        pending = nil
        phase = .idle
        timeout?.cancel()
        timeout = nil
        transport.cancelConnection()
        continuation.resume(with: result)
    }
}
