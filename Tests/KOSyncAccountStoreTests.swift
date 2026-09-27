import XCTest
@testable import Pocket

/// KOSync account persistence against in-memory settings and secret storage,
/// so the tests never touch the real Keychain or user defaults.
final class KOSyncAccountStoreTests: XCTestCase {
    private var settings: MemorySettings!
    private var secrets: MemorySecrets!
    private var generated: [String] = []

    override func setUp() {
        settings = MemorySettings()
        secrets = MemorySecrets()
        generated = []
    }

    private func makeStore(deviceName: String = "Pocket Daily iPhone") -> KOSyncAccountStore {
        KOSyncAccountStore(settings: settings, secrets: secrets, deviceName: deviceName) { [unowned self] in
            let id = String(format: "%032lx", self.generated.count + 1)
            self.generated.append(id)
            return id
        }
    }

    private func account(_ server: String = "https://sync.example.com") throws -> KOSyncAccount {
        KOSyncAccount(
            server: try KOSyncServer(validating: server),
            credentials: KOSyncCredentials(username: "reader", password: "password")
        )
    }

    func testFreshStoreHasNoAccountAndUsesPublicServer() throws {
        let store = makeStore()
        XCTAssertNil(try store.loadAccount())
        XCTAssertNil(store.username)
        XCTAssertEqual(store.server, .standard)
    }

    func testSaveKeepsKeyOnlyInSecretStorage() throws {
        let store = makeStore()
        try store.save(account())
        XCTAssertEqual(secrets.items[KOSyncAccountStore.keychainAccount], "5f4dcc3b5aa765d61d8327deb882cf99")
        XCTAssertEqual(settings.values[KOSyncAccountStore.Keys.username] as? String, "reader")
        XCTAssertEqual(settings.values[KOSyncAccountStore.Keys.serverURL] as? String, "https://sync.example.com")
        XCTAssertFalse(settings.values.values.contains { ($0 as? String) == "5f4dcc3b5aa765d61d8327deb882cf99" })
        XCTAssertEqual(try makeStore().loadAccount(), try account())
    }

    func testMissingKeyMeansNoAccount() throws {
        let store = makeStore()
        try store.save(account())
        secrets.items = [:]
        XCTAssertNil(try store.loadAccount())
        secrets.items[KOSyncAccountStore.keychainAccount] = "not-a-key"
        XCTAssertNil(try store.loadAccount())
    }

    func testSaveRejectsInvalidAccountWithoutWriting() throws {
        let store = makeStore()
        var invalidName = try account()
        invalidName.credentials.username = "a:b"
        XCTAssertThrowsError(try store.save(invalidName)) { XCTAssertEqual($0 as? KOSyncError, .invalidUsername) }
        var invalidKey = try account()
        invalidKey.credentials.key = "password"
        XCTAssertThrowsError(try store.save(invalidKey)) { XCTAssertEqual($0 as? KOSyncError, .unauthorized) }
        XCTAssertTrue(secrets.items.isEmpty)
        XCTAssertTrue(settings.values.isEmpty)
    }

    func testSecretFailureLeavesSettingsUntouched() throws {
        secrets.failure = KOSyncKeychainError.status(-25308)
        XCTAssertThrowsError(try makeStore().save(account()))
        XCTAssertNil(settings.values[KOSyncAccountStore.Keys.username])
    }

    func testSignOutRemovesCredentialsButKeepsServerAndDevice() throws {
        let store = makeStore()
        try store.save(account("https://example.com/kosync/"))
        let deviceID = store.deviceID
        try store.signOut()
        XCTAssertNil(try store.loadAccount())
        XCTAssertNil(store.username)
        XCTAssertTrue(secrets.items.isEmpty)
        XCTAssertEqual(store.server.baseURL.absoluteString, "https://example.com/kosync")
        XCTAssertEqual(store.deviceID, deviceID)
    }

    func testInvalidStoredServerFallsBackToPublicServer() {
        settings.values[KOSyncAccountStore.Keys.serverURL] = "http://insecure.example.com"
        XCTAssertEqual(makeStore().server, .standard)
    }

    func testDeviceIDIsCreatedOnceAndPersisted() {
        let store = makeStore()
        let first = store.deviceID
        XCTAssertEqual(first, "00000000000000000000000000000001")
        XCTAssertEqual(store.deviceID, first)
        XCTAssertEqual(makeStore().deviceID, first)
        XCTAssertEqual(generated.count, 1)
    }

    func testCorruptDeviceIDIsReplaced() {
        settings.values[KOSyncAccountStore.Keys.deviceID] = "short"
        XCTAssertEqual(makeStore().deviceID, "00000000000000000000000000000001")
    }

    func testRandomDeviceIDIsLowercaseHex() {
        let first = KOSyncAccountStore.randomDeviceID()
        let second = KOSyncAccountStore.randomDeviceID()
        XCTAssertTrue(KOReaderDocumentDigest.isDigest(first))
        XCTAssertEqual(first, first.lowercased())
        XCTAssertNotEqual(first, second)
    }

    func testProgressUsesDeviceIdentity() {
        let store = makeStore(deviceName: "Pocket Daily Mac")
        let progress = store.progress(
            document: "0123456789abcdef0123456789abcdef",
            position: "/body/DocFragment[2]/body/p[3]/text().4",
            percentage: 0.25
        )
        XCTAssertEqual(progress.device, "Pocket Daily Mac")
        XCTAssertEqual(progress.deviceID, store.deviceID)
        XCTAssertNil(progress.timestamp)
    }

    func testDeviceNames() {
        XCTAssertEqual(KOSyncDeviceName.name(for: .phone), "Pocket Daily iPhone")
        XCTAssertEqual(KOSyncDeviceName.name(for: .pad), "Pocket Daily iPad")
        XCTAssertEqual(KOSyncDeviceName.name(for: .mac), "Pocket Daily Mac")
    }

    @MainActor
    func testCurrentDeviceNameOnSimulator() {
        XCTAssertTrue(["Pocket Daily iPhone", "Pocket Daily iPad"].contains(KOSyncDeviceName.current))
    }
}

private final class MemorySettings: KOSyncSettingsStorage {
    var values: [String: Any] = [:]

    func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        values[defaultName] = nil
    }
}

private final class MemorySecrets: KOSyncSecretStorage {
    var items: [String: String] = [:]
    var failure: Error?

    func secret(forAccount account: String) throws -> String? {
        if let failure { throw failure }
        return items[account]
    }

    func setSecret(_ secret: String, forAccount account: String) throws {
        if let failure { throw failure }
        items[account] = secret
    }

    func removeSecret(forAccount account: String) throws {
        if let failure { throw failure }
        items[account] = nil
    }
}
