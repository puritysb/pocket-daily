import SwiftUI
import UniformTypeIdentifiers

/// One studio on every platform: Home & Sleep first, then Cards; the reader
/// connection, files and settings sit in the inspector (a Reader tab on iPhone).
enum StudioSection: String, CaseIterable, Hashable {
    case layout = "Home & Sleep", cards = "Cards", reader = "Reader"

    var symbol: String {
        switch self {
        case .layout: "rectangle.3.group"
        case .cards: "rectangle.stack"
        case .reader: "dot.radiowaves.left.and.right"
        }
    }
}

struct ContentView: View {
    private enum FileImportAction {
        case wirelessUpload
        case sdSource
        case sdRoot
    }

    private struct PendingFirmwareTransfer: Identifiable {
        let id = UUID()
        let url: URL
        let action: FileImportAction
    }

    /// Wide layouts show the inspector beside the studio; below this the
    /// iPhone-style tabs take over.
    private static let wideWidth: CGFloat = 920
    private static let inspectorWidth: CGFloat = 320
    /// Main-area width below which the canvas and its controls stack.
    private static let sideBySideWidth: CGFloat = 720

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: PocketModel
    @StateObject private var nearby = NearbySyncController()
    @StateObject private var profileEditor = ProfileEditorState()
    @State private var section: StudioSection
    @State private var importing = false
    @State private var importAction: FileImportAction = .wirelessUpload
    @State private var sdSource: URL?
    @State private var pendingFirmwareTransfer: PendingFirmwareTransfer?
    @State private var showingProjectInfo = false

