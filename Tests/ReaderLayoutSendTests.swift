import XCTest
@testable import Pocket

/// Home & Sleep's single Send: the profile and reader settings go in one reader
/// work item, only the parts that changed, and Revert restores the settings.
@MainActor
final class ReaderLayoutSendTests: XCTestCase {
    private func connectedModel(session: URLSession) throws -> PocketModel {
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), client: CrossPointClient(session: session))
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"t","device":"X3","deviceID":"5B09AF70","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1,"pocketProfile":1}"#.utf8))
        model.preferences = ReaderPreferences()
        return model
    }

    private func waitIdle(_ model: PocketModel) async throws {
        for _ in 0..<300 where model.isWorking { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isWorking)
    }

    func testExplicitReadingSaveNeverSendsPendingLayoutOrOtherPreferences() async throws {
        LayoutSendURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LayoutSendURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let model = try connectedModel(session: session)
        defer { model.pauseForBackground() }
        // Establish the authoritative baseline, then leave an unrelated setting staged.
        model.setFontSize(1)
        model.sendReaderLayout(profile: nil, cards: nil)
        try await waitIdle(model)
        model.setSleepTimeout(20)
        LayoutSendURLProtocol.reset()
        var reading = ReaderPreferences()
        reading.fontSize = 3
        model.sendReaderLayout(profile: nil, cards: nil, settingsOverride: reading,
                               includePendingPreferences: false)
        try await waitIdle(model)
        XCTAssertEqual(LayoutSendURLProtocol.requests.map(\.path), ["/api/status", "/api/pocket/v1/preferences"])
        XCTAssertEqual(model.preferencesBaseline?.fontSize, 3)
        XCTAssertEqual(model.preferencesBaseline?.sleepTimeoutMinutes, 10)
        XCTAssertEqual(model.preferences?.sleepTimeoutMinutes, 20)
        XCTAssertTrue(model.preferencesDirty)
        LayoutSendURLProtocol.reset()
        model.sendReaderLayout(profile: nil, cards: nil, includePendingPreferences: false)
        XCTAssertTrue(LayoutSendURLProtocol.requests.isEmpty)
    }

    func testSendSavesTheProfileThenTheSettingsAndOnlyWhatChanged() async throws {
        LayoutSendURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LayoutSendURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let model = try connectedModel(session: session)
        defer { model.pauseForBackground() }

        var profile = PocketProfile.defaults
        profile.home.items = [.word, .study]
        model.setSleepTimeout(20)
        XCTAssertTrue(model.preferencesDirty)
        model.sendReaderLayout(profile: profile, cards: nil)
        try await waitIdle(model)
        XCTAssertEqual(LayoutSendURLProtocol.requests.map(\.path),
                       ["/api/pocket/v1/profile", "/api/status", "/api/pocket/v1/preferences"])
        XCTAssertEqual(LayoutSendURLProtocol.requests.map(\.method), ["POST", "GET", "POST"])
        XCTAssertEqual(model.readerProfile?.profile.home.items, [.word, .study])
        XCTAssertFalse(model.preferencesDirty)
        XCTAssertEqual(model.messageTone, .success)

        // Settings only: the profile is not re-sent.
        LayoutSendURLProtocol.reset()
        model.setFontSize(3)
        model.sendReaderLayout(profile: nil, cards: nil)
        try await waitIdle(model)
        XCTAssertEqual(LayoutSendURLProtocol.requests.map(\.path), ["/api/status", "/api/pocket/v1/preferences"])

        XCTAssertEqual(model.profileSend, .saved(model.readerProfile?.generation ?? 0))

        // Nothing changed: nothing is sent.
        LayoutSendURLProtocol.reset()
        model.sendReaderLayout(profile: nil, cards: nil)
        XCTAssertFalse(model.isWorking)
        XCTAssertTrue(LayoutSendURLProtocol.requests.isEmpty)

        // Revert returns to what the reader has.
        model.setSleepTimeout(90)
        XCTAssertEqual(model.preferences?.sleepTimeoutMinutes, ReaderPreferences.neverSleepMinutes,
                       "The reader accepts 1-30 minutes or 31 (never)")
        model.revertPreferences()
        XCTAssertEqual(model.preferences?.sleepTimeoutMinutes, 20)
        XCTAssertEqual(model.preferences?.fontSize, 3)
        XCTAssertFalse(model.preferencesDirty)
    }

    /// Weather and events go to a reader that stores them, from the cache,
    /// and with Send; nothing is sent when no city or calendar is chosen.
    func testGlanceIsSentToAReaderThatStoresIt() async throws {
        LayoutSendURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LayoutSendURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let suite = "layout-glance-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = WeatherSnapshot(fetched: Date(), place: "Seoul", currentCode: 0, currentTempC: 20,
                                       currentSummary: "Clear", hours: [],
                                       days: [.init(date: Calendar.current.startOfDay(for: Date()), code: 0,
                                                    summary: "Clear", minC: 12, maxC: 22, precipitationChance: 0)])
        let settings = GlanceSettings(defaults: defaults, fetch: { _ in snapshot })
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), client: CrossPointClient(session: session),
                                glanceSettings: settings)
        defer { model.pauseForBackground() }
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"t","device":"X3","deviceID":"5B09AF70","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1,"pocketProfile":1,"pocketGlance":1}"#.utf8))
        model.preferences = ReaderPreferences()

        model.pushGlance()
        XCTAssertFalse(model.isWorking, "Nothing configured, nothing sent")
        settings.setPlace(.init(name: "Seoul", latitude: 37.57, longitude: 126.98))
        await settings.refreshWeatherIfNeeded()
        model.pushGlance(applyDraft: true)
        try await waitIdle(model)
        XCTAssertEqual(LayoutSendURLProtocol.requests.map(\.path), ["/api/pocket/v1/glance"])
        XCTAssertNotNil(model.glanceSentAt)
        let body = try XCTUnwrap(LayoutSendURLProtocol.lastBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual((json["weather"] as? [String: Any])?["place"] as? String, "Seoul")

        // Send carries the glance with the settings it saves.
        LayoutSendURLProtocol.reset()
        model.setFontSize(2)
        model.sendReaderLayout(profile: nil, cards: nil)
        try await waitIdle(model)
        XCTAssertEqual(LayoutSendURLProtocol.requests.map(\.path), ["/api/status", "/api/pocket/v1/preferences", "/api/pocket/v1/glance"])
    }


    func testSourceDraftStaysLocalUntilExplicitEmptyApplyAndLaterEditsStayPending() async throws {
        LayoutSendURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LayoutSendURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); LayoutSendURLProtocol.releaseGlance() }
        let suite = "layout-glance-apply-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = GlanceSettings(defaults: defaults)
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), client: CrossPointClient(session: session), glanceSettings: settings)
        defer { model.pauseForBackground() }
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"t","device":"X3","deviceID":"5B09AF70","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1,"pocketGlance":1}"#.utf8))
        settings.setPlace(.init(name: "Draft city", latitude: 1, longitude: 1))
        XCTAssertTrue(settings.isConfigured)
        model.pushGlance()
        try await waitIdle(model)
        XCTAssertTrue(LayoutSendURLProtocol.requests.isEmpty, "Configured source edits must not auto-send")
        settings.setPlace(nil)
        settings.setSelectedCalendarIDs([])
        XCTAssertFalse(settings.isConfigured)
        XCTAssertTrue(settings.hasUnappliedSourceChanges)
        model.pushGlance()
        try await waitIdle(model)
        XCTAssertTrue(LayoutSendURLProtocol.requests.isEmpty, "Automatic sends cannot apply source drafts")
        LayoutSendURLProtocol.holdNextGlance()
        model.pushGlance(applyDraft: true)
        for _ in 0..<300 where !LayoutSendURLProtocol.hasPendingGlance { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(LayoutSendURLProtocol.hasPendingGlance)
        XCTAssertEqual(LayoutSendURLProtocol.requests.map(\.path), ["/api/pocket/v1/glance"])
        let sent = try XCTUnwrap(LayoutSendURLProtocol.lastBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        XCTAssertTrue(json["weather"] is NSNull)
        XCTAssertEqual((json["events"] as? [[String: Any]])?.count, 0, "Explicit Apply sends an empty document to clear prior reader content")
        settings.setSelectedCalendarIDs(["unavailable-calendar"])
        LayoutSendURLProtocol.releaseGlance()
        try await waitIdle(model)
        XCTAssertTrue(settings.hasUnappliedSourceChanges, "Completion must not clear source edits made during the request")
        model.pushGlance(applyDraft: true)
        try await waitIdle(model)
        XCTAssertFalse(settings.hasUnappliedSourceChanges)
    }

    /// A reader that draws screens inside Sync shows the edited Home after the
    /// profile is saved; only a layout change asks for it.
    func testApplyShowsTheEditedScreenOnAReaderThatDrawsIt() async throws {
        LayoutSendURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LayoutSendURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), client: CrossPointClient(session: session))
        defer { model.pauseForBackground() }
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"t","device":"X3","deviceID":"5B09AF70","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1,"pocketProfile":1,"screenPresentation":1}"#.utf8))
        model.preferences = ReaderPreferences()
        XCTAssertTrue(model.canShowScreens)

        var profile = PocketProfile.defaults
        profile.home.weather = .top
        model.sendReaderLayout(profile: profile, cards: nil, show: .home)
        try await waitIdle(model)
        XCTAssertEqual(LayoutSendURLProtocol.requests.map(\.path),
                       ["/api/pocket/v1/profile", "/api/pocket/v1/screen/present"])
        XCTAssertEqual(model.screenShow, .shown(.home, generation: 1))
        XCTAssertEqual(model.messageTone, .success)

        // A screen-specific setting save also redraws the explicitly requested screen.
        LayoutSendURLProtocol.reset()
        model.setFontSize(2)
        model.sendReaderLayout(profile: nil, cards: nil, show: .home)
        try await waitIdle(model)
        XCTAssertEqual(LayoutSendURLProtocol.requests.map(\.path),
                       ["/api/status", "/api/pocket/v1/preferences", "/api/pocket/v1/screen/present"])
    }

    /// Readers without the capability are never asked to draw a screen.
    func testOlderReaderIsNotAskedToDrawAScreen() async throws {
        LayoutSendURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LayoutSendURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let model = try connectedModel(session: session)
        defer { model.pauseForBackground() }
        XCTAssertFalse(model.canShowScreens)
        model.sendReaderLayout(profile: .defaults, cards: nil, show: .home)
        try await waitIdle(model)
        XCTAssertEqual(LayoutSendURLProtocol.requests.map(\.path), ["/api/pocket/v1/profile"])
        XCTAssertEqual(model.screenShow, .idle)
    }

    func testDemoSendsNothing() throws {
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO())
        model.enterDemoMode()
        model.setSleepTimeout(30)
        model.sendReaderLayout(profile: .defaults, cards: nil)
        XCTAssertFalse(model.isWorking)
    }
}

