import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The Library (reading on this device) comes first; the reader follows with
/// its own pages: Connection (connect, firmware, Bluetooth), Screens (Home &
/// Sleep) and Files (docs/READER_EXPANSION.md, 기기 중심 구조). It is "Reader",
/// not a product name: the app works with compatible readers.
enum StudioSection: String, CaseIterable, Hashable {
    case library = "Library", reader = "Reader", layout = "Screens", files = "Files"

    init(_ page: DeviceSection) {
        switch page {
        case .connection: self = .reader
        case .screens: self = .layout
        case .files: self = .files
        }
    }

    /// The device page this section shows; nil for the Library.
    var devicePage: DeviceSection? {
        switch self {
        case .library: nil
        case .reader: .connection
        case .layout: .screens
        case .files: .files
        }
    }

    /// Tab icons; the sidebar rows use each page's own symbol.
    var symbol: String {
        self == .library ? "books.vertical" : "rectangle.portrait.inset.filled"
    }
}

/// A library book opened for reading.
struct ReadingTarget: Identifiable, Hashable {
    let id: UUID
}

struct ContentView: View {
    private enum FileImportAction {
        case wirelessUpload
        case sdSource
        case sdRoot
#if DEBUG
        case localFirmware
#endif
    }

    /// Wide layouts use a sidebar; compact layouts use tabs.
    private static let wideWidth: CGFloat = 920

    @AppStorage("appAppearance") private var appearance = AppAppearance.system
    @ObservedObject private var readerAppearance = ReaderAppearanceStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var model: PocketModel
    @StateObject private var nearby = NearbySyncController(ownershipChanged: {
        ReaderBluetoothLink.shared.nearbySessionActive = $0
    })
    @StateObject private var profileEditor = ProfileEditorState()
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var sync = ReadingSync.shared
    private let readerLink = ReaderBluetoothLink.shared
    @ObservedObject private var inbox: ArticleInboxModel
    @State private var section: StudioSection
    @State private var reading: ReadingTarget?
    @State private var shelf: LibraryView.Shelf = .books
    @State private var importing = false
    @State private var importAction: FileImportAction = .wirelessUpload
    @State private var sdSource: URL?
    @State private var confirmingFirmwareUpdate = false
#if DEBUG
    /// A checked local image waiting for its acknowledgement.
    @State private var localFirmware: PocketModel.LocalFirmwareImage?
#endif
    @State private var showingProjectInfo = false
    @State private var showingSettings = false
    /// The page the compact Reader tab returns to.
    @State private var lastDevicePage: DeviceSection = .connection
#if os(macOS)
    @Environment(\.openSettings) private var openSettingsWindow
#endif
    @State private var firmwareDownloadTask: Task<Void, Never>?

    private let initialPreview: ProfileStudioView.PreviewSurface

    /// The store screenshots open a given tab and preview surface.
    @MainActor
    init(initialSection: StudioSection = .library, initialPreview: ProfileStudioView.PreviewSurface = .home,
         initialBookID: UUID? = nil, initialShelf: LibraryView.Shelf = .books, inbox: ArticleInboxModel? = nil) {
        _inbox = ObservedObject(wrappedValue: inbox ?? .shared)
        _shelf = State(initialValue: initialShelf)
        _section = State(initialValue: initialSection)
        _reading = State(initialValue: initialBookID.map { ReadingTarget(id: $0) })
        self.initialPreview = initialPreview
    }