    /// `initialSection` lets the store screenshots open a given studio tab.
    init(initialSection: StudioSection = .layout) {
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= Self.wideWidth {
                desktopStudio(stacked: proxy.size.width - Self.inspectorWidth < Self.sideBySideWidth)
            } else {
                compactStudio
            }
        }
        .background(PocketPalette.workspace)
        .modifier(TransferFilePicker(
            isPresented: $importing,
            allowedContentTypes: importAction == .sdRoot ? [.folder] : [.epub, .data],
            completion: { result in
                let urls: [URL]
                switch result {
                case .success(let selected): urls = selected
                case .failure(let error):
                    model.post(error)
                    return
                }
                guard let url = urls.first else { return }
                switch importAction {
                case .wirelessUpload:
                    prepareTransfer(url, action: .wirelessUpload)
                case .sdSource:
                    prepareTransfer(url, action: .sdSource)
                case .sdRoot:
                    if let sdSource {
                        model.copyToSD(sdSource, root: url)
                        self.sdSource = nil
                    }
                }
            }
        ))
        .onChange(of: nearby.hotspotLease) { _, lease in
            if let lease, model.directConnectionRequested { model.useNearbyLease(lease) }
        }
        .onChange(of: nearby.state) { _, state in
            if let message = state.failureMessage {
                model.directDiscoveryFailed(message)
            }
            if case let .connected(status) = state {
                model.selectHardware(named: status.model)
                if model.directConnectionRequested {
                    model.expectDirectReader(status.deviceID)
                    do { try nearby.requestHotspot() }
                    catch { model.directDiscoveryFailed(error.localizedDescription) }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
#if os(iOS)
            if phase == .background {
                nearby.disconnect()
                model.pauseForBackground()
            } else if phase == .active {
                model.resumeForForeground()
            }
#endif
        }
        .sheet(item: $pendingFirmwareTransfer) { transfer in
            FirmwareTransferSheet(
                filename: transfer.url.lastPathComponent,
                cancel: { pendingFirmwareTransfer = nil },
                continueTransfer: {
                    pendingFirmwareTransfer = nil
                    performTransfer(transfer.url, action: transfer.action)
                }
            )
        }
        .sheet(isPresented: $showingProjectInfo) {
            ProjectInformationSheet()
        }
    }

    // MARK: Layouts

    private func desktopStudio(stacked: Bool) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                studioTopBar
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                Divider()
                ScrollView {
                    studio(section == .reader ? .layout : section, stacked: stacked)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                        .frame(maxWidth: 900, alignment: .leading)
                        .frame(maxWidth: .infinity)
                }
            }
            .background(PocketPalette.stage)
            Divider()
            ScrollView { inspector.padding(16) }
                .accessibilityIdentifier("inspector")
                .frame(width: Self.inspectorWidth)
                .background(PocketPalette.panel)
        }
    }

    private var compactStudio: some View {
        TabView(selection: $section) {
            ForEach(StudioSection.allCases, id: \.self) { tab in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if tab != .reader { firmwareAdvice }
                            studio(tab, stacked: true)
                        }
                        .padding()
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .background(PocketPalette.workspace)
                    .navigationTitle(tab.rawValue)
#if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
#endif
                    .toolbar {
                        if tab != .reader {
                            ToolbarItem(placement: .primaryAction) {
                                CompactReaderMenu(model: model) { section = .reader }
                            }
                        }
                    }
                }
                .tabItem { Label(tab.rawValue, systemImage: tab.symbol) }
                .tag(tab)
            }
        }
    }

    @ViewBuilder private func studio(_ section: StudioSection, stacked: Bool) -> some View {
        switch section {
        case .layout: ProfileStudioView(model: model, editor: profileEditor, stacked: stacked)
        case .cards: ContentStudioView(model: model, stacked: stacked)
        case .reader: inspector
        }
    }

    /// Wide header: the product, the two studio tabs and the reader in one line.
    private var studioTopBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                PocketMark()
                Text("Pocket Daily").font(.title3.weight(.semibold))
                Picker("Studio", selection: Binding(
                    get: { section == .reader ? .layout : section }, set: { section = $0 })) {
                    Text(StudioSection.layout.rawValue).tag(StudioSection.layout)
                    Text(StudioSection.cards.rawValue).tag(StudioSection.cards)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .padding(.leading, 12)
                .accessibilityIdentifier("studio-mode")
                Spacer(minLength: 12)
                ReaderChip(model: model)
            }
            firmwareAdvice
        }
    }

    @ViewBuilder private var firmwareAdvice: some View {
        if let status = model.readerStatus,
           case let .updateAvailable(current, minimum) = FirmwareGuidance.advise(readerVersion: status.version) {
            Label("Reader firmware \(current) is older than \(minimum). Update on the reader: Settings → System → Update.",
                  systemImage: "arrow.down.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: Inspector

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            ConnectionInspector(model: model, nearby: nearby, onConnect: connect)
            if showsStatus {
                StatusCallout(message: model.message, tone: model.messageTone)
            }
            if model.isTransferring {
                Button("Pause transfer") { model.pauseTransfer() }
            }
            if model.uploadProgress > 0 && model.uploadProgress < 1 { ProgressView(value: model.uploadProgress) }
            FilesInspector(model: model) { urls in
                if let first = urls.first { prepareTransfer(first, action: .wirelessUpload) }
            } choose: {
                importAction = .wirelessUpload
                importing = true
            } copyToSD: {
                importAction = .sdSource
                importing = true
            }
            DeviceSettingsInspector(model: model)
            AdvancedInspector(model: model, nearby: nearby)
            Button {
                showingProjectInfo = true
            } label: {
                Label("About & Privacy", systemImage: "info.circle")
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .accessibilityIdentifier("about-privacy")
        }
    }

    /// The reader card already says how to connect and that demo sends
    /// nothing; the callout carries only news beyond that.
    private var showsStatus: Bool {
        if model.messageTone != .neutral { return true }
        return !model.isDemoMode && model.message != PocketModel.initialMessage
    }

    private func connect() {
        model.exitDemoMode()
        model.startConnectionSearch()
        nearby.disconnect()
    }

    private func prepareTransfer(_ url: URL, action: FileImportAction) {
        guard !model.isDemoMode else {
            model.post("Exit demo and connect a reader before sending files.")
            return
        }
        if url.pathExtension.lowercased() == "bin" {
            pendingFirmwareTransfer = PendingFirmwareTransfer(url: url, action: action)
        } else {
            performTransfer(url, action: action)
        }
    }

    private func performTransfer(_ url: URL, action: FileImportAction) {
        switch action {
        case .wirelessUpload:
            model.upload(url)
        case .sdSource:
            sdSource = url
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                importAction = .sdRoot
                importing = true
            }
        case .sdRoot:
            break
        }
    }
}

/// Wide header reader state: the connected reader and how it is reached, or
/// the preview hardware choice when there is none.
private struct ReaderChip: View {
    @ObservedObject var model: PocketModel