private final class LayoutSendURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [(method: String, path: String)] = []
    nonisolated(unsafe) private static var body: Data?
    static var requests: [(method: String, path: String)] { lock.withLock { recorded } }
    static var lastBody: Data? { lock.withLock { body } }
    nonisolated(unsafe) private static var holdGlance = false
    nonisolated(unsafe) private static var pendingGlance: (@Sendable () -> Void)?
    static func reset() { lock.withLock { recorded = []; body = nil; holdGlance = false; pendingGlance = nil } }
    static var hasPendingGlance: Bool { lock.withLock { pendingGlance != nil } }
    static func holdNextGlance() { lock.withLock { holdGlance = true } }
    static func releaseGlance() {
        let complete = lock.withLock { () -> (@Sendable () -> Void)? in
            holdGlance = false
            defer { pendingGlance = nil }
            return pendingGlance
        }
        complete?()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.recorded.append((request.httpMethod ?? "GET", url.path)) }
        var body = Data("{}".utf8)
        let sent = request.httpBodyStream.map { stream -> Data in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        } ?? request.httpBody ?? Data()
        Self.lock.withLock { Self.body = sent }
        if url.path == "/api/status" {
            body = Data(#"{"version":"t","device":"X3","deviceID":"5B09AF70","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1}"#.utf8)
        }
        if url.path.hasPrefix("/api/pocket/v1/screen/") {
            // The reader drew the requested screen for the requested generation.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let value = { (name: String) in items.first { $0.name == name }?.value ?? "" }
            body = Data(#"{"schema":1,"deviceID":"\#(value("deviceID"))","surface":"\#(value("surface"))","generation":\#(value("generation")),"phase":"rendered","failure":"none","heap":20000,"block":8000}"#.utf8)
        }
        if url.path == "/api/pocket/v1/profile" {
            // Echo the sent document as the reader's stored profile.
            if var object = try? JSONSerialization.jsonObject(with: sent) as? [String: Any] {
                object["deviceID"] = "5B09AF70"
                object["generation"] = 1
                body = (try? JSONSerialization.data(withJSONObject: object)) ?? body
            }
        }
        guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        let replyData = body
        let complete: @Sendable () -> Void = { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: replyData)
            client?.urlProtocolDidFinishLoading(self)
        }
        let held = Self.lock.withLock {
            guard url.path == "/api/pocket/v1/glance", Self.holdGlance else { return false }
            Self.pendingGlance = complete
            return true
        }
        if !held { complete() }
    }
    override func stopLoading() {}
}
