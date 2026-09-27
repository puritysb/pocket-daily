import Foundation
import Security
#if canImport(UIKit)
import UIKit
#endif

/// Plain settings storage; `UserDefaults` conforms.
protocol KOSyncSettingsStorage: AnyObject {
    func string(forKey defaultName: String) -> String?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: KOSyncSettingsStorage {}

/// Secret storage for the account key; the Keychain in the app.
protocol KOSyncSecretStorage {
    func secret(forAccount account: String) throws -> String?
    func setSecret(_ secret: String, forAccount account: String) throws
    func removeSecret(forAccount account: String) throws
}

enum KOSyncKeychainError: LocalizedError, Equatable {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .status(status):
            "Pocket Daily could not access the Keychain (error \(status)). Unlock the device and try again."
        }
    }
}

struct KeychainKOSyncSecretStorage: KOSyncSecretStorage {
    static let defaultService = "bound.serendipity.pocket.daily.kosync"

    var service = Self.defaultService

    func secret(forAccount account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = perform(query) { SecItemCopyMatching($0 as CFDictionary, &result) }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KOSyncKeychainError.status(status)
        }
    }

    func setSecret(_ secret: String, forAccount account: String) throws {
        try removeSecret(forAccount: account)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = Data(secret.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = perform(query) { SecItemAdd($0 as CFDictionary, nil) }
        guard status == errSecSuccess else {
            throw KOSyncKeychainError.status(status)
        }
    }

    func removeSecret(forAccount account: String) throws {
        let status = perform(baseQuery(account: account)) { SecItemDelete($0 as CFDictionary) }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KOSyncKeychainError.status(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// macOS uses the data-protection keychain, which needs a signed app
    /// identifier; unsigned local builds fall back to the file keychain.
    private func perform(_ query: [String: Any], _ operation: ([String: Any]) -> OSStatus) -> OSStatus {
        #if os(macOS)
        var modern = query
        modern[kSecUseDataProtectionKeychain as String] = true
        let status = operation(modern)
        guard status == errSecMissingEntitlement else { return status }
        return operation(query)
        #else
        return operation(query)
        #endif
    }
}

struct KOSyncAccount: Equatable, Sendable {
    var server: KOSyncServer
    var credentials: KOSyncCredentials
}

enum KOSyncDeviceName {
    enum Idiom {
        case phone, pad, mac
    }

    static func name(for idiom: Idiom) -> String {
        switch idiom {
        case .phone: "Pocket Daily iPhone"
        case .pad: "Pocket Daily iPad"
        case .mac: "Pocket Daily Mac"
        }
    }

    @MainActor
    static var current: String {
        #if os(macOS)
        name(for: .mac)
        #else
        name(for: UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone)
        #endif
    }
}

/// Persists the optional KOReader sync account: server and username in
/// settings, the key in the Keychain, plus this installation's device ID.
final class KOSyncAccountStore {
    enum Keys {
        static let serverURL = "kosync.serverURL"
        static let username = "kosync.username"
        static let deviceID = "kosync.deviceID"
    }

    static let keychainAccount = "account-key"

    let deviceName: String
    private let settings: any KOSyncSettingsStorage
    private let secrets: any KOSyncSecretStorage
    private let makeDeviceID: () -> String

    init(
        settings: any KOSyncSettingsStorage,
        secrets: any KOSyncSecretStorage,
        deviceName: String,
        makeDeviceID: @escaping () -> String = KOSyncAccountStore.randomDeviceID
    ) {
        self.settings = settings
        self.secrets = secrets
        self.deviceName = deviceName
        self.makeDeviceID = makeDeviceID
    }

    @MainActor
    convenience init() {
        self.init(
            settings: UserDefaults.standard,
            secrets: KeychainKOSyncSecretStorage(),
            deviceName: KOSyncDeviceName.current
        )
    }

    /// The saved server, or the public KOReader server when none is saved or
    /// the saved value no longer validates.
    var server: KOSyncServer {
        guard let stored = settings.string(forKey: Keys.serverURL),
              let server = try? KOSyncServer(validating: stored)
        else {
            return .standard
        }
        return server
    }

    var username: String? {
        guard let stored = settings.string(forKey: Keys.username), !stored.isEmpty else { return nil }
        return stored
    }

    /// The signed-in account, or nil when sync is not set up.
    func loadAccount() throws -> KOSyncAccount? {
        guard let username else { return nil }
        guard let key = try secrets.secret(forAccount: Self.keychainAccount),
              KOReaderDocumentDigest.isDigest(key)
        else {
            return nil
        }
        return KOSyncAccount(server: server, credentials: KOSyncCredentials(username: username, key: key))
    }

    /// Saves an account that the server has already accepted. The key is
    /// written first so settings never name an account without a key.
    func save(_ account: KOSyncAccount) throws {
        guard KOSyncCredentials.isValidUsername(account.credentials.username) else {
            throw KOSyncError.invalidUsername
        }
        guard KOReaderDocumentDigest.isDigest(account.credentials.key) else {
            throw KOSyncError.unauthorized
        }
        try secrets.setSecret(account.credentials.key.lowercased(), forAccount: Self.keychainAccount)
        settings.set(account.server.baseURL.absoluteString, forKey: Keys.serverURL)
        settings.set(account.credentials.username, forKey: Keys.username)
    }

    /// Removes the account and key; keeps the server address and device ID.
    func signOut() throws {
        settings.removeObject(forKey: Keys.username)
        try secrets.removeSecret(forAccount: Self.keychainAccount)
    }

    /// A stable per-installation identifier sent as KOSync `device_id`.
    var deviceID: String {
        if let stored = settings.string(forKey: Keys.deviceID), KOReaderDocumentDigest.isDigest(stored) {
            return stored
        }
        let created = makeDeviceID()
        settings.set(created, forKey: Keys.deviceID)
        return created
    }

    func progress(document: String, position: String, percentage: Double) -> KOSyncProgress {
        KOSyncProgress(
            document: document,
            progress: position,
            percentage: percentage,
            device: deviceName,
            deviceID: deviceID,
            timestamp: nil
        )
    }

    static func randomDeviceID() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0 ..< 16)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }
}
