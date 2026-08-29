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
#else
enum HotspotJoiner {
    static func join(_ lease: HotspotLease) async throws {
        throw HotspotJoinError.manualConnectionRequired(lease.ssid)
    }
}

enum HotspotJoinError: LocalizedError {
    case manualConnectionRequired(String)

    var errorDescription: String? {
        switch self {
        case let .manualConnectionRequired(ssid):
            "Connect this Mac to \(ssid), then return to Pocket."
        }
    }
}
#endif
