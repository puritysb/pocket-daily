import Foundation

/// What a connected reader can do, independent of how its firmware says so.
/// Views ask for these instead of reading status fields, so another device
/// family plugs in with its own adapter (docs/READER_EXPANSION.md, 기기 중심 구조).
enum DeviceCapability: String, CaseIterable, Hashable {
    /// Home and Sleep screens the app designs and applies.
    case screens
    /// Browsing and removing the files stored on the reader (`readerFiles` ≥ 1).
    case files
    /// Copying a book from the reader into the Library (`readerFiles` ≥ 2,
    /// firmware docs/reader-files.md "Reader file download").
    case fileDownload
    /// Exchanging reading positions over the local connection.
    case readingPositions
    /// Receiving an official firmware update from the app.
    case firmwareUpdate
    /// A paired reader exchanges reading positions over Bluetooth when a book closes.
    case bluetoothSync
}

/// The reader as the whole app shows it: sidebar, Library header and the
/// Reader pages read the same snapshot. The app supports compatible readers
/// rather than one product, so a model name appears only once a reader has
/// reported it; otherwise it is simply "Reader".
struct DeviceSnapshot: Equatable {
    enum Family: String, Equatable {
        /// X3/X4 readers running Pocket Daily or compatible CrossPoint-based firmware.
        case crossPoint


    }

    enum Link: Equatable {
        case offline, connecting, sameWiFi, direct, demo
    }

    let family: Family
    /// The model the reader reported (for example "X4"); nil until one answers.
    let model: String?
    let link: Link
    let capabilities: Set<DeviceCapability>

    var isConnected: Bool { link == .sameWiFi || link == .direct }

    /// "Not connected", "X4 · Same Wi-Fi", "Demo".
    var statusText: String {
        switch link {
        case .offline: "Not connected"
        case .connecting: "Connecting…"
        case .sameWiFi: [model, "Same Wi-Fi"].compactMap { $0 }.joined(separator: " · ")
        case .direct: [model, "Direct"].compactMap { $0 }.joined(separator: " · ")
        case .demo: "Demo"
        }
    }

    /// The CrossPoint adapter: `/api/status` fields and the Bluetooth pairing
    /// become capabilities. A demo reader is shown, but offers nothing.
    static func crossPoint(status: CrossPointStatus?, isDemo: Bool,
                           isConnecting: Bool, isDirect: Bool, bluetoothPaired: Bool = false, bluetoothSupported: Bool = false) -> DeviceSnapshot {
        let link: Link
        if isDemo { link = .demo }
        else if status != nil { link = isDirect ? .direct : .sameWiFi }
        else if isConnecting { link = .connecting }
        else { link = .offline }

        var capabilities = Set<DeviceCapability>()
        if let status, !isDemo {
            let identified = status.deviceID?.isEmpty == false
            if status.pocketProfile == 1 && identified { capabilities.insert(.screens) }
            if (status.readerFiles ?? 0) >= 1 { capabilities.insert(.files) }
            if (status.readerFiles ?? 0) >= 2 { capabilities.insert(.fileDownload) }
            if status.readingProgress == 1 && identified { capabilities.insert(.readingPositions) }
            if status.supportsAtomicUpload { capabilities.insert(.firmwareUpdate) }
        }
        if !isDemo && bluetoothPaired && bluetoothSupported { capabilities.insert(.bluetoothSync) }

        let model = status.flatMap { PocketHardware(deviceName: $0.device)?.rawValue }
        return DeviceSnapshot(family: .crossPoint, model: model, link: link, capabilities: capabilities)
    }
}