    var body: some View {
        HStack(spacing: 8) {
            if let status = model.readerStatus, !model.isDemoMode {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text(status.device).font(.callout.weight(.semibold))
                Text(model.hasDirectSession ? "Direct" : "Same Wi-Fi")
                    .font(.caption).foregroundStyle(.secondary)
                SyncModeBadge(mode: model.syncMode)
            } else {
                Text(model.isDemoMode ? "Demo" : "No reader")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Preview device", selection: $model.preferredHardware) {
                    ForEach(PocketHardware.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 100)
                .help("Preview size when no reader is connected")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-chip")
    }
}

/// Compact toolbar reader state; opens the Reader tab, or picks the preview
/// hardware when no reader is connected.
private struct CompactReaderMenu: View {
    @ObservedObject var model: PocketModel
    let openReader: () -> Void

    var body: some View {
        if let status = model.readerStatus, !model.isDemoMode {
            Button(action: openReader) {
                Label(status.device, systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            }
            .accessibilityLabel("\(status.device) connected")
        } else {
            Menu {
                Picker("Preview device", selection: $model.preferredHardware) {
                    ForEach(PocketHardware.allCases) { Text($0.rawValue).tag($0) }
                }
                Button("Connect a reader", systemImage: "dot.radiowaves.left.and.right", action: openReader)
            } label: {
                Text("\(model.hardware.rawValue) · \(model.isDemoMode ? "Demo" : "No reader")")
                    .font(.callout)
            }
            .accessibilityIdentifier("reader-menu")
        }
    }
}

/// Live-studio sync mode, surfaced: push means real-time events and the
/// frame stream; poll means the reader's radio budget kept the listener
/// off and the app rides the heartbeat.
private struct SyncModeBadge: View {
    let mode: DeviceSyncMode

    var body: some View {
        let (text, color): (String, Color) = {
            switch mode {
            case .push: return ("LIVE", .green)
            case .poll: return ("POLL", .orange)
            case .offline: return ("OFFLINE", .gray)
            }
        }()
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
            .help("LIVE: real-time events over WebSocket. POLL: heartbeat polling (reader memory is tight).")
    }
}

private struct PocketMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(PocketPalette.ink)
                .frame(width: 32, height: 38)
            RoundedRectangle(cornerRadius: 3)
                .fill(PocketPalette.paper)
                .frame(width: 22, height: 27)
            Capsule()
                .fill(PocketPalette.accent)
                .frame(width: 10, height: 3)
                .offset(y: 11)
        }
        .accessibilityHidden(true)
    }
}

private struct FirmwareTransferSheet: View {
    let filename: String
    let cancel: () -> Void
    let continueTransfer: () -> Void

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(PocketPalette.accent)
                    .frame(width: 48, height: 48)
                    .background(PocketPalette.selection, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Stage custom firmware?").font(.title2.weight(.semibold))
                    Text(filename).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                SafetyLine(symbol: "checkmark.seal", text: "Pocket validates the ESP32-C3 image structure, checksum, SHA-256 digest, and Nearby Sync identity before staging.")
                SafetyLine(symbol: "checkmark.shield", text: "Use only Pocket Daily or compatible CrossPoint-based firmware for this reader profile.")
                SafetyLine(symbol: "building.2.crop.circle", text: "Factory firmware and manufacturer services are not supported by this app.")
                SafetyLine(symbol: "wrench.and.screwdriver", text: "Custom firmware can affect support or warranty if it causes device damage.")
                SafetyLine(symbol: "hand.tap", text: "Pocket Daily only stages the file. Installation still requires confirmation on the reader.")
            }
            .padding(16)
            .background(PocketPalette.stage, in: RoundedRectangle(cornerRadius: 14))

            Text("Keep a known recovery method available before installing. The selected file remains your responsibility.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("I understand · Continue", action: continueTransfer)
                    .buttonStyle(.borderedProminent)
                    .tint(PocketPalette.ink)
            }
        }
        .padding(24)
        .frame(maxWidth: 520)
        }
#if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 460)
#endif
        .presentationDetents([.medium, .large])
    }
}