    var body: some View {
        ZStack {
            GeometryReader { proxy in
                if proxy.size.width >= Self.wideWidth {
                    wideLayout
                } else {
                    compactStudio
                }
            }
            // Keep the shelf and its scroll position while reading in this window.
            .opacity(reading == nil ? 1 : 0)
            .allowsHitTesting(reading == nil)
            .accessibilityElement(children: .contain)
            .accessibilityHidden(reading != nil)
            if let reading {
                ReaderContainer(bookID: reading.id, library: library, sync: sync) { self.reading = nil }
                    .id(reading.id)
            }
        }
        .preferredColorScheme(reading == nil ? appearance.colorScheme : readerAppearance.appearance.theme.colorScheme)
        .background(PocketPalette.workspace)
        .onOpenURL { url in
            Task {
                let book = await library.importFiles([url])
                // iOS copies documents opened from other apps into this app's
                // Documents/Inbox. Remove only that temporary copy, and only once the
                // library holds its own; a failed import keeps it for another try.
                if book != nil, Self.isOwnInboxCopy(url) {
                    try? FileManager.default.removeItem(at: url)
                }
                if let book { open(book) }
            }
        }
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
                    prepareTransfer(url, action: importAction)
                case .sdSource:
                    prepareTransfer(url, action: .sdSource)
                case .sdRoot:
                    if let sdSource {
                        model.copyToSD(sdSource, root: url)
                        self.sdSource = nil
                    }
#if DEBUG
                case .localFirmware:
                    inspectLocalFirmware(url)
#endif
                }
            }
        ))
        .onChange(of: nearby.hotspotLease) { _, lease in
            if let lease, model.directConnectionRequested { model.useNearbyLease(lease) }
        }
        .onChange(of: nearby.state) { _, state in
            if let message = state.failureMessage {
                if readerLink.setup == .searching { readerLink.setup = .failed(message) }
                else { model.directDiscoveryFailed(message) }
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
            if phase == .active {
#if os(iOS)
                model.resumeForForeground()
#endif
                Task { await inbox.activate(allowNetwork: !model.isDemoMode) }
                sync.nudgeReader()
                readerLink.start()
            }
            else if phase == .background { inbox.suspend() }
#if os(iOS)
            if phase == .background {
                nearby.disconnect()
                model.pauseForBackground()
            }
#endif
        }
        .alert("Update reader firmware?", isPresented: $confirmingFirmwareUpdate) {
            Button("Update") { startFirmwareUpdate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sends the official Pocket Daily update for a compatible X3/X4 reader. Factory firmware is not supported. Keep a recovery method available; custom firmware may affect device support. Installation starts only after you confirm on the reader.")
        }
#if DEBUG
        .alert("Send this firmware build?", isPresented: Binding(get: { localFirmware != nil },
                                                                 set: { if !$0 { localFirmware = nil } }),
               presenting: localFirmware) { image in
            Button("Send") { startLocalFirmwareUpdate(image.file) }
            Button("Cancel", role: .cancel) {}
        } message: { image in
            Text(image.confirmation(readerVersion: model.readerStatus?.version))
        }
#endif
        .sheet(isPresented: $showingProjectInfo) {
            ProjectInformationSheet()
        }
        .sheet(isPresented: $showingSettings) {
            AppSettingsSheet(model: model)
        }
        .onChange(of: model.isWorking) { _, working in
            guard !working else { return }
            // Positions first; the reader's book list follows once the lane is free again.
            exchangeReadingPositions()
            model.refreshReaderInventoryIfWanted()
        }
        .onChange(of: model.readerStatus?.deviceID) { _, identity in
            exchangeReadingPositions()
            model.refreshReaderInventoryIfWanted()
            // The launch check may be stale by the time a reader connects.
            if identity != nil { Task { await model.refreshFirmwareReleaseForReader() } }
        }
        .task {
            model.refreshGlance()
            sync.attachReader(model: model, library: library)
            // Positions are matched against library books, so load them first.
            if library.books.isEmpty { await library.load() }
            sync.nudgeReader()
        }
        .task {
            // Same Wi-Fi reconnect asks one remembered address every few seconds.
            // Hosted tests (store renders) share the user's defaults; they must not reach a real reader.
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            while !Task.isCancelled {
                model.reconnectRememberedReader()
                try? await Task.sleep(for: .seconds(8))
            }
        }
        .task(id: model.isDemoMode) {
            // Unsent layout and reading edits come back from disk; demo starts
            // clean and its edits are never saved.
            profileEditor.reset()
            if !model.isDemoMode { profileEditor.restore(ProfileEditStore.live.load()) }
        }
        .onReceive(profileEditor.objectWillChange.debounce(for: .milliseconds(400), scheduler: RunLoop.main)) { _ in
            guard !model.isDemoMode else { return }
            do { try ProfileEditStore.live.save(profileEditor.snapshot) }
            catch { model.post("Your layout edits could not be saved on this device: \(error.localizedDescription)", tone: .failure) }
        }
        .task(id: model.isDemoMode) {
            // Authenticated pairing: remember this reader for reading sync over Bluetooth.
            nearby.onAuthenticated = { peripheral, status in
                guard !model.isDemoMode else { return }
                readerLink.remember(peripheral: peripheral, readerID: status.deviceID, model: status.model)
            }
            readerLink.requestSetupConnection = { nearby.scan() }
            readerLink.endSetupConnection = { nearby.disconnect() }
            if model.isDemoMode { inbox.cancelRefresh() }
            await inbox.activate(allowNetwork: !model.isDemoMode)
            if !model.isDemoMode { await model.checkFirmwareAtLaunch() }
        }
    }

    // MARK: Layouts

    static func isOwnInboxCopy(_ url: URL) -> Bool {
        guard url.isFileURL,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return false }
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(inbox) && !path.dropFirst(inbox.count).contains("/")
    }

    private func exchangeReadingPositions() {
        sync.exchangeWithReader(model: model, library: library)
    }

    private func open(_ book: LibraryBook) {
        section = .library
        reading = ReadingTarget(id: book.id)
    }

    private func libraryView(showsShelfMenu: Bool = true) -> some View {
        LibraryView(model: model, library: library, inbox: inbox, shelf: $shelf,
                    showsShelfMenu: showsShelfMenu, openSettings: showsShelfMenu ? showSettings : nil,
                    openDevice: showsShelfMenu ? { section = .reader } : nil, open: open)
    }

    /// One place for app-wide preferences: the Settings window on macOS, a sheet elsewhere.
    private func showSettings() {
#if os(macOS)
        openSettingsWindow()
#else
        showingSettings = true
#endif
    }

    /// One navigation rail replaces the two stacked section pickers.
    private var wideLayout: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            if section == .library {
                libraryView(showsShelfMenu: false)
            } else {
                desktopStudio
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                PocketMark()
                Text("Pocket Daily").font(.headline)
            }
            .padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 4) {
                Text("Library")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 4)
                ForEach(LibraryView.Shelf.allCases) { item in
                    sidebarRow(item.rawValue, symbol: item == .books ? "books.vertical" : "doc.text",
                               selected: section == .library && shelf == item) {
                        shelf = item
                        section = .library
                    }
                }
            }
            if section == .library && shelf == .articles && !inbox.feeds.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Following").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(inbox.feeds) { feed in
                                sidebarRow(feed.title, symbol: "dot.radiowaves.left.and.right", selected: inbox.filter == .feed(feed.id)) {
                                    inbox.filter = .feed(feed.id)
                                }
                            }
                        }
                    }.frame(height: min(CGFloat(inbox.feeds.count) * 64, 240))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Reader")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 4)
                ForEach(model.device.family.sections) { page in
                    // Connection carries the reader's state wherever the sidebar is shown.
                    sidebarRow(page.rawValue, symbol: page.symbol, selected: section == StudioSection(page),
                               detail: page == .connection ? model.device : nil) {
                        section = StudioSection(page)
                    }
                }
            }
            Spacer()
            Button(action: showSettings) {
                Label("Settings", systemImage: "gearshape")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 11)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Appearance and Continue Reading")
            .accessibilityIdentifier("app-settings")
        }
        .padding(12)
        .padding(.top, 12)
        .frame(width: 200)
        .background(PocketPalette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app-sidebar")
    }

    private func sidebarRow(_ title: String, symbol: String, selected: Bool, detail: DeviceSnapshot? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(2)
                    if let detail {
                        DeviceStatusLabel(device: detail, showsReader: false)
                    }
                }
            } icon: {
                Image(systemName: symbol)
            }
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, detail == nil ? 11 : 8)
                .background(selected ? PocketPalette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("navigation-\(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var desktopStudio: some View {
        VStack(spacing: 0) {
            studioTopBar
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            Divider()
            if section == .reader || section == .files {
                GeometryReader { geometry in
                    ScrollView {
                        Group {
                            if section == .files {
                                filesContents(twoColumns: geometry.size.width >= 980)
                            } else {
                                connectionContents(twoColumns: geometry.size.width >= 980)
                            }
                        }
                        .padding(24)
                        .frame(maxWidth: 1100)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityIdentifier("inspector")
                }
            } else {
                ProfileStudioView(model: model, editor: profileEditor,
                                  initialPreview: initialPreview)
                    .padding(24)
                    .frame(maxWidth: 1100, maxHeight: .infinity, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(PocketPalette.stage)
    }

    /// iPhone: Library and one Reader tab; the tab's pages sit at its top.
    private var compactStudio: some View {
        TabView(selection: Binding(
            get: { section == .library ? StudioSection.library : StudioSection.reader },
            set: { section = $0 == .library ? .library : StudioSection(lastDevicePage) })) {
            libraryView()
                .tabItem { Label(StudioSection.library.rawValue, systemImage: StudioSection.library.symbol) }
                .tag(StudioSection.library)
            readerTab
                .tabItem { Label(StudioSection.reader.rawValue, systemImage: StudioSection.reader.symbol) }
                .tag(StudioSection.reader)
        }
        .onChange(of: section) { _, value in
            if let page = value.devicePage { lastDevicePage = page }
        }
    }

    private var readerTab: some View {
        NavigationStack {
            readerPage
                .background(PocketPalette.workspace)
                .navigationTitle("Reader")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .safeAreaInset(edge: .top, spacing: 0) { readerPagePicker }
                .toolbar {
                    if section == .layout {
                        ToolbarItem(placement: .primaryAction) {
                            CompactReaderMenu(model: model) { section = .reader }
                        }
                    }
                }
        }
    }

    @ViewBuilder private var readerPage: some View {
        switch section.devicePage ?? lastDevicePage {
        case .screens:
            // The preview and Apply stay visible while settings scroll.
            ProfileStudioView(model: model, editor: profileEditor, contentPadding: 12,
                              initialPreview: initialPreview)
        case .connection, .files:
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if section == .files { filesContents() } else { connectionContents() }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    /// The reader's state and its pages, above whichever page is open.
    private var readerPagePicker: some View {
        VStack(spacing: 8) {
            DeviceStatusLabel(device: model.device, showsReader: false)
            Picker("Reader page", selection: Binding(
                get: { section.devicePage ?? lastDevicePage },
                set: { section = StudioSection($0) })) {
                ForEach(model.device.family.sections) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("device-pages")
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(PocketPalette.workspace)
    }

    /// The destination title and the current reader or preview hardware.
    private var studioTopBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(topBarTitle).font(.title2.weight(.semibold))
                    Text(topBarSubtitle)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                // The sidebar's Connection row carries the state; the chip adds the preview size on Screens.
                if section == .layout { ReaderChip(model: model) }
            }
        }
    }

    private var topBarTitle: String {
        switch section {
        case .layout: "Reader screens"
        case .files: "Files"
        default: "Connection"
        }
    }

    private var topBarSubtitle: String {
        switch section {
        case .layout: "Home, sleep and reading"
        case .files: "Send books and documents, and see what the reader holds"
        default: "Connect the reader, keep its firmware current and pair Bluetooth"
        }
    }

    // MARK: Inspector

    private func columns(twoColumns: Bool) -> AnyLayout {
        twoColumns ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                   : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
    }

    /// Reaching the reader and keeping it current.
    private func connectionContents(twoColumns: Bool = false) -> some View {
        let layout = columns(twoColumns: twoColumns)
        return layout {
            VStack(alignment: .leading, spacing: 20) {
                ConnectionInspector(model: model, nearby: nearby, onConnect: connect)
                if showsStatus { StatusCallout(message: model.message, tone: model.messageTone) }
#if DEBUG
                FirmwareUpdateCard(model: model, isUpdating: firmwareDownloadTask != nil,
                                   update: { confirmingFirmwareUpdate = true }, cancel: cancelFirmwareUpdate,
                                   sendLocalBuild: {
                                       importAction = .localFirmware
                                       importing = true
                                   })
#else
                FirmwareUpdateCard(model: model, isUpdating: firmwareDownloadTask != nil,
                                   update: { confirmingFirmwareUpdate = true }, cancel: cancelFirmwareUpdate)
#endif
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 20) {
                if !model.isDemoMode {
                    ReaderBluetoothPairingCard(sync: sync)
                    TroubleshootingInspector(model: model, nearby: nearby)
                }
                Button { showingProjectInfo = true } label: {
                    Label("About & Privacy", systemImage: "info.circle")
                }
                .buttonStyle(.borderless).font(.callout).foregroundStyle(.secondary)
                .accessibilityIdentifier("about-privacy")
            }
            .frame(width: twoColumns ? 320 : nil)
            .frame(maxWidth: twoColumns ? nil : .infinity, alignment: .topLeading)
        }
    }

    /// What goes to the reader, and what it already holds.
    private func filesContents(twoColumns: Bool = false) -> some View {
        let layout = columns(twoColumns: twoColumns)
        return layout {
            VStack(alignment: .leading, spacing: 20) {
                if showsStatus { StatusCallout(message: model.message, tone: model.messageTone) }
                if model.isTransferring, model.activeTransferKind == nil {
                    Button("Pause transfer") { model.pauseTransfer() }
                }
                if model.activeTransferKind == nil, model.uploadProgress > 0 && model.uploadProgress < 1 {
                    ProgressView(value: model.uploadProgress).progressViewStyle(.pocketBar)
                }
                FilesInspector(model: model) { urls in
                    if let first = urls.first { prepareTransfer(first, action: .wirelessUpload) }
                } choose: {
                    importAction = .wirelessUpload
                    importing = true
                } copyToSD: {
                    importAction = .sdSource
                    importing = true
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            InspectorCard(title: "On the reader", symbol: "internaldrive") {
                if model.readerStatus != nil {
                    ReaderStoragePanel(model: model)
                } else {
                    Text("Connect the reader to see its storage and the files on it.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Connect the reader") { section = .reader }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("files-connect")
                }
            }
            .frame(width: twoColumns ? 320 : nil)
            .frame(maxWidth: twoColumns ? nil : .infinity, alignment: .topLeading)
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

    private func startFirmwareUpdate() {
        guard firmwareDownloadTask == nil else { return }
        firmwareDownloadTask = Task {
            defer { firmwareDownloadTask = nil }
            await model.updateFirmware()
        }
    }

#if DEBUG
    private func inspectLocalFirmware(_ url: URL) {
        Task { localFirmware = await model.inspectLocalFirmware(url) }
    }

    private func startLocalFirmwareUpdate(_ file: URL) {
        guard firmwareDownloadTask == nil else { return }
        firmwareDownloadTask = Task {
            defer { firmwareDownloadTask = nil }
            await model.updateFirmware(fromLocalImage: file)
        }
    }
#endif

    private func cancelFirmwareUpdate() {
        if let firmwareDownloadTask { firmwareDownloadTask.cancel() }
        else if model.isTransferring, model.activeTransferKind == .firmware { model.stopAndRemoveTransfer() }
        else { model.removePreparedFiles(kind: .firmware) }
    }

    private func prepareTransfer(_ url: URL, action: FileImportAction) {
        guard !model.isDemoMode else {
            model.post("Exit demo and connect a reader before sending files.")
            return
        }
        if url.pathExtension.lowercased() == "bin" {
#if DEBUG
            // Development builds treat a chosen or dropped image as a local build.
            if action == .wirelessUpload {
                inspectLocalFirmware(url)
                return
            }
#endif
            model.post("Use Firmware update to get the latest official release. Local firmware files are not supported.", tone: .pending)
            return
        }
        performTransfer(url, action: action)
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
#if DEBUG
        case .localFirmware:
            break
#endif
        }
    }
}

/// How the reader is reached, the same wherever it appears: the sidebar's
/// Connection row, the Library header on iPhone, the Reader tab.
struct DeviceStatusLabel: View {
    let device: DeviceSnapshot
    /// Off where a title or row already says Reader.
    var showsReader = true

    private var tint: Color {
        switch device.link {
        case .sameWiFi, .direct: PocketPalette.signal
        case .connecting: .orange
        case .demo, .offline: .secondary
        }
    }

    private var text: String {
        showsReader ? "Reader · \(device.statusText)" : device.statusText
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
                .opacity(device.link == .offline ? 0.5 : 1)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(showsReader ? "Reader, \(device.statusText)" : device.statusText)
        .accessibilityIdentifier("device-status")
    }
}

/// Wide header reader state: the connected reader and how it is reached, or
/// the preview hardware choice when there is none.
private struct ReaderChip: View {
    @ObservedObject var model: PocketModel

    var body: some View {
        HStack(spacing: 8) {
            if let status = model.readerStatus, !model.isDemoMode {
                Circle().fill(PocketPalette.signal).frame(width: 8, height: 8)
                Text(status.device).font(.callout.weight(.semibold))
                Text(model.hasDirectSession ? "Direct" : "Same Wi-Fi")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Preview size", selection: $model.preferredHardware) {
                    ForEach(PocketHardware.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 100)
                .help("Screen size to preview until a reader is connected")
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
                    .foregroundStyle(PocketPalette.signal)
            }
            .accessibilityLabel("\(status.device) connected")
        } else {
            Menu {
                Picker("Preview size", selection: $model.preferredHardware) {
                    ForEach(PocketHardware.allCases) { Text($0.rawValue).tag($0) }
                }
                Button("Connect a reader", systemImage: "antenna.radiowaves.left.and.right", action: openReader)
            } label: {
                HStack(spacing: 5) {
                    Text("Preview").font(.caption).foregroundStyle(.secondary)
                    Text(model.hardware.rawValue).font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.primary)
            }
            .accessibilityIdentifier("reader-menu")
        }
    }
}

private struct PocketMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(PocketPalette.deviceTop)
                .overlay { RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.14), lineWidth: 0.5) }
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
                            Text("Independent, local-first e-book reader and reader companion")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }

                    InfoSection(title: "Reading", symbol: "books.vertical") {
                        Text("Reads DRM-free EPUB books, and text or Markdown files converted to EPUB, on this device. No reader hardware is needed.")
                    }
                    InfoSection(title: "Compatibility", symbol: "rectangle.portrait.inset.filled") {
                        Text("The companion is designed for X3/X4 hardware running Pocket Daily or compatible CrossPoint-based firmware. Factory firmware and manufacturer cloud services are not supported.")
                    }
                    InfoSection(title: "Independent project", symbol: "person.crop.circle.badge.checkmark") {
                        Text("Pocket Daily is not affiliated with, sponsored by, or endorsed by CrossPoint Reader, Xteink, or any device manufacturer.")
                    }
                    InfoSection(title: "Privacy", symbol: "lock.shield") {
                        Text("No account, analytics, advertising, or cloud relay. Your library stays on this device. Device discovery and transfer stay on Bluetooth and the local network. Reading positions stay in your own iCloud and on your reader. Pocket Daily does not read your coordinates.")
                    }
                    InfoSection(title: "Firmware responsibility", symbol: "cpu") {
                        Text("Custom firmware can affect device support or warranty. Pocket Daily offers official firmware updates and requires confirmation on the reader before installation.")
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
        NavigationLink("Reader engine and font notices") { ReaderEngineNotices() }
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

/// MIT and BSD notices for the bundled reader engine, read from the app bundle.
private struct ReaderEngineNotices: View {
    private var notices: String {
        guard let root = Bundle.main.url(forResource: "ReaderEngine", withExtension: nil) else {
            return "Reader engine notices are unavailable."
        }
        let fonts = root.deletingLastPathComponent().appendingPathComponent("ReaderFonts/PocketSymbols")
        let files = [("foliate-js (MIT)", root.appendingPathComponent("foliate-js/LICENSE")),
                     ("zip.js (BSD-3-Clause)", root.appendingPathComponent("foliate-js/vendor/zip.js.LICENSE")),
                     ("Reader symbol font: Noto Emoji (OFL 1.1)", fonts.appendingPathComponent("NotoEmoji-OFL.txt")),
                     ("Reader symbol font: Noto Sans Symbols 2 (OFL 1.1)", fonts.appendingPathComponent("NotoSansSymbols2-OFL.txt")),
                     ("Reader symbol font: Noto Sans Math (OFL 1.1)", fonts.appendingPathComponent("NotoSansMath-OFL.txt"))]
        return files.map { title, url in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "Unavailable."
            return "\(title)\n\n\(text)"
        }.joined(separator: "\n\n")
    }

    var body: some View {
        ScrollView {
            Text(notices).font(.caption).textSelection(.enabled).padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Reader engine notices")
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
/// with the message from the model, so success, a next step on the reader
/// (such as installing firmware that was sent), an interrupted operation and
/// failures are visually distinct without guessing from wording.
private struct StatusCallout: View {
    let message: String
    let tone: StatusTone

    private var symbol: String {
        switch tone {
        case .success: "checkmark.circle.fill"
        case .pending: "pause.circle.fill"
        case .onReader: "hand.tap.fill"
        case .failure: "exclamationmark.triangle.fill"
        case .neutral: "info.circle"
        }
    }

    private var color: Color {
        switch tone {
        case .success: .green
        case .pending: .orange
        case .onReader: .accentColor
        case .failure: .red
        case .neutral: .secondary
        }
    }

    private var title: String? {
        switch tone {
        case .success: "Done"
        case .pending: nil
        case .onReader: "Next: finish on the reader"
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
        InspectorCard(title: "Connection", symbol: "antenna.radiowaves.left.and.right") {
            HStack {
                Circle().fill(model.readerStatus == nil || model.isDemoMode ? Color.secondary : PocketPalette.signal)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.readerStatus?.device ?? "Reader").fontWeight(.semibold)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                    if model.readerStatus == nil && !model.isDemoMode {
                        // Compatibility, stated precisely; no product is implied.
                        Text("For X3 and X4 readers running Pocket Daily or compatible CrossPoint-based firmware.")
                            .font(.caption).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if model.isWorking || model.canCancelConnection { ProgressView().controlSize(.small) }
                if isConnected { sessionMenu }
            }
            if model.canCancelConnection {
                Button(model.isSearchingForReader ? "Cancel search" : "Cancel connection", systemImage: "xmark.circle") {
                    nearby.disconnect()
                    model.cancelConnectionAttempt()
                }
                .accessibilityIdentifier("cancel-reader-connection")
            } else if model.isCancellingConnection {
                Text("Stopping connection…").font(.callout).foregroundStyle(.secondary)
            }
            actions
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
                        .buttonStyle(.borderedProminent).disabled(model.isWorking)
                    Text(lease.ssid)
                    Text(lease.passphrase).textSelection(.enabled)
                    Button("Verify connection") {
                        Task { await model.verifyNearbyLease(lease) }
                    }.disabled(model.isWorking)
                }
                .font(.caption.monospaced())
                .padding(9)
                .background(PocketPalette.workspace, in: RoundedRectangle(cornerRadius: 8))
            }
        }
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
    }

    private var isConnected: Bool { model.readerStatus != nil && !model.isDemoMode }

    /// Only what makes sense now: leave demo; connect (and how); or, once
    /// connected, nothing here, since session actions sit in the ⋯ menu.
    @ViewBuilder private var actions: some View {
        if model.canCancelConnection || model.isCancellingConnection {
            EmptyView()
        } else if model.isDemoMode {
            Button("Exit demo") { model.exitDemoMode() }
                .buttonStyle(.borderedProminent).tint(PocketPalette.accent).frame(maxWidth: .infinity)
                .disabled(model.isWorking)
        } else if model.hasDirectSession, model.readerStatus == nil {
            Button("Reconnect directly") { confirmingDirectConnection = true }
                .buttonStyle(.borderedProminent).tint(PocketPalette.accent).frame(maxWidth: .infinity)
                .disabled(model.isWorking)
            Button("End session") { nearby.disconnect(); model.endConnection() }
                .buttonStyle(.borderless).font(.callout)
                .disabled(model.isWorking)
        } else if model.readerStatus == nil {
            Button("Find on same Wi-Fi", action: onConnect)
                .buttonStyle(.borderedProminent).tint(PocketPalette.accent).frame(maxWidth: .infinity)
                .disabled(model.isWorking)
            HStack {
                Button("Connect directly") { confirmingDirectConnection = true }
                    .disabled(model.isWorking)
                Spacer()
                Button("Try demo") { nearby.disconnect(); model.enterDemoMode() }
                    .accessibilityIdentifier("try-demo")
                    .disabled(model.isWorking)
            }
            .buttonStyle(.borderless)
            .font(.callout)
            DisclosureGroup("How to connect", isExpanded: $showingHelp) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("**Same Wi-Fi** · On the reader: Pocket Daily → Sync → Same Wi-Fi. This device stays on its network.")
                    Text("**Direct** · On the reader choose Direct connection, then Connect directly here. Works without a router.")
                    Text("Keep Sync open on the reader while you apply changes. Older firmware calls these Join a Network and Nearby Sync.")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }

    /// Session actions for a connected reader, out of the way until needed.
    private var sessionMenu: some View {
        Menu {
            if model.hasDirectSession {
                Button("Reconnect directly", systemImage: "arrow.clockwise") { confirmingDirectConnection = true }
            } else {
                Button("Reconnect", systemImage: "arrow.clockwise", action: onConnect)

            }
            Divider()
            Button("End session", systemImage: "xmark.circle", role: .destructive) {
                nearby.disconnect()
                model.endConnection()
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.isWorking)
        .accessibilityLabel("Reader actions")
        .accessibilityIdentifier("reader-actions")
    }

    private var detail: String {
        if model.isDemoMode { return "Demo · nothing is sent" }
        if model.isCancellingConnection { return "Stopping connection…" }
        if model.isSearchingForReader { return "Searching on this Wi-Fi…" }
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

/// One update action; transfer bookkeeping is only exposed for recovery.
struct FirmwareUpdateCard: View {
    @ObservedObject var model: PocketModel
    let isUpdating: Bool
    let update: () -> Void
    let cancel: () -> Void
#if DEBUG
    /// Development builds only: choose a firmware image built on this machine.
    var sendLocalBuild: (() -> Void)? = nil
#endif
    @State private var confirmingLocalRemoval = false

    private var pending: Bool { model.preparedTransfers.contains { $0.kind == .firmware } }
    private var sending: Bool { model.isTransferring && model.activeTransferKind == .firmware }

    var body: some View {
        InspectorCard(title: "Firmware", symbol: "cpu") {
            if model.isDemoMode {
                Text("Firmware updates appear when you connect a reader.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if let release = model.latestFirmwareRelease {
                    Text("Latest · \(release.version)\(release.isBeta ? " (beta)" : "")")
                        .font(.callout.weight(.medium))
                    if let date = release.publishedAt {
                        Text("Released \(date.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if isUpdating || sending {
                    if sending {
                        ProgressView(value: model.uploadProgress).progressViewStyle(.pocketBar)
                        Text(model.uploadProgress >= 1 ? "Saving on reader…" : "Sending · \(Int(model.uploadProgress * 100))%")
                            .font(.caption)
                    } else {
                        ProgressView(model.readerUpdateState == .idle ? "Preparing update…" : "Downloading update…")
                            .font(.caption)
                    }
                    Button("Cancel", action: cancel).accessibilityIdentifier("cancel-firmware-update")
                } else if pending {
                    Text("Update interrupted").font(.callout)
                    HStack {
                        Button("Resume update") { model.sendPreparedFiles(kind: .firmware) }
                            .disabled(model.readerStatus == nil || model.isWorking)
                        Button("Cancel", action: cancel).disabled(model.isWorking)
                    }
                    if model.messageTone == .failure {
                        Text("Reconnect to the same reader to finish cleanup, or forget this update on this device.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Forget update…") { confirmingLocalRemoval = true }
                            .font(.caption).disabled(model.isWorking)
                    }
                } else if let version = model.firmwareAwaitingInstallation {
                    Text("\(version) sent · confirm installation on the reader")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let version = model.firmwareLeftForInstallation {
                    Text("\(version) sent · the reader is installing it or waiting for Install. Open Sync → Same Wi-Fi on it afterwards to confirm.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.isCheckingFirmware {
                    ProgressView("Checking for updates…").font(.caption)
                    Button("Cancel check") { model.cancelFirmwareCheck() }
                        .accessibilityIdentifier("cancel-firmware-check")
                } else if model.firmwareCheckError != nil, model.readerStatus == nil {
                    Text("Firmware updates appear when you connect a reader.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let error = model.firmwareCheckError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("Check again") { Task { await model.checkFirmwareRelease() } }
                        .disabled(model.hasDirectSession)
                } else if model.firmwareUpdateAvailable {
                    Button("Update available", action: update)
                        .buttonStyle(.borderedProminent).disabled(!model.canUpdateReader)
                        .accessibilityIdentifier("update-reader")
                    Text(model.hasDirectSession ? "Use an internet connection to download the update." : "Confirm installation on the reader after sending.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.latestFirmwareRelease != nil, let status = model.readerStatus {
                    Text(FirmwareGuidance.parse(status.version) == nil ? "Reader version could not be compared." : "No newer update available")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(model.readerStatus == nil ? "Connect a reader to check its version." : "Connect to the internet to check for updates.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.latestFirmwareRelease == nil {
                        Button("Check for updates") { Task { await model.checkFirmwareRelease() } }
                            .disabled(model.hasDirectSession)
                    }
                }
#if DEBUG
                if let sendLocalBuild, model.readerStatus != nil, !isUpdating, !sending, !pending {
                    Divider()
                    Button("Send a local build…", action: sendLocalBuild)
                        .disabled(!model.canSendLocalFirmware)
                        .accessibilityIdentifier("send-local-firmware")
                    Text("Development builds only. Checks a firmware image from this device and sends it like an update; the reader still asks before installing.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
#endif
            }
        }
        .accessibilityIdentifier("firmware-update-card")
        .alert("Forget this update?", isPresented: $confirmingLocalRemoval) {
            Button("Forget update", role: .destructive) { model.removePreparedFiles(kind: .firmware, localOnly: true) }
            Button("Keep update", role: .cancel) {}
        } message: {
            Text("Removes the local copy only. Temporary data on the reader may remain. Already saved firmware is unchanged.")
        }
    }
}

/// Books and study packs for the reader; prepared files wait here
/// until a reader is connected.
private struct FilesInspector: View {
    @ObservedObject var model: PocketModel
    let receive: ([URL]) -> Void
    let choose: () -> Void
    let copyToSD: () -> Void
    @State private var targeted = false
    @State private var writing = false

    private var isEnabled: Bool { model.canPrepareFiles }

    private var dropLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: targeted ? "arrow.down.doc.fill" : "doc.badge.plus")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(targeted ? "Drop to prepare" : "Books and documents")
                    .font(.callout.weight(.medium))
                Text("EPUB · TXT · MD · XTC · PDL").font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    /// Every way to add a file, in one place.
    private var addMenu: some View {
        Menu {
            Button("Choose a file…", systemImage: "doc", action: choose)
                .accessibilityIdentifier("choose-file")
            Button("Write text to read…", systemImage: "square.and.pencil") { writing = true }
                .accessibilityIdentifier("write-text")
#if os(macOS)
            Divider()
            Button("Copy a file to an SD card…", systemImage: "sdcard", action: copyToSD)
                .accessibilityIdentifier("copy-to-sd")
#endif
        } label: {
            Label("Add files", systemImage: "plus")
        }
        .fixedSize()
        .disabled(!isEnabled)
        .accessibilityIdentifier("files-add")
    }

    var body: some View {
        InspectorCard(title: "Files", symbol: "tray.full") {
            // The menu moves under the label when the inspector is narrow.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    dropLabel.fixedSize()
                    Spacer(minLength: 0)
                    addMenu
                }
                VStack(alignment: .leading, spacing: 10) {
                    dropLabel
                    addMenu
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
            .sheet(isPresented: $writing) {
                TextDocumentComposer { url in try await model.prepareGeneratedReadingFile(url) }
            }
            if model.hasDirectSession {
                Text("Only files already on this device can be prepared while connected directly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Books, articles and written text are saved on the reader’s SD card. Saved articles and your books are in the Library.")
                .font(.caption).foregroundStyle(.secondary)
            if !model.isDemoMode { ReaderSymbolFontOffer(model: model) }
            PreparedTransferQueue(model: model, kind: .content)
        }
    }
}

/// Categories have independent send/remove actions even when both are pending.
private struct PreparedTransferQueue: View {
    @ObservedObject var model: PocketModel
    let kind: TransferKind
    @State private var confirmingRemoval = false
    @State private var confirmingStop = false
    @State private var confirmingLocalRemoval = false
    private var items: [PreparedTransfer] { model.preparedTransfers.filter { $0.kind == kind } }
    private var isActive: Bool { model.isTransferring && model.activeTransferKind == kind }
    private var sendTitle: String {
        let verb = items.contains { $0.stagingID != nil } ? "Resume" : "Send"
        return "\(verb) \(kind.rawValue)"
    }

    var body: some View {
        if !items.isEmpty, !model.isDemoMode {
            VStack(alignment: .leading, spacing: 8) {
                Text("Ready · \(items.count)").font(.subheadline.weight(.semibold))
                ForEach(items) { item in
                    Text(item.filename).font(.caption).lineLimit(2)
                    if item.publicationPending == true {
                        Text("Publication not confirmed. Check the file on the reader. Remove this prepared copy before preparing it again; removing it does not delete a published file.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(model.destinationLabel(for: item)).font(.caption2).foregroundStyle(.secondary)
                }
                if isActive {
                    ProgressView(value: model.uploadProgress).progressViewStyle(.pocketBar)
                    Text(model.uploadProgress >= 1 ? "Saving on SD card…" : "Sending · \(Int(model.uploadProgress * 100))%")
                        .font(.caption)
                    HStack {
                        Button("Pause") { model.pauseTransfer() }
                        Button("Stop and remove…", role: .destructive) { confirmingStop = true }
                    }
                } else {
                    HStack {
                        Button(sendTitle) { model.sendPreparedFiles(kind: kind) }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.readerStatus == nil || model.isWorking)
                        Button(kind == .content ? "Remove content…" : "Remove firmware…") { confirmingRemoval = true }
                            .disabled(model.isWorking)
                    }
                    if items.contains(where: { $0.stagingID != nil }) {
                        Text("Paused or interrupted copies are kept for retry. Remove cleans their temporary files on the connected reader.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Remove only local copies…") { confirmingLocalRemoval = true }
                            .font(.caption).disabled(model.isWorking)
                    }
                }
            }
            .alert("Remove prepared \(kind.rawValue)?", isPresented: $confirmingRemoval) {
                Button("Remove prepared copies", role: .destructive) { model.removePreparedFiles(kind: kind) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes this category’s prepared copies and its tracked temporary files on the reader. Original sources and completed reader files stay.")
            }
            .alert("Stop and remove this transfer?", isPresented: $confirmingStop) {
                Button("Stop and remove", role: .destructive) { model.stopAndRemoveTransfer() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Stops this category and cleans its temporary files. If the connection is lost, the queue stays so you can retry cleanup. Already saved files stay.")
            }
            .alert("Remove only local copies?", isPresented: $confirmingLocalRemoval) {
                Button("Remove local copies", role: .destructive) { model.removePreparedFiles(kind: kind, localOnly: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The reader is not cleaned up. Its temporary files may remain on SD. Already saved content and firmware are unchanged.")
            }
        }
    }
}

/// Crash report and connection log, folded away until a connection needs
/// attention.
private struct TroubleshootingInspector: View {
    @ObservedObject var model: PocketModel
    @ObservedObject var nearby: NearbySyncController
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 14) {
                if let diagnostic = model.crashDiagnostic {
                    DiagnosticsInspector(diagnostic: diagnostic)
                }
                ConnectionTraceInspector(nearby: nearby)
            }
            .padding(.top, 8)
        } label: {
            Label(model.crashDiagnostic == nil ? "Troubleshooting" : "Troubleshooting · crash report saved",
                  systemImage: "wrench.and.screwdriver")
                .font(.callout.weight(.medium))
        }
    }
}

private struct DiagnosticsInspector: View {
    let diagnostic: CrashDiagnostic
    @State private var expanded = false

    var body: some View {
        InspectorCard(title: "Diagnostics", symbol: "waveform.path.ecg") {
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
                        .font(.caption2.monospaced())
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
        InspectorCard(title: "Connection log", symbol: "point.3.connected.trianglepath.dotted") {
            Text(nearby.traceAnalysis).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(expanded ? "Hide log" : "Show log") { expanded.toggle() }.buttonStyle(.bordered)
                ShareLink("Export log", item: nearby.traceReport)
            }
            if expanded {
                ScrollView([.horizontal, .vertical]) {
                    Text(nearby.traceReport)
                        .font(.caption2.monospaced())
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
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(PocketPalette.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).stroke(PocketPalette.line, lineWidth: 1) }
    }
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
