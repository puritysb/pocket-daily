import Foundation

@MainActor
final class LocalReaderDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var continuation: CheckedContinuation<(host: String, port: Int)?, Never>?
    private var timeoutTask: Task<Void, Never>?

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