private struct SafetyLine: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(PocketPalette.ink).frame(width: 20)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Not private: the macOS store-screenshot test renders this sheet offscreen, which
/// avoids depending on the Accessibility permission a UI-test runner would need.
struct ProjectInformationSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        PocketMark()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pocket Daily").font(.title2.weight(.semibold))
                            Text("Independent, local-first reader companion")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }

                    InfoSection(title: "Compatibility", symbol: "rectangle.connected.to.line.below") {
                        Text("Designed for X3/X4 hardware running Pocket Daily or compatible CrossPoint-based firmware. Factory firmware and manufacturer cloud services are not supported.")
                    }
                    InfoSection(title: "Independent project", symbol: "person.crop.circle.badge.checkmark") {
                        Text("Pocket Daily is not affiliated with, sponsored by, or endorsed by CrossPoint Reader, Xteink, or any device manufacturer.")
                    }
                    InfoSection(title: "Privacy", symbol: "lock.shield") {
                        Text("No account, analytics, advertising, or cloud relay. Device discovery and transfer stay on Bluetooth and the local network. Pocket Daily does not read your coordinates.")
                    }
                    InfoSection(title: "Firmware responsibility", symbol: "externaldrive.badge.exclamationmark") {
                        Text("Custom firmware can affect device support or warranty. Pocket Daily stages user-selected files but never installs firmware without confirmation on the reader.")
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 18) { projectLinks }
                        VStack(alignment: .leading, spacing: 10) { projectLinks }
                    }
                    .font(.callout.weight(.medium))
                }
                .padding(24)
            }
            .navigationTitle("About Pocket Daily")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
#if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
#endif
    }

    @ViewBuilder
    private var projectLinks: some View {
        Link("Privacy policy", destination: PocketLinks.privacy)
        Link("Open-source notices", destination: PocketLinks.notices)
        NavigationLink("Preview font notices") { PreviewFontNotices() }
        Link("Support", destination: PocketLinks.support)
    }
}

/// OFL notices for the bundled preview font, read from the app bundle.
private struct PreviewFontNotices: View {
    @State private var notices = "Loading font notices…"

    var body: some View {
        ScrollView {
            Text(notices).font(.caption).textSelection(.enabled).padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Preview font notices")
        .task {
            do { notices = try await PreviewFontStore.shared.notices() }
            catch { notices = "Font notices are unavailable: \(error.localizedDescription)" }
        }
    }
}

private struct InfoSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.headline)
            content.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PocketPalette.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(PocketPalette.line) }
    }
}

/// The single place the app reports what just happened. The tone travels
/// with the message from the model, so success, a staged-but-not-installed
/// firmware, and failures are visually distinct without guessing from wording.
private struct StatusCallout: View {
    let message: String
    let tone: StatusTone

    private var symbol: String {
        switch tone {
        case .success: "checkmark.circle.fill"
        case .pending: "arrow.down.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        case .neutral: "info.circle"
        }
    }

    private var color: Color {
        switch tone {
        case .success: .green
        case .pending: .orange
        case .failure: .red
        case .neutral: .secondary
        }
    }

