import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Library and My Reader are peers. Settings and management are reader details,
/// not separate app destinations. Task ownership uses the same detail routes.
enum StudioSection: String, CaseIterable, Hashable {
    case library = "Library", reader = "My Reader"
    case customize = "Reader Settings", device = "Manage Reader"

    var symbol: String {
        switch self {
        case .library: "books.vertical"
        case .reader: "rectangle.portrait.inset.filled"
        case .customize: "slider.horizontal.3"
        case .device: "antenna.radiowaves.left.and.right"
        }
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
    private static let wideWidth = PocketDesign.wideLayoutWidth

    @AppStorage("appAppearance") private var appearance = AppAppearance.system
    @ObservedObject private var readerAppearance = ReaderAppearanceStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var model: PocketModel
    @Environment(\.readerFleet) private var fleet
    private let isActive: Bool
    private let workspace: ReaderWorkspace?
    @StateObject private var nearby: NearbySyncController
    @StateObject private var profileEditor = ProfileEditorState()
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var sync = ReadingSync.shared
    @ObservedObject private var readerLink: ReaderBluetoothLink
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
    @State private var showingConnection = false
    @State private var readerOnlyExpanded = false
    @State private var deviceDetailsExpanded = false
    /// The page the compact Reader tab returns to.
    @State private var lastReaderSection: StudioSection = .reader
    @State private var transferTask: ReadingTarget?
    @State private var contentTaskRequest: ProfileStudioView.SourceTaskRequest?
    @State private var screenTaskRequest: ProfileStudioView.ScreenTaskRequest?
    @State private var firmwareDownloadTask: Task<Void, Never>?
    @State private var draftPersistence = ProfileDraftPersistence()
    @State private var draftLoading = true
    @State private var lastProfileSnapshot: ProfileEditSnapshot?
    @State private var draftRevision = 0
    @State private var draftGeneration = 0

    @State private var readerSetting: ProfileStudioView.PreviewSurface

    /// The store screenshots open a given tab and preview surface.
    @MainActor
    init(initialSection: StudioSection = .library, initialPreview: ProfileStudioView.PreviewSurface = .home,
         initialBookID: UUID? = nil, initialShelf: LibraryView.Shelf = .books, inbox: ArticleInboxModel? = nil,
         bluetoothLink: ReaderBluetoothLink? = nil, profileStore: ProfileEditStore = .live, isActive: Bool = true, workspace: ReaderWorkspace? = nil) {
        let bluetoothLink = bluetoothLink ?? ReaderBluetoothLink.shared
        self.isActive = isActive
        self.workspace = workspace
        if let workspace { _profileEditor = StateObject(wrappedValue: workspace.editor) }
        _readerLink = ObservedObject(wrappedValue: bluetoothLink)
        _nearby = StateObject(wrappedValue: workspace?.nearby ?? NearbySyncController(ownershipChanged: { bluetoothLink.nearbySessionActive = $0 }))
        _draftPersistence = State(initialValue: ProfileDraftPersistence(store: profileStore))
        _inbox = ObservedObject(wrappedValue: inbox ?? .shared)
        _shelf = State(initialValue: initialShelf)
        _section = State(initialValue: initialSection)
        _reading = State(initialValue: initialBookID.map { ReadingTarget(id: $0) })
        _readerSetting = State(initialValue: initialPreview)
    }

    private var presentedContent: some View {
        ZStack {
            GeometryReader { proxy in
                if proxy.size.width >= Self.wideWidth && !dynamicTypeSize.isAccessibilitySize {
                    wideLayout(titlebarInset: proxy.safeAreaInsets.top)
                        .safeAreaInset(edge: .bottom, spacing: 0) { transferTaskEntry(on: section) }
#if os(macOS)
                        .ignoresSafeArea(.container, edges: .top)
#endif
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
#if os(macOS)
        .focusedSceneValue(\.settingsPresentation, isActive ? $showingSettings : nil)
#endif
        .sheet(item: $transferTask) { task in
            BookTransferSheet(model: model, jobID: task.id, library: library,
                              connection: {
                                  VStack(alignment: .leading, spacing: 16) {
                                      ConnectionInspector(model: model, nearby: nearby, onConnect: connect, offersDemo: false,
                                                          connectsOnOpen: true)
                                      if showsStatus { StatusCallout(message: model.message, tone: model.messageTone) }
                                  }
                              },
                              cancelConnection: { nearby.disconnect(); model.cancelConnectionAttempt() },
                              onInventory: { transferTask = nil; section = .reader },
                              onDevice: { transferTask = nil; section = .device },
                              onCurrentTask: openCurrentReaderTask)
        }
        .onOpenURL { url in
            guard isActive else { return }
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
            guard workspace == nil else { return }
            if let lease, model.directConnectionRequested { model.useNearbyLease(lease) }
        }
        .onChange(of: nearby.state) { _, state in
            guard workspace == nil else { return }
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
                if isActive { Task { await inbox.activate(allowNetwork: !model.isDemoMode) } }
                sync.nudgeReader()
                readerLink.start()
            }
            else if phase == .background && isActive { inbox.suspend() }
#if os(iOS)
            if phase == .background {
                nearby.disconnect()
                model.pauseForBackground()
            }
#endif
        }
        .alert(firmwareConfirmationTitle, isPresented: $confirmingFirmwareUpdate) {
            Button("Send Update") { startFirmwareUpdate() }
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
            AppSettingsSheet(model: model, appearance: $appearance, openDevice: {
                showingSettings = false
                section = .device
            })
        }
        .sheet(isPresented: $showingConnection) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Connect your reader").font(PocketDesign.pageTitle)
                    Spacer()
                    Button("Done") { showingConnection = false }
                        .accessibilityIdentifier("connection-done")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ConnectionInspector(model: model, nearby: nearby, onConnect: connect,
                                            offersDemo: section != .customize, connectsOnOpen: true)
                        if showsStatus { StatusCallout(message: model.message, tone: model.messageTone) }
                    }
                }
                Text(section == .customize ? "Your edits stay here. Apply them when you are ready." : "Your files stay ready. Choose Send after connecting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
#if os(macOS)
            .frame(width: 500, height: 480)
#endif
            .onChange(of: model.device.isConnected) { _, connected in
                if connected { showingConnection = false }
            }
        }
    }

    var body: some View {
        presentedContent
        .onChange(of: readerSetting) { _, value in workspace?.preview = value }
        .onChange(of: isActive) { _, active in
            if active { section = .reader }
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
            guard workspace == nil, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            while !Task.isCancelled {
                model.reconnectRememberedReader()
                try? await Task.sleep(for: .seconds(8))
            }
        }
        .task(id: model.isDemoMode) {
            guard workspace == nil else { return }
            draftGeneration += 1
            draftRevision += 1
            let generation = draftGeneration
            let demo = model.isDemoMode
            draftLoading = true
            profileEditor.reset()
            profileEditor.localSaveError = nil
            if !demo {
                do {
                    let snapshot = try await draftPersistence.load()
                    guard !Task.isCancelled, generation == draftGeneration, model.isDemoMode == demo else { return }
                    profileEditor.restore(snapshot)
                    profileEditor.observeTarget(model.readerStatus?.deviceID)
                    profileEditor.sync(with: model.readerProfile)
                    profileEditor.syncReading(model.preferencesBaseline ?? model.preferences)
                } catch {
                    guard !Task.isCancelled, generation == draftGeneration, model.isDemoMode == demo else { return }
                    profileEditor.localSaveError = error.localizedDescription
                }
            }
            guard !Task.isCancelled, generation == draftGeneration, model.isDemoMode == demo else { return }
            lastProfileSnapshot = comparableSnapshot(profileEditor.snapshot)
            draftLoading = false
        }
        .onReceive(profileEditor.objectWillChange.debounce(for: .milliseconds(400), scheduler: RunLoop.main)) { _ in
            guard workspace == nil, !model.isDemoMode, !draftLoading else { return }
            let snapshot = profileEditor.snapshot
            let comparable = comparableSnapshot(snapshot)
            // Restore and status-only changes never overwrite a failed load.
            guard comparable != lastProfileSnapshot else { return }
            lastProfileSnapshot = comparable
            draftRevision += 1
            let revision = draftRevision
            let generation = draftGeneration
            Task {
                do {
                    try await draftPersistence.save(snapshot, revision: revision)
                    guard generation == draftGeneration, revision == draftRevision, !model.isDemoMode, !draftLoading else { return }
                    if profileEditor.localSaveError != nil { profileEditor.localSaveError = nil }
                } catch {
                    guard generation == draftGeneration, revision == draftRevision, !model.isDemoMode, !draftLoading else { return }
                    if profileEditor.localSaveError != error.localizedDescription { profileEditor.localSaveError = error.localizedDescription }
                    model.post("Your layout edits could not be saved on this device: \(error.localizedDescription)", tone: .failure)
                }
            }
        }
        .task(id: model.isDemoMode) {
            // Authenticated pairing: remember this reader for reading sync over Bluetooth.
            if workspace == nil {
            nearby.onAuthenticated = { peripheral, status in
                guard !model.isDemoMode else { return }
                do { try model.acceptsBluetoothReader(status.deviceID, peripheral) }
                catch {
                    readerLink.setup = .failed(error.localizedDescription)
                    model.directDiscoveryFailed(error.localizedDescription)
                    nearby.disconnect()
                    return
                }
                readerLink.remember(peripheral: peripheral, readerID: status.deviceID, model: status.model,
                                    supportsReadingSync: status.capabilities.contains(ReadingSyncBLE.capability))
            }
            nearby.acceptsPeripheral = { model.acceptsPeripheral($0) }
            readerLink.requestSetupConnection = { nearby.scan() }
            readerLink.endSetupConnection = { nearby.disconnect() }
            }
            if isActive {
                if model.isDemoMode { inbox.cancelRefresh() }
                await inbox.activate(allowNetwork: !model.isDemoMode)
            }
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

    private func comparableSnapshot(_ snapshot: ProfileEditSnapshot?) -> ProfileEditSnapshot? {
        guard var snapshot else { return nil }
        snapshot.savedAt = Date(timeIntervalSince1970: 0)
        return snapshot
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
                    openDevice: showsShelfMenu ? { section = .reader } : nil,
                    sendToReader: beginBookTransfer,
                    taskFooter: showsShelfMenu ? AnyView(transferTaskEntry(on: .library)) : nil, open: open)
    }

    private func beginBookTransfer(_ book: LibraryBook) {
        Task {
            if let id = await model.createBookTransferJob(books: [book], library: library,
                origin: BookTransferOrigin(collection: shelf.rawValue, focusedBookID: book.id)) {
                transferTask = ReadingTarget(id: id)
            } else if let error = model.bookTransferError { library.error = error }
        }
    }

    /// One way back to open work: a single job reopens directly, several
    /// are listed in one menu. My Reader lists the same jobs in its body, so
    /// the bar stays out of the way there.
    @ViewBuilder private func transferTaskEntry(on destination: StudioSection) -> some View {
        let jobs = model.bookTransferJobs.filter { $0.requiresAttention }
        if destination != .reader, !jobs.isEmpty || auxiliaryTask != nil {
            HStack {
                if let job = jobs.first, jobs.count == 1 {
                    Button { transferTask = ReadingTarget(id: job.id) } label: {
                        Label("\(job.items.first?.title ?? "Books") · \(job.presentationStatus)", systemImage: "arrow.up.doc")
                            .lineLimit(1)
                    }
                    .accessibilityIdentifier("book-transfer-reopen")
                } else if !jobs.isEmpty {
                    Menu {
                        ForEach(jobs) { job in
                            Button("\(job.items.first?.title ?? "Books") · \(job.presentationStatus)") {
                                transferTask = ReadingTarget(id: job.id)
                            }
                        }
                    } label: {
                        Label("Book Transfers · \(jobs.count)", systemImage: "arrow.up.doc")
                    }
                    .accessibilityIdentifier("book-transfer-reopen")
                }
                Spacer()
                if let task = auxiliaryTask {
                    Button(task.title, action: openCurrentReaderTask)
                        .accessibilityIdentifier("reader-task-reopen")
                }
            }
            .font(.callout).padding(.horizontal, PocketDesign.pageInset).padding(.vertical, 12)
            .background(PocketPalette.panel)
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("book-transfer-progress-entry")
        }
    }

    private var auxiliaryTaskOwner: ReaderTaskDestination? {
        if let task = model.activeReaderTask { return task }
        if firmwareDownloadTask != nil || model.readerUpdateState != .idle ||
            model.firmwareAwaitingInstallation != nil || model.firmwareLeftForInstallation != nil { return .firmware }
        if let deployment = model.contentDeployment, [.needsConfirmation, .failed, .cancelled].contains(deployment.phase) { return .cards }
        return nil
    }

    private var auxiliaryTask: (title: String, destination: StudioSection)? {
        guard let task = auxiliaryTaskOwner, let destination = StudioSection.owner(of: task) else { return nil }
        let title: String
        if model.firmwareAwaitingInstallation != nil || model.firmwareLeftForInstallation != nil {
            title = "Confirm firmware installation"
        } else if case .cards = task, model.activeReaderTask == nil { title = "Check My cards result" }
        else { title = task.title }
        return (title, destination)
    }

    private func openCurrentReaderTask() {
        guard let task = auxiliaryTaskOwner else { return }
        if case .bookTransfer(let id) = task {
            transferTask = ReadingTarget(id: id)
            return
        }
        transferTask = nil
        switch task {
        case .cards:
            if readerSetting == .reading { readerSetting = .home }
            contentTaskRequest = .init(id: UUID(), destination: .cards)
        case .weatherCalendar:
            if readerSetting == .reading { readerSetting = .home }
            contentTaskRequest = .init(id: UUID(), destination: .weatherCalendar)
        case .diagnostics: deviceDetailsExpanded = true
        case .reading: readerSetting = .reading
        case .screens:
            screenTaskRequest = .init(id: UUID(), screen: model.activeScreenTarget ?? .home)
        default: break
        }
        if let destination = StudioSection.owner(of: task) { section = destination }
    }

    /// Present settings in the window where the user is working.
    private func showSettings() {
        showingSettings = true
    }

    /// One navigation rail replaces the two stacked section pickers.
    private func wideLayout(titlebarInset: CGFloat) -> some View {
        HStack(spacing: 0) {
            sidebar(titlebarInset: titlebarInset)
            Divider()
            if section == .library {
                libraryView(showsShelfMenu: false)
            } else {
                desktopStudio
            }
        }
    }

    private func sidebar(titlebarInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                PocketMark()
                Text("Pocket Daily").font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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
                    sidebarRow("My Reader", symbol: StudioSection.reader.symbol,
                               selected: section != .library, detail: model.device) { section = .reader }
                }
            }
            .scrollIndicators(.hidden)
            Button(action: showSettings) {
                HStack(spacing: 10) {
                    PocketSymbol("gearshape", role: .navigation)
                    Text("Settings").font(.subheadline)
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: PocketDesign.navigationTarget)
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Appearance and Continue Reading")
            .accessibilityIdentifier("app-settings")
        }
        .padding(12)
#if os(macOS)
        .padding(.top, 4 + titlebarInset)
#else
        .padding(.top, 4)
#endif
        .frame(width: PocketDesign.sidebarWidth)
        .background(PocketPalette.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("app-sidebar")
    }

    private func sidebarRow(_ title: String, symbol: String, selected: Bool, detail: DeviceSnapshot? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: detail == nil ? .center : .top, spacing: 10) {
                PocketSymbol(symbol, role: .navigation)
                    .padding(.top, detail == nil ? 0 : 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(2)
                    if let detail {
                        DeviceStatusLabel(device: detail, showsReader: false)
                    }
                }
            }
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(minHeight: PocketDesign.navigationTarget)
                .background(selected ? PocketPalette.selection : Color.clear, in: RoundedRectangle(cornerRadius: PocketDesign.controlRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("navigation-\(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var desktopStudio: some View {
        VStack(spacing: 0) {
            HStack {
                if section != .reader {
                    Button { section = .reader } label: { PocketActionGlyph(name: "chevron.left") }
                        .buttonStyle(.plain).accessibilityLabel("Back to My Reader")
                        .accessibilityIdentifier("reader-back")
                }
                Text(section.rawValue).font(PocketDesign.pageTitle)
                Spacer()
            }
            .padding(.horizontal, PocketDesign.pageInset).padding(.vertical, 12)
            Divider()
            readerDestination(section, padding: PocketDesign.pageInset)
        }
        .background(PocketPalette.stage)
    }

    private var compactStudio: some View {
        TabView(selection: Binding(
            get: { section == .library ? StudioSection.library : StudioSection.reader },
            set: { section = $0 == .library ? .library : lastReaderSection })) {
            libraryView()
                .tabItem { Label("Library", systemImage: StudioSection.library.symbol) }
                .tag(StudioSection.library)
            readerTab
                .tabItem { Label("My Reader", systemImage: StudioSection.reader.symbol) }
                .tag(StudioSection.reader)
        }
        .onChange(of: section) { _, value in
            if value != .library { lastReaderSection = value }
        }
    }

    private var readerTab: some View {
        NavigationStack(path: Binding(
            get: { section != .library && section != .reader ? [section] : [] },
            set: { section = $0.last ?? .reader })) {
            compactReaderContent(.reader, padding: PocketDesign.compactInset)
                .navigationTitle("My Reader")
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
                .navigationDestination(for: StudioSection.self) { destination in
                    compactReaderContent(destination, padding: PocketDesign.compactInset)
                        .navigationTitle(destination.rawValue)
#if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
#endif
                }
        }
    }

    /// Reserve task height in the actual navigation content, so scrolling and
    /// pinned editor actions finish above it and the system tab bar.
    private func compactReaderContent(_ destination: StudioSection, padding: CGFloat) -> some View {
        VStack(spacing: 0) {
            readerDestination(destination, padding: padding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            transferTaskEntry(on: destination)
        }
    }

    @ViewBuilder private func readerDestination(_ destination: StudioSection, padding: CGFloat) -> some View {
        if destination == .customize {
            ProfileStudioView(model: model, editor: profileEditor, contentPadding: padding,
                              initialPreview: readerSetting, previewSelection: $readerSetting,
                              sourceTaskRequest: contentTaskRequest,
                              onSourceTaskOpened: { contentTaskRequest = nil },
                              screenTaskRequest: screenTaskRequest,
                              onScreenTaskOpened: { screenTaskRequest = nil },
                              connectionContent: {
                                  AnyView(VStack(alignment: .leading, spacing: 16) {
                                      ConnectionInspector(model: model, nearby: nearby, onConnect: connect, offersDemo: false,
                                                          connectsOnOpen: true)
                                      if showsStatus { StatusCallout(message: model.message, tone: model.messageTone) }
                                  })
                              },
                              cancelConnection: { nearby.disconnect(); model.cancelConnectionAttempt() },
                              onConnect: { showingConnection = true })
                .id(destination)
                .frame(maxWidth: PocketDesign.contentWidth, maxHeight: .infinity, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: PocketDesign.sectionSpacing) {
                    switch destination {
                    case .reader: readerOverview()
                    default: connectionContents()
                    }
                }
                .padding(padding)
                .frame(maxWidth: PocketDesign.contentWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityIdentifier("inspector")
            .scrollDismissesKeyboard(.interactively)
            .background(PocketPalette.workspace)
        }
    }

    /// One reader workspace: identity and actions, retained work, then its books.
    /// Offline is a normal state; editors and last-observed files stay accessible.
    private func readerOverview() -> some View {
        VStack(alignment: .leading, spacing: PocketDesign.sectionSpacing) {
            if let fleet { ReaderPicker(fleet: fleet) }
            InspectorCard(title: model.registrationName ?? model.readerStatus?.device ?? readerLink.rememberedReader?.model ?? (model.hasKnownReader ? "Remembered reader" : "Your reader"), symbol: "rectangle.portrait") {
                HStack(alignment: .top) {
                    DeviceStatusLabel(device: model.device, showsReader: false)
                    Spacer()
                    Menu {
                        Button("Manage Reader…", systemImage: "antenna.radiowaves.left.and.right") { section = .device }
                            .accessibilityIdentifier("reader-manage")
                    } label: {
                        PocketActionGlyph(name: "ellipsis")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Reader Options")
                    .accessibilityIdentifier("reader-management-menu")
                }
                if let paired = readerLink.rememberedReader, !model.isDemoMode {
                    // One Bluetooth line: what it is, and when it last worked.
                    let state = paired.supportsReadingSync == true ? readerLink.statusText : "Paired · position sharing not confirmed"
                    let last = readerLink.lastCompletedAt.map { " · exchanged \($0.formatted(.relative(presentation: .named)))" } ?? ""
                    Text("Bluetooth · \(paired.model) · \(state)\(last)")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("overview-bluetooth-status")
                }
                if model.device.capabilities.contains(.bluetoothSync), !model.device.isConnected {
                    Text("Bluetooth can share reading positions. Connect over Wi-Fi to send files or settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.isDemoMode && !model.hasKnownReader && !model.device.isConnected {
                    Text("For X3 and X4 readers running Pocket Daily or compatible CrossPoint-based firmware.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { readerActions }
                    VStack(alignment: .leading, spacing: 10) { readerActions }
                }
                if !model.device.isConnected && !model.isDemoMode {
                    Text("Edit settings now. Connect when you’re ready to apply them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if profileEditor.isDirty || profileEditor.readingDirty {
                InspectorCard(title: model.isDemoMode ? "Preview changes" : profileEditor.localSaveError == nil ? "Saved edits" : "Unsaved edits", symbol: "pencil") {
                    if let error = profileEditor.localSaveError {
                        PocketStatusLabel("Draft could not be saved · " + error, tone: .failure).font(.callout)
                    } else {
                        Text(model.isDemoMode ? "These changes stay in this demo. Nothing is sent."
                             : "Your reader settings are saved in this app and have not been applied.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Button("Continue Editing") {
                        resumeReaderEdits()
                    }.buttonStyle(.bordered).accessibilityIdentifier("reader-resume-edits")
                }
            }
            if !model.bookTransferJobs.filter({ $0.requiresAttention }).isEmpty {
                InspectorCard(title: "Book transfers", symbol: "arrow.up.doc") {
                    ForEach(model.bookTransferJobs.filter { $0.requiresAttention }) { job in
                        Button {
                            transferTask = ReadingTarget(id: job.id)
                        } label: {
                            HStack {
                                Text(job.items.first?.title ?? "Selected books")
                                Spacer()
                                Text(job.presentationStatus).foregroundStyle(.secondary)
                                PocketSymbol("chevron.right", role: .accessory)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            if let task = auxiliaryTask {
                Button(task.title, action: openCurrentReaderTask).buttonStyle(.bordered)
            }
            filesContents()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-overview")
    }

    private func resumeReaderEdits() {
        let current: ProfileEditorState.Scope = readerSetting == .reading ? .reading : readerSetting == .sleep ? .sleep : .home
        let scope = ([current] + [.home, .sleep, .reading]).first { !profileEditor.pending(in: $0).isEmpty } ?? current
        readerSetting = scope == .reading ? .reading : scope == .sleep ? .sleep : .home
        section = .customize
    }

    @ViewBuilder private var readerActions: some View {
        if !model.device.isConnected {
            Button(model.isDemoMode ? "Explore Connection" : "Connect Reader…") { showingConnection = true }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("overview-connect")
        }
        Button("Reader Settings", systemImage: "slider.horizontal.3") { section = .customize }
            .buttonStyle(.bordered).accessibilityIdentifier("reader-settings")
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
                if model.device.isConnected || model.preparedTransfers.contains(where: { $0.kind == .firmware }) ||
                    model.firmwareAwaitingInstallation != nil || model.firmwareLeftForInstallation != nil {
                    firmwareCard
                } else {
                    DisclosureGroup {
                        firmwareCard.padding(.top, 10).tint(PocketPalette.accent)
                    } label: {
                        Text("Firmware Updates")
                    }
                    // iOS draws the title as a tinted button; these are rows, not
                    // links. The content keeps the accent for its own actions.
                    .tint(.primary)
                    .font(.callout)
                }

            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 20) {
                if !model.isDemoMode {
                    ReaderBluetoothPairingCard(sync: sync, link: readerLink)
                    Button("Continue Reading Settings…", systemImage: "gearshape", action: showSettings)
                        .buttonStyle(.borderless).font(.callout)
                        .accessibilityIdentifier("device-continue-reading-settings")
                    TroubleshootingInspector(model: model, nearby: nearby)
                }
                DisclosureGroup(isExpanded: $deviceDetailsExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let status = model.readerStatus {
                            LabeledContent("Reader", value: status.device)
                            LabeledContent("Firmware", value: status.version)
                            ReaderMemoryDiagnostic(status: status)
                        }
                        if !model.isDemoMode {
                            ReaderSymbolFontOffer(model: model)
                            PreparedTransferQueue(model: model, kind: .content,
                                                  included: { $0.filename == ReaderSymbolFont.fileName })
                        }
                    }.padding(.top, 12).tint(PocketPalette.accent)
                } label: {
                    Text("Device Details")
                }
                .tint(.primary)
                .font(.callout)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("device-details")
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

    @ViewBuilder private var firmwareCard: some View {
#if DEBUG
        FirmwareUpdateCard(model: model, isUpdating: firmwareDownloadTask != nil,
                           update: { confirmingFirmwareUpdate = true }, cancel: cancelFirmwareUpdate,
                           onConnect: { showingConnection = true }, sendLocalBuild: {
                               importAction = .localFirmware
                               importing = true
                           })
#else
        FirmwareUpdateCard(model: model, isUpdating: firmwareDownloadTask != nil,
                           update: { confirmingFirmwareUpdate = true }, cancel: cancelFirmwareUpdate,
                           onConnect: { showingConnection = true })
#endif
    }

    /// The reader's observed files lead; app-readable content starts in Library.
    private func filesContents() -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("On your reader").font(.headline)
                    Spacer(minLength: 16)
                    addFromLibrary
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("On your reader").font(.headline)
                    addFromLibrary
                }
            }
            ReaderInventoryView(model: model, library: library, open: open,
                                connect: { showingConnection = true }, manage: { section = .device })
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    readerOnlyExpanded.toggle()
                } label: {
                    Label("Reader-Only Files", systemImage: readerOnlyExpanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain).font(.callout)
                .accessibilityIdentifier("reader-only-files")
                .accessibilityValue(readerOnlyExpanded ? "Expanded" : "Collapsed")
                if readerOnlyExpanded {
                    Text("XTC · PDL").font(.caption).foregroundStyle(.secondary)
                    Button("Add XTC or PDL…", systemImage: "doc.badge.plus") {
                        importAction = .wirelessUpload
                        importing = true
                    }
                    .disabled(!model.canPrepareFiles)
                    .accessibilityIdentifier("reader-only-files-add")
#if os(macOS)
                    Button("Copy XTC or PDL to SD Card…", systemImage: "sdcard") {
                        importAction = .sdSource
                        importing = true
                    }.disabled(!model.canPrepareFiles)
#endif
                }
            }
            PreparedTransferQueue(model: model, kind: .content,
                                  included: { $0.filename != ReaderSymbolFont.fileName })
            if showsStatus { StatusCallout(message: model.message, tone: model.messageTone) }
        }
    }

    private var addFromLibrary: some View {
        Button("Add from Library", systemImage: "books.vertical") { section = .library; shelf = .books }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("inventory-choose-library")
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

    /// Names the reader and the version, so the confirmation says what changes.
    private var firmwareConfirmationTitle: String {
        let reader = model.readerStatus?.device ?? "the reader"
        guard let version = model.latestFirmwareRelease?.version else { return "Update \(reader)?" }
        return "Update \(reader) to \(version)?"
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
        guard ["xtc", "pdl"].contains(url.pathExtension.lowercased()) else {
            model.post("Add EPUB, TXT or Markdown in the Library, then use Send to Reader.", tone: .pending)
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
        case .connecting: PocketPalette.accent
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
struct ReaderChip: View {
    @ObservedObject var model: PocketModel

    var body: some View {
        HStack(spacing: 8) {
            if let status = model.readerStatus, !model.isDemoMode {
                Circle().fill(PocketPalette.signal).frame(width: 8, height: 8)
                Text(status.device).font(.callout.weight(.semibold))
                // Words with the dot: the state is not told by color alone.
                Text(model.hasDirectSession ? "Connected · Direct" : "Connected · Same Wi-Fi")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Preview size", selection: $model.preferredHardware) {
                    ForEach(PocketHardware.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
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
                Button("Connect a Reader", systemImage: "antenna.radiowaves.left.and.right", action: openReader)
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
                .frame(width: 24, height: 29)
            RoundedRectangle(cornerRadius: 3)
                .fill(PocketPalette.paper)
                .frame(width: 16, height: 20)
            Capsule()
                .fill(PocketPalette.accent)
                .frame(width: 8, height: 2)
                .offset(y: 8)
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
                    HStack(spacing: 12) {
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
                        HStack(spacing: 16) { projectLinks }
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
        Link("Privacy Policy", destination: PocketLinks.privacy)
        Link("Open-Source Notices", destination: PocketLinks.notices)
        NavigationLink("Preview Font Notices") { PreviewFontNotices() }
        NavigationLink("Reader Engine and Font Notices") { ReaderEngineNotices() }
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
        .navigationTitle("Preview Font Notices")
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
        .navigationTitle("Reader Engine Notices")
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
        .background(PocketPalette.card, in: RoundedRectangle(cornerRadius: PocketDesign.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: PocketDesign.cardRadius).stroke(PocketPalette.line) }
    }
}

/// The single place the app reports what just happened. The tone travels
/// with the message from the model, so success, a next step on the reader
/// (such as installing firmware that was sent), an interrupted operation and
/// failures are visually distinct without guessing from wording.
private struct StatusCallout: View {
    let message: String
    let tone: StatusTone

    private var symbol: String { tone.symbol }
    private var color: Color { tone.color }

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
        .padding(tone == .neutral ? 0 : PocketDesign.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: PocketDesign.cardRadius)
                .fill(tone == .neutral ? Color.clear : color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PocketDesign.cardRadius)
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

struct ConnectionInspector: View {
    @Environment(\.readerFleet) private var fleet
    @ObservedObject var model: PocketModel
    @ObservedObject var nearby: NearbySyncController
    let onConnect: () -> Void
    /// Off inside a book or editor task: demo would abandon the work in progress.
    var offersDemo = true
    /// Only explicit Connect sheets start work on presentation.
    var connectsOnOpen = false
    private var readerLink: ReaderBluetoothLink { model.bluetoothLink }
    @State private var startedOnOpen = false
    @State private var confirmingDirectConnection = false
    @State private var otherMethods = false

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
                Button(model.isSearchingForReader ? "Cancel Search" : "Cancel Connection", systemImage: "xmark.circle") {
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
                    Button("Retry Automatic Join") { model.useNearbyLease(lease) }
                        .buttonStyle(.borderedProminent).disabled(model.isWorking)
                    // Only the network name and passphrase are code-like.
                    Text(lease.ssid).font(.caption.monospaced())
                    Text(lease.passphrase).font(.caption.monospaced()).textSelection(.enabled)
                    Button("Verify Connection") {
                        Task { await model.verifyNearbyLease(lease) }
                    }.disabled(model.isWorking)
                }
                .font(.caption)
                .padding(8)
                .background(PocketPalette.workspace, in: RoundedRectangle(cornerRadius: PocketDesign.controlRadius))
            }
        }
        .onAppear {
            guard connectsOnOpen, !startedOnOpen else { return }
            startedOnOpen = true
            guard readerLink.rememberedReader != nil, model.readerStatus == nil,
                  !model.isDemoMode, !model.isWorking, !model.canCancelConnection,
                  !model.isCancellingConnection, !model.hasDirectSession else { return }
            onConnect()
        }
        .alert("Connect to the reader’s temporary Wi-Fi?", isPresented: $confirmingDirectConnection) {
            Button("Cancel", role: .cancel) {}
            Button("Connect Directly") {
                model.beginDirectConnection()
                guard model.directConnectionRequested else { return }
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
            Button("Exit Demo") { model.exitDemoMode() }
                .buttonStyle(.borderedProminent).tint(PocketPalette.accent).frame(maxWidth: .infinity, alignment: .leading)
                .disabled(model.isWorking)
        } else if model.hasDirectSession, model.readerStatus == nil {
            Button("Reconnect Directly") { confirmingDirectConnection = true }
                .buttonStyle(.borderedProminent).tint(PocketPalette.accent).frame(maxWidth: .infinity, alignment: .leading)
                .disabled(model.isWorking)
            Button("End Session") { nearby.disconnect(); model.endConnection() }
                .buttonStyle(.borderless).font(.callout)
                .disabled(model.isWorking)
        } else if model.readerStatus == nil {
            VStack(alignment: .leading, spacing: 8) {
                Button(readerLink.rememberedReader == nil ? "Find on Same Wi-Fi" : "Connect Reader", systemImage: "wifi", action: onConnect)
                    .buttonStyle(.borderedProminent).tint(PocketPalette.accent)
                    .disabled(model.isWorking)
                Text(readerLink.rememberedReader == nil
                     ? "On the reader: Pocket Daily → Sync → Same Wi-Fi."
                     : "Keep your reader nearby. Compatible firmware wakes over Bluetooth and joins your saved Wi-Fi.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                otherMethods.toggle()
            } label: {
                Label("Other Connection Methods", systemImage: otherMethods ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.borderless).font(.callout)
            .accessibilityIdentifier("connection-other-methods")
            .accessibilityValue(otherMethods ? "Expanded" : "Collapsed")
            if otherMethods {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Connect Directly", systemImage: "antenna.radiowaves.left.and.right") { confirmingDirectConnection = true }
                        .buttonStyle(.bordered).disabled(model.isWorking)
                    Text("On the reader: Pocket Daily → Sync → Direct connection.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if offersDemo, (fleet?.readers.count ?? 1) == 1 {
                Button("Try Demo") { nearby.disconnect(); model.enterDemoMode() }
                    .buttonStyle(.borderless).font(.caption)
                    .accessibilityIdentifier("try-demo").disabled(model.isWorking)
            }

        }
    }

    /// Session actions for a connected reader, out of the way until needed.
    private var sessionMenu: some View {
        Menu {
            if model.hasDirectSession {
                Button("Reconnect Directly", systemImage: "arrow.clockwise") { confirmingDirectConnection = true }
            } else {
                Button("Reconnect", systemImage: "arrow.clockwise", action: onConnect)

            }
            Divider()
            Button("End Session", systemImage: "xmark.circle", role: .destructive) {
                nearby.disconnect()
                model.endConnection()
            }
        } label: {
            PocketActionGlyph(name: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.isWorking)
        .accessibilityLabel("Reader Actions")
        .accessibilityIdentifier("reader-actions")
    }

    private var detail: String {
        if model.isDemoMode { return "Demo · nothing is sent" }
        if model.isCancellingConnection { return "Stopping connection…" }
        if model.isSearchingForReader { return "Searching on this Wi-Fi…" }
        if model.readerStatus != nil { return model.hasDirectSession ? "Connected · Direct" : "Connected · Same Wi-Fi" }
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
    var onConnect: (() -> Void)? = nil
#if DEBUG
    /// Development builds only: choose a firmware image built on this machine.
    var sendLocalBuild: (() -> Void)? = nil
#endif
    @State private var confirmingLocalRemoval = false
    @State private var confirmingPreparedUpdate = false
    @State private var preparationTask: Task<Void, Never>?

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
                if isUpdating || sending || preparationTask != nil {
                    if sending {
                        ProgressView(value: model.uploadProgress).progressViewStyle(.pocketBar)
                        Text(model.uploadProgress >= 1 ? "Saving on reader…" : "Sending · \(Int(model.uploadProgress * 100))%")
                            .font(.caption)
                    } else {
                        ProgressView(model.readerUpdateState == .idle ? "Preparing update…" : "Downloading update…")
                            .font(.caption)
                    }
                    Button("Cancel") { preparationTask?.cancel(); cancel() }.accessibilityIdentifier("cancel-firmware-update")
                } else if pending {
                    Text("Update ready to send or resume").font(.callout)
                    HStack {
                        if model.readerStatus == nil, let onConnect {
                            Button("Connect to Send Update…", action: onConnect)
                        } else {
                            Button("Send Update") { confirmingPreparedUpdate = true }
                                .disabled(model.readerStatus == nil || model.isWorking)
                        }
                        Button("Cancel", action: cancel).disabled(model.isWorking)
                    }
                    if model.messageTone == .failure {
                        Text("Reconnect to the same reader to finish cleanup, or forget this update on this device.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Forget Update…") { confirmingLocalRemoval = true }
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
                    Button("Cancel Check") { model.cancelFirmwareCheck() }
                        .accessibilityIdentifier("cancel-firmware-check")
                } else if model.firmwareCheckError != nil, model.readerStatus == nil {
                    Text("Firmware updates appear when you connect a reader.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let error = model.firmwareCheckError {
                    PocketStatusLabel(error, tone: .failure).font(.caption)
                    Button("Check Again") { Task { await model.checkFirmwareRelease() } }
                        .disabled(model.hasDirectSession)
                    if model.hasDirectSession {
                        Text("Checking needs an internet connection; the direct link has none.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if model.firmwareUpdateAvailable {
                    // The label says the result; a disabled button says why.
                    Button(model.latestFirmwareRelease.map { "Update to \($0.version)" } ?? "Update Reader", action: update)
                        .buttonStyle(.borderedProminent).disabled(!model.canUpdateReader)
                        .accessibilityIdentifier("update-reader")
                    Text(model.hasDirectSession ? "Use an internet connection to download the update."
                         : model.canUpdateReader ? "Confirm installation on the reader after sending."
                         : "Available after the current reader task.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.latestFirmwareRelease != nil, let status = model.readerStatus {
                    Text(FirmwareGuidance.parse(status.version) == nil ? "Reader version could not be compared." : "No newer update available")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(model.readerStatus == nil ? "Connect a reader to check its version." : "Connect to the internet to check for updates.")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.latestFirmwareRelease == nil {
                        Button("Check for Updates") { Task { await model.checkFirmwareRelease() } }
                            .disabled(model.hasDirectSession)
                    }
                }
                if !pending, !isUpdating, !sending, preparationTask == nil, !model.hasDirectSession {
                    Button("Download Update for Later") {
                        preparationTask = Task { @MainActor in
                            await model.prepareOfficialFirmware()
                            preparationTask = nil
                        }
                    }
                    .disabled(!model.canPrepareFiles)
                    .accessibilityIdentifier("prepare-official-firmware")
                    Text("Download online. Send over either connection.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
#if DEBUG
                if let sendLocalBuild, model.readerStatus != nil, !isUpdating, !sending, !pending {
                    Divider()
                    Button("Send a Local Build…", action: sendLocalBuild)
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
        .alert("Send prepared firmware?", isPresented: $confirmingPreparedUpdate) {
            Button("Send Update") { model.sendPreparedFiles(kind: .firmware) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sends the prepared Pocket Daily firmware for a compatible X3/X4 reader. Factory firmware is not supported. Keep a recovery method available; custom firmware may affect device support. Installation starts only after you confirm on the reader.")
        }
        .alert("Forget this update?", isPresented: $confirmingLocalRemoval) {
            Button("Forget Update", role: .destructive) { model.removePreparedFiles(kind: .firmware, localOnly: true) }
            Button("Keep Update", role: .cancel) {}
        } message: {
            Text("Removes the local copy only. Temporary data on the reader may remain. Already saved firmware is unchanged.")
        }
    }
}

/// Categories have independent send/remove actions even when both are pending.
private struct PreparedTransferQueue: View {
    @ObservedObject var model: PocketModel
    let kind: TransferKind
    var included: (PreparedTransfer) -> Bool = { _ in true }
    @State private var confirmingRemoval = false
    @State private var confirmingStop = false
    @State private var confirmingLocalRemoval = false
    private var items: [PreparedTransfer] { model.preparedTransfers.filter { $0.kind == kind && $0.bookJobID == nil && included($0) } }
    private var itemIDs: Set<UUID> { Set(items.map(\.id)) }
    /// Completed copies leave the preparation queue. Controls stay bound to the
    /// original operation until it drains, including after reopening this view.
    private var activeBatch: [PreparedTransfer] {
        let batch = model.activePreparedFileBatch
        guard !batch.isEmpty, batch.allSatisfy({ $0.kind == kind && $0.bookJobID == nil && included($0) }) else { return [] }
        return batch
    }
    private var controlIDs: Set<UUID> { Set(activeBatch.map(\.id)) }
    private var isActive: Bool { model.isSendingPreparedFiles(ids: controlIDs) }
    private var displayedItems: [PreparedTransfer] { isActive ? activeBatch : items }
    private var sendTitle: String {
        let verb = items.contains { $0.stagingID != nil } ? "Resume" : "Send"
        return "\(verb) \(items.count) \(items.count == 1 ? "File" : "Files")"
    }

    var body: some View {
        if !items.isEmpty || isActive, !model.isDemoMode {
            VStack(alignment: .leading, spacing: 8) {
                Text(isActive ? "Sending files · \(activeBatch.count)" : "Ready to send · \(items.count)")
                    .font(.subheadline.weight(.semibold))
                ForEach(displayedItems) { item in
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
                        Button("Pause") { model.pausePreparedFiles(ids: controlIDs) }
                        Button("Stop and Remove…", role: .destructive) { confirmingStop = true }
                    }
                } else {
                    HStack {
                        // Without a reader the device card holds the one primary
                        // action (Connect); this waits as a secondary button.
                        if model.readerStatus == nil {
                            Button(sendTitle) {}.buttonStyle(.bordered).disabled(true)
                        } else {
                            Button(sendTitle) { model.sendPreparedFiles(ids: itemIDs, kind: kind) }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.isWorking)
                        }
                        Button("Remove These Files…") { confirmingRemoval = true }
                            .disabled(model.isWorking)
                    }
                    if model.readerStatus == nil {
                        Text("Connect the reader to send.").font(.caption).foregroundStyle(.secondary)
                    } else if model.isWorking {
                        Text("Sends after the current reader task.").font(.caption).foregroundStyle(.secondary)
                    }
                    if items.contains(where: { $0.stagingID != nil }) {
                        Text("Paused or interrupted copies are kept for retry. Remove cleans their temporary files on the connected reader.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Remove Only Local Copies…") { confirmingLocalRemoval = true }
                            .font(.caption).disabled(model.isWorking)
                    }
                }
            }
            .alert("Remove prepared \(kind.rawValue)?", isPresented: $confirmingRemoval) {
                Button("Remove Prepared Copies", role: .destructive) { model.removePreparedFiles(ids: itemIDs, kind: kind) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes these prepared copies and their tracked temporary files on the reader. Original sources and completed reader files stay.")
            }
            .alert("Stop and remove this transfer?", isPresented: $confirmingStop) {
                Button("Stop and Remove", role: .destructive) { model.stopAndRemovePreparedFiles(ids: controlIDs) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Stops these files and cleans its temporary files. If the connection is lost, the queue stays so you can retry cleanup. Already saved files stay.")
            }
            .alert("Remove only local copies?", isPresented: $confirmingLocalRemoval) {
                Button("Remove Local Copies", role: .destructive) { model.removePreparedFiles(ids: itemIDs, kind: kind, localOnly: true) }
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
            VStack(alignment: .leading, spacing: 12) {
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
                Button(expanded ? "Hide Raw Report" : "Show Raw Report") { expanded.toggle() }
                    .buttonStyle(.bordered)
                ShareLink("Export Report", item: diagnostic.report)
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
                Button(expanded ? "Hide Log" : "Show Log") { expanded.toggle() }.buttonStyle(.bordered)
                ShareLink("Export Log", item: nearby.traceReport)
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
            Label(title, systemImage: symbol)
                .labelStyle(PocketSectionLabel())
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PocketDesign.cardInset)
        .background(PocketPalette.card, in: RoundedRectangle(cornerRadius: PocketDesign.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: PocketDesign.cardRadius).stroke(PocketPalette.line, lineWidth: 1) }
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
