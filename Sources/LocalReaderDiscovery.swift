import Darwin
import Foundation

/// The same discovery state machine uses real networking or controlled test IO.
@MainActor
protocol ReaderDiscoveryIO {
    var rememberedHost: String? { get }
    func candidates() -> [String]
    func firstBonjour(timeout: Duration) async -> (host: String, port: Int)?
    func stop()
    func status(host: String, port: Int, timeout: TimeInterval) async throws -> CrossPointStatus
}

@MainActor
final class LiveReaderDiscoveryIO: ReaderDiscoveryIO {
    private let browser = LocalReaderDiscovery()
    private let client: CrossPointClient
    private let rememberedHostKey: String
    private let defaults: UserDefaults

    init(client: CrossPointClient, rememberedHostKey: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.client = client
        self.rememberedHostKey = rememberedHostKey
    }

    var rememberedHost: String? { defaults.string(forKey: rememberedHostKey) }
    func candidates() -> [String] { ["192.168.4.1"] + LocalReaderDiscovery.localIPv4Candidates() }
    func firstBonjour(timeout: Duration) async -> (host: String, port: Int)? {
        await browser.first(timeout: timeout)
    }
    func stop() { browser.stop() }
    func status(host: String, port: Int, timeout: TimeInterval) async throws -> CrossPointStatus {
        try await client.status(host: host, port: port, timeout: timeout)
    }
}

#if DEBUG
/// UI automation must never assume that a user's physical LAN has no readers.
@MainActor
final class EmptyReaderDiscoveryIO: ReaderDiscoveryIO {
    let delay: Duration
    init(delay: Duration = .zero) { self.delay = delay }
    var rememberedHost: String? { nil }
    func candidates() -> [String] { [] }
    func firstBonjour(timeout: Duration) async -> (host: String, port: Int)? {
        try? await Task.sleep(for: delay)
        return nil
    }
    func stop() {}
    func status(host: String, port: Int, timeout: TimeInterval) async throws -> CrossPointStatus {
        throw URLError(.cannotConnectToHost)
    }
}
#endif

@MainActor
final class LocalReaderDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var continuation: CheckedContinuation<(host: String, port: Int)?, Never>?
    private var timeoutTask: Task<Void, Never>?

    /// Bonjour is intentionally absent from the X3's low-memory File Transfer
    /// profile. Build a bounded list from active IPv4 interfaces so the app can
    /// still find the reader after DHCP changes. Nearby addresses are tried
    /// first; a /22 home network remains fully covered.
    nonisolated static func localIPv4Candidates(limitPerInterface: Int = 2_048) -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var candidatesByInterface: [[String]] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = cursor?.pointee {
            defer { cursor = interface.ifa_next }
            guard let addressPointer = interface.ifa_addr,
                  let maskPointer = interface.ifa_netmask,
                  addressPointer.pointee.sa_family == UInt8(AF_INET),
                  (interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == UInt32(IFF_UP | IFF_RUNNING)
            else { continue }

            let address = addressPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask = maskPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            candidatesByInterface.append(
                ipv4Candidates(address: address, netmask: mask, limit: limitPerInterface)
            )
        }
        return interleaveCandidates(candidatesByInterface)
    }

    /// Two active interfaces can share one subnet (for example, Wi-Fi and a
    /// nearby-device interface). Interleave them so a reader adjacent to either
    /// address is checked immediately instead of after one full subnet sweep.
    nonisolated static func interleaveCandidates(_ lists: [[String]]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        let longest = lists.map(\.count).max() ?? 0
        result.reserveCapacity(lists.reduce(0) { $0 + $1.count })
        for index in 0 ..< longest {
            for list in lists where index < list.count {
                let host = list[index]
                if seen.insert(host).inserted { result.append(host) }
            }
        }
        return result
    }

    nonisolated static func ipv4Candidates(address: UInt32, netmask: UInt32, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let network = address & netmask
        let broadcast = network | ~netmask
        guard broadcast > network + 1 else { return [] }

        let first = network + 1
        let last = broadcast - 1
        let available = Int(min(UInt64(last - first + 1), UInt64(limit)))
        var values: [UInt32] = []
        values.reserveCapacity(available)

        var distance: UInt32 = 1
        while values.count < available {
            var added = false
            if address >= first + distance {
                values.append(address - distance)
                added = true
                if values.count >= available { break }
            }
            if address <= last - distance {
                values.append(address + distance)
                added = true
            }
            if !added { break }
            distance += 1
        }

        return values.map {
            "\(($0 >> 24) & 0xFF).\(($0 >> 16) & 0xFF).\(($0 >> 8) & 0xFF).\($0 & 0xFF)"
        }
    }

    func first(timeout: Duration = .seconds(5)) async -> (host: String, port: Int)? {
        stop()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            browser.delegate = self
            browser.searchForServices(ofType: "_crosspoint._tcp.", inDomain: "local.")
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(nil)
            }
        }
    }

    func stop() {
        browser.stop()
        services.forEach { $0.stop() }
        services.removeAll()
        timeoutTask?.cancel()
        timeoutTask = nil
        finish(nil)
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        Task { @MainActor in
            services.append(service)
            service.delegate = self
            service.resolve(withTimeout: 3)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor in
            guard let hostname = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                  !hostname.isEmpty else { return }
            finish((hostname, sender.port))
        }
    }

    private func finish(_ endpoint: (host: String, port: Int)?) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        browser.stop()
        services.forEach { $0.stop() }
        services.removeAll()
        continuation.resume(returning: endpoint)
    }
}