    private var title: String? {
        switch tone {
        case .success: "Done"
        case .pending: "Staged — install on the reader"
        case .failure: "Attention"
        case .neutral: nil
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                if let title {
                    Text(title).font(.subheadline.weight(.semibold))
                }
                Text(message)
                    .font(tone == .neutral ? .caption : .callout)
                    .foregroundStyle(tone == .neutral ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(tone == .neutral ? 0 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(tone == .neutral ? Color.clear : color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(tone == .neutral ? Color.clear : color.opacity(0.45), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

enum PocketLinks {
    static let privacy = URL(string: "https://puritysb.github.io/pocket-daily/privacy/")!
    static let support = URL(string: "https://puritysb.github.io/pocket-daily/support/")!
    static let notices = URL(string: "https://github.com/puritysb/pocket-daily/blob/main/THIRD_PARTY_NOTICES.md")!
}

private struct ConnectionInspector: View {
    @ObservedObject var model: PocketModel
    @ObservedObject var nearby: NearbySyncController
    let onConnect: () -> Void
    @State private var confirmingDirectConnection = false
    @State private var showingHelp = false

    var body: some View {
        InspectorCard(title: "READER", symbol: "dot.radiowaves.left.and.right") {
            HStack {
                Circle().fill(model.readerStatus == nil ? Color.secondary : Color.green).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.readerStatus?.device ?? model.hardware.displayName).fontWeight(.semibold)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
            }
            Button(model.isDemoMode ? "Exit demo" : (model.readerStatus == nil ? "Find on same Wi-Fi" : "Reconnect")) {
                if model.isDemoMode { model.exitDemoMode() } else { onConnect() }
            }
                .buttonStyle(.borderedProminent).tint(PocketPalette.ink).frame(maxWidth: .infinity)
                .disabled(model.isWorking || model.hasDirectSession)
            if !model.isDemoMode {
                HStack {
                    Button(model.hasDirectSession ? "Reconnect directly" : "Connect directly") {
                        confirmingDirectConnection = true
                    }
                    .disabled(model.isWorking || model.readerStatus != nil)
                    Spacer()
                    if model.readerStatus != nil || model.hasDirectSession {
                        Button("End session") { nearby.disconnect(); model.endConnection() }
                            .disabled(model.isWorking)
                    } else {
                        Button("Try demo") { nearby.disconnect(); model.enterDemoMode() }
                            .accessibilityIdentifier("try-demo")
                    }
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .alert("Connect to the reader’s temporary Wi-Fi?", isPresented: $confirmingDirectConnection) {
                    Button("Cancel", role: .cancel) {}
                    Button("Connect directly") {
                        model.beginDirectConnection()
                        if !model.resumeDirectConnection() {
                            nearby.scan()
                            // Permission/radio failures may be synchronous and
                            // identical to the previous state (no onChange).
                            if let message = nearby.state.failureMessage {
                                model.directDiscoveryFailed(message)
                            }
                        }
                    }
                } message: {
                    Text("Your Wi-Fi will switch to the reader. Prepare cloud files first; internet may be unavailable. Keep Pocket Daily open during transfer.")
                }
                DisclosureGroup("How to connect", isExpanded: $showingHelp) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("**Same Wi-Fi** · On the reader: Pocket Daily → Sync → Same Wi-Fi. This device stays on its network.")
                        Text("**Direct** · On the reader choose Direct connection, then Connect directly here. Works without a router.")
                        Text("Keep Sync open on the reader while you send. Older firmware calls these Join a Network and Nearby Sync.")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                }
                .font(.caption)
                if model.readerStatus?.screenPreviewAvailable == true {
                    Button("Show reader screen") { model.loadReaderPreview() }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .disabled(model.isWorking)
                }
                if let frame = model.readerScreenImageData {
                    PocketDevicePreview(hardware: model.hardware, status: model.readerStatus, screenImageData: frame)
                        .frame(height: 260)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("reader-screen")
                }
            }
            if let lease = nearby.hotspotLease, model.manualHotspotFallback {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Manual Wi-Fi fallback").font(.caption.weight(.semibold))
                    if model.locationPermissionRequired {
                        Text("Location access lets Pocket join this temporary network automatically. Pocket never reads your coordinates.")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Location Settings") { model.openLocationSettings() }
                            .buttonStyle(.bordered)
                    }
                    Button("Retry automatic join") { model.useNearbyLease(lease) }
                        .buttonStyle(.borderedProminent)
                    Text(lease.ssid)
                    Text(lease.passphrase).textSelection(.enabled)
                    Button("Verify connection") {
                        Task { await model.verifyNearbyLease(lease) }
                    }
                }
                .font(.caption.monospaced())
                .padding(9)
                .background(PocketPalette.workspace, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var detail: String {
        if model.isDemoMode { return "Demo · nothing is sent" }
        if let status = model.readerStatus { return "\(status.version) · \(status.mode) · \(status.ip)" }
        if model.manualHotspotFallback { return "Private Wi-Fi needs a manual join" }
        switch nearby.state {
        case .idle: return "Not connected"
        case .bluetoothUnavailable: return "Bluetooth unavailable — use the same Wi-Fi"
        case .scanning: return "Finding a reader for direct connection…"
        case let .connecting(name): return "Pairing securely with \(name)…"
        case let .connected(status): return "Bluetooth paired · \(status.deviceID)"
        case .switchingToHotspot: return "Starting private Wi-Fi…"
        case let .failed(message): return message
        }
    }
}

/// Books, study packs and firmware for the reader; prepared files wait here
/// until a reader is connected.
private struct FilesInspector: View {
    @ObservedObject var model: PocketModel
    let receive: ([URL]) -> Void
    let choose: () -> Void
    let copyToSD: () -> Void
    @State private var targeted = false

    private var isEnabled: Bool { model.canPrepareFiles }

    private var dropLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: targeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(targeted ? "Drop to prepare" : "Book, study pack or firmware")
                    .font(.callout.weight(.medium))
                Text("EPUB · PDL · BIN").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private var chooseButton: some View {
        Button("Choose…", action: choose)
            .buttonStyle(.bordered)
            .disabled(!isEnabled)
            .accessibilityIdentifier("choose-file")
    }

    var body: some View {
        InspectorCard(title: "FILES", symbol: "arrow.up.doc") {
            // The button moves under the label when the inspector is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    dropLabel.fixedSize()
                    Spacer(minLength: 0)
                    chooseButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    dropLabel
                    chooseButton
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(targeted ? PocketPalette.selection : .clear)
                    .overlay { RoundedRectangle(cornerRadius: 10).stroke(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(.secondary.opacity(0.55)) }
            )
            .dropDestination(for: URL.self) { urls, _ in
                guard isEnabled else { return false }
                receive(urls)
                return true
            } isTargeted: { targeted = $0 }
            .opacity(isEnabled ? 1 : 0.55)
            if model.hasDirectSession {
                Text("Only files already on this device can be prepared while connected directly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.preparedTransfers.isEmpty, !model.isDemoMode {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ready to send · \(model.preparedTransfers.count)").font(.subheadline.weight(.semibold))
                    ForEach(model.preparedTransfers) { item in
                        Text(item.filename).font(.caption).lineLimit(1)
                    }
                    HStack {
                        Button("Send") { model.sendPreparedFiles() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.readerStatus == nil || model.isWorking)
                        Button("Remove") { model.removePreparedFiles() }
                            .disabled(model.isWorking)
                    }
                }
            }
#if os(macOS)
            Button("Copy to an SD card…", action: copyToSD)
                .buttonStyle(.borderless)
                .font(.callout)
                .disabled(model.isWorking || model.isDemoMode)
#endif
        }
    }
}

private struct DeviceSettingsInspector: View {
    @ObservedObject var model: PocketModel

    var body: some View {
        InspectorCard(title: "READER SETTINGS", symbol: "slider.horizontal.3") {
            if let preferences = model.preferences {
                Toggle("Start on Pocket Daily", isOn: Binding(
                    get: { preferences.startupApp == 1 }, set: { model.setStartupPocketDaily($0) }
                ))
                Toggle("Keep Daily card while asleep", isOn: Binding(
                    get: { preferences.pocketDailySleepCover }, set: { model.setPocketDailySleepCover($0) }
                ))
                Stepper("Sleep after \(preferences.sleepTimeoutMinutes) min", value: Binding(
                    get: { preferences.sleepTimeoutMinutes }, set: { model.setSleepTimeout($0) }
                ), in: 1 ... 120)
                LabeledContent("Reading size") {
                    Picker("Reading size", selection: Binding(
                        get: { preferences.fontSize }, set: { model.setFontSize($0) }
                    )) {
                        Text("S").tag(0); Text("M").tag(1); Text("L").tag(2); Text("XL").tag(3)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
                Button(model.isDemoMode ? "Demo · not saved" : "Save settings") { model.savePreferences() }
                    .buttonStyle(.bordered).disabled(model.isDemoMode || !model.preferencesDirty || model.isWorking)
            } else {
                Text("Connect a reader to change its settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Rarely needed tools, folded away: theme metrics and connection diagnostics.
private struct AdvancedInspector: View {
    @ObservedObject var model: PocketModel
    @ObservedObject var nearby: NearbySyncController
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 14) {
                ThemePackInspector(model: model)
                if !model.isDemoMode {
                    TroubleshootingInspector(model: model, nearby: nearby)
                }
            }
            .padding(.top, 8)
        } label: {
            Label(model.crashDiagnostic == nil ? "Advanced" : "Advanced · crash report saved",
                  systemImage: "gearshape.2")
                .font(.callout.weight(.medium))
        }
    }
}

private struct TroubleshootingInspector: View {
    @ObservedObject var model: PocketModel
    @ObservedObject var nearby: NearbySyncController

    var body: some View {
        InspectorCard(title: "TROUBLESHOOTING", symbol: "wrench.and.screwdriver") {
            if let diagnostic = model.crashDiagnostic {
                DiagnosticsInspector(diagnostic: diagnostic)
            }
            ConnectionTraceInspector(nearby: nearby)
        }
    }
}

private struct DiagnosticsInspector: View {
    let diagnostic: CrashDiagnostic
    @State private var expanded = false

    var body: some View {
        InspectorCard(title: "DIAGNOSTICS", symbol: "waveform.path.ecg") {
            Text("Recorded device crash").font(.callout.weight(.semibold))
            Text(diagnostic.version).font(.caption.monospaced()).textSelection(.enabled)
            Text("Reset: \(diagnostic.resetReason)").font(.caption).textSelection(.enabled)
            Text(diagnostic.reason).font(.caption).textSelection(.enabled)
            if let breadcrumb = diagnostic.breadcrumb {
                Text("Checkpoint: \(breadcrumb)").font(.caption.monospaced()).textSelection(.enabled)
            }
            Text(diagnostic.analysis).font(.caption).foregroundStyle(.secondary)
            Text("Last event: \(diagnostic.lastEvent)")
                .font(.caption2.monospaced()).textSelection(.enabled)
            HStack {
                Button(expanded ? "Hide raw report" : "Show raw report") { expanded.toggle() }
                    .buttonStyle(.bordered)
                ShareLink("Export report", item: diagnostic.report)
            }
            if expanded {
                ScrollView([.horizontal, .vertical]) {
                    Text(diagnostic.report)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                .padding(8)
                .background(PocketPalette.workspace, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct ConnectionTraceInspector: View {
    @ObservedObject var nearby: NearbySyncController
    @State private var expanded = false

    var body: some View {
        InspectorCard(title: "CONNECTION LOG", symbol: "point.3.connected.trianglepath.dotted") {
            Text(nearby.traceAnalysis).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(expanded ? "Hide log" : "Show log") { expanded.toggle() }.buttonStyle(.bordered)
                ShareLink("Export log", item: nearby.traceReport)
            }
            if expanded {
                ScrollView([.horizontal, .vertical]) {
                    Text(nearby.traceReport)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
                .padding(8)
                .background(PocketPalette.workspace, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

struct InspectorCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .background(PocketPalette.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).stroke(PocketPalette.line, lineWidth: 1) }
    }
}

enum PocketPalette {
    static let workspace = Color(red: 0.952, green: 0.946, blue: 0.925)
    static let stage = Color(red: 0.925, green: 0.918, blue: 0.888)
    static let panel = Color(red: 0.977, green: 0.973, blue: 0.956)
    static let card = Color.white.opacity(0.72)
    static let paper = Color(red: 0.94, green: 0.93, blue: 0.86)
    static let ink = Color(red: 0.105, green: 0.12, blue: 0.115)
    static let deviceTop = Color(red: 0.105, green: 0.125, blue: 0.12)
    static let deviceBottom = Color(red: 0.055, green: 0.065, blue: 0.062)
    static let accent = Color(red: 0.78, green: 0.46, blue: 0.12)
    static let signal = Color(red: 0.22, green: 0.58, blue: 0.38)
    static let line = Color.black.opacity(0.11)
    static let selection = accent.opacity(0.15)
}

/// Owns a single picker presentation independently of connection/preview updates.
struct TransferFilePicker: ViewModifier {
    @Binding var isPresented: Bool
    let allowedContentTypes: [UTType]
    let completion: (Result<[URL], Error>) -> Void
#if os(iOS)
    @State private var selectedURLs: [URL]?

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $isPresented, onDismiss: {
            // Firmware confirmation must wait until the picker has finished dismissing.
            if let urls = selectedURLs {
                selectedURLs = nil
                completion(.success(urls))
            }
        }) {
            TransferDocumentPicker(contentTypes: allowedContentTypes) { urls in
                selectedURLs = urls
                isPresented = false
            }
            .ignoresSafeArea()
        }
    }
#else
    func body(content: Content) -> some View {
        content.fileImporter(
            isPresented: $isPresented,
            allowedContentTypes: allowedContentTypes,
            allowsMultipleSelection: false,
            onCompletion: completion
        )
    }
#endif
}

#if os(iOS)
private struct TransferDocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let finish: ([URL]?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        // Keep the existing controller and its search state for the entire presentation.
        context.coordinator.finish = finish
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var finish: ([URL]?) -> Void
        private var completed = false

        init(finish: @escaping ([URL]?) -> Void) { self.finish = finish }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            complete(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            complete(nil)
        }

        private func complete(_ urls: [URL]?) {
            guard !completed else { return }
            completed = true
            finish(urls)
        }
    }
}
#endif
