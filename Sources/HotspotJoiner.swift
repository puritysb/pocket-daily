import Foundation

#if os(iOS)
import NetworkExtension

enum HotspotJoiner {
    static func join(_ lease: HotspotLease) async throws {
        let configuration = NEHotspotConfiguration(ssid: lease.ssid, passphrase: lease.passphrase, isWEP: false)
        configuration.joinOnce = true
        try await NEHotspotConfigurationManager.shared.apply(configuration)
    }
}
#elseif os(macOS)
import AppKit
import CoreLocation
import CoreWLAN

@MainActor
enum HotspotJoiner {
    static func join(_ lease: HotspotLease) async throws {
        // CoreWLAN scanning is location-gated on modern macOS. Ask once, then
        // perform the blocking scan/association off the UI actor. The
        // passphrase came through the authenticated BLE channel and is never
        // written to Pocket's logs or preferences.
        try await LocationAuthorization.shared.authorize()

        let ssid = lease.ssid
        let passphrase = lease.passphrase
        try await Task.detached(priority: .userInitiated) {
            guard let interface = CWWiFiClient.shared().interface() else {
                throw HotspotJoinError.noWiFiInterface
            }

            let matchingNetwork: (Set<CWNetwork>?) -> CWNetwork? = { networks in
                networks?
                    .filter { $0.ssid == ssid }
                    .max(by: { $0.rssiValue < $1.rssiValue })
            }
            let ssidData = Data(ssid.utf8)
            let deadline = ContinuousClock.now + .seconds(20)
            var lastScanError: Error?
            while ContinuousClock.now < deadline {
                // macOS System Settings refreshes CoreWLAN's cache even when a
                // directed scan returns no rows. Prefer that fresh cache, then
                // fall back to both broadcast and directed scans. ESP32 soft APs
                // have been observed in the system Wi-Fi list while
                // scanForNetworks(withName:) still returns an empty set.
                if let network = matchingNetwork(interface.cachedScanResults()) {
                    try interface.associate(to: network, password: passphrase)
                    return
                }
                do {
                    let networks = try interface.scanForNetworks(withName: nil)
                    if let network = matchingNetwork(networks) {
                        try interface.associate(to: network, password: passphrase)
                        return
                    }
                } catch {
                    lastScanError = error
                }
                do {
                    let networks = try interface.scanForNetworks(withSSID: ssidData, includeHidden: true)
                    if let network = matchingNetwork(networks) {
                        try interface.associate(to: network, password: passphrase)
                        return
                    }
                } catch {
                    lastScanError = error
                }
                try await Task.sleep(for: .milliseconds(500))
            }

            if let lastScanError { throw lastScanError }
            throw HotspotJoinError.networkNotFound(ssid)
        }.value
    }

    static func openLocationSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
private final class LocationAuthorization: NSObject, @preconcurrency CLLocationManagerDelegate {
    static let shared = LocationAuthorization()

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Void, Error>?

    private override init() {
        super.init()
        manager.delegate = self
    }

    func authorize() async throws {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return
        case .denied, .restricted:
            throw HotspotJoinError.locationPermissionRequired
        case .notDetermined:
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                manager.requestWhenInUseAuthorization()
            }
        @unknown default:
            throw HotspotJoinError.locationPermissionRequired
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let continuation else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            self.continuation = nil
            continuation.resume()
        case .denied, .restricted:
            self.continuation = nil
            continuation.resume(throwing: HotspotJoinError.locationPermissionRequired)
        case .notDetermined:
            break
        @unknown default:
            self.continuation = nil
            continuation.resume(throwing: HotspotJoinError.locationPermissionRequired)
        }
    }
}

enum HotspotJoinError: LocalizedError, Equatable {
    case noWiFiInterface
    case locationPermissionRequired
    case networkNotFound(String)

    var errorDescription: String? {
        switch self {
        case .noWiFiInterface:
            "No Wi-Fi interface is available on this Mac."
        case .locationPermissionRequired:
            "Allow Pocket to use Location Services so it can find the reader's temporary Wi-Fi network."
        case let .networkNotFound(ssid):
            "Pocket could not find \(ssid). You can still join it manually below."
        }
    }
}
#endif
