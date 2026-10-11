import Combine
import CoreLocation
import Foundation
#if os(macOS)
import CoreWLAN
import Security
#else
import NetworkExtension
#endif

/// Reads only the current network name, on explicit user request. No location
/// updates, scanning, network changes, or credential storage. The separate Mac
/// password lookup is called only by the same explicit autofill action.
@MainActor
final class CurrentWiFiName: ObservableObject {
    enum Failure: LocalizedError {
        case permission, preciseLocation, unavailable

        var errorDescription: String? {
            switch self {
            case .permission:
                "Allow location access for Pocket Daily in System Settings to read the Wi-Fi name, or enter it yourself."
            case .preciseLocation:
                "Enable Precise Location for Pocket Daily to read the Wi-Fi name, or enter it yourself. Your coordinates are not read."
            case .unavailable:
                "The current Wi-Fi name is unavailable. Check that this device is on Wi-Fi, or enter the name yourself."
            }
        }
    }

    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    private let fetch: @MainActor () async throws -> String?

    init(fetch: @escaping @MainActor () async throws -> String? = { try await CurrentWiFiName.fetchSystemName() }) {
        self.fetch = fetch
    }

    func read() async -> String? {
        guard !isLoading else { return nil }
        isLoading = true
        message = nil
        defer { isLoading = false }
        do {
            let name = try await fetch()
            try Task.checkCancellation()
            guard let name, ReaderWiFiCredentials(ssid: name, password: "").validationMessage == nil else {
                throw Failure.unavailable
            }
            return name
        } catch is CancellationError {
            return nil
        } catch {
            message = (error as? Failure)?.localizedDescription ?? Failure.unavailable.localizedDescription
            return nil
        }
    }

    private static func isAuthorized(_ status: CLAuthorizationStatus) -> Bool {
#if os(macOS)
        status == .authorizedAlways
#else
        status == .authorizedAlways || status == .authorizedWhenInUse
#endif
    }

#if os(macOS)
    /// User-selected current network only. macOS owns any authentication UI.
    /// Never inspect other keychain entries or relax the app's sandbox.
    static func savedPassword(for name: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled, CWWiFiClient.shared().interface()?.ssid() == name else { return nil }
            var password: NSString?
            let status = CWKeychainFindWiFiPassword(.system, Data(name.utf8), &password)
            defer { password = nil }
            guard status == errSecSuccess, let password, password.length > 0,
                  CWWiFiClient.shared().interface()?.ssid() == name else { return nil }
            return password as String
        }.value
    }
#endif

    private static func fetchSystemName() async throws -> String? {
        // Creating a manager and asking permission happens only after the tap.
        let manager = CLLocationManager()
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            break
        default:
            throw Failure.permission
        }
        // Bound the wait, including a system prompt left unanswered. Polling
        // avoids holding a continuation after a dismissed/cancelled sheet.
        let deadline = ContinuousClock.now + .seconds(30)
        while manager.authorizationStatus == .notDetermined, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        try Task.checkCancellation()
        guard isAuthorized(manager.authorizationStatus) else {
            throw Failure.permission
        }
#if os(macOS)
        return await Task.detached(priority: .userInitiated) {
            CWWiFiClient.shared().interface()?.ssid()
        }.value
#else
        guard manager.accuracyAuthorization == .fullAccuracy else { throw Failure.preciseLocation }
        return await NEHotspotNetwork.fetchCurrent()?.ssid
#endif
    }
}
