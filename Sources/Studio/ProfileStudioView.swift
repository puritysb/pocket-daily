import SwiftUI
import Combine

/// Draft of the Home & Sleep profile and reading settings. Lives with the app
/// window so switching tabs keeps unsent edits, and is saved to disk
/// (`ProfileEditStore`) so quitting does not lose them.
@MainActor
final class ProfileEditorState: ObservableObject {
    @Published var draft: PocketProfile = .defaults
    /// The reader profile the draft started from (defaults when none).
    @Published private(set) var base: PocketProfile = .defaults
    private var baseGeneration: UInt32?
    /// What the last merge with the reader's settings did, until dismissed.
    @Published private(set) var mergeReport: ProfileMerge.Report?

    @Published var localSaveError: String?
    @Published private(set) var targetDeviceID: String?
    @Published private(set) var connectedDeviceID: String?
    private var reviewDeviceID: String?
    @Published private(set) var targetMismatch = false

    var isDirty: Bool { draft != base }

    /// Reader identity is checked before either baseline can change. Generic
    /// offline edits may merge for review, but are bound only by explicit Apply.
    func observeTarget(_ deviceID: String?) {
        guard let deviceID else { connectedDeviceID = nil; return }
        let previous = targetDeviceID ?? reviewDeviceID
        if let previous, previous != deviceID, isDirty || readingDirty {
            targetMismatch = true
            connectedDeviceID = deviceID
            return
        }
        if previous != deviceID { baseGeneration = nil; mergeReport = nil }
        connectedDeviceID = deviceID
        reviewDeviceID = deviceID
        targetMismatch = false
        if !isDirty && !readingDirty { targetDeviceID = deviceID }
    }

    func bindForApply(to deviceID: String) -> Bool {
        guard !targetMismatch, connectedDeviceID == deviceID else { return false }
        targetDeviceID = deviceID
        return true
    }

    /// Explicitly copy edits to a different reader, retaining the original
    /// snapshot for recovery before changing identity.
    func useDraft(with deviceID: String, store: ProfileEditStore = .live) async throws {
        if let snapshot { try await Task.detached { try store.archive(snapshot) }.value }
        guard connectedDeviceID == deviceID else { return }
        targetDeviceID = deviceID
        connectedDeviceID = deviceID
        reviewDeviceID = deviceID
        targetMismatch = false
        baseGeneration = nil
        mergeReport = nil
    }

    /// Adopt a newly loaded or saved reader profile. Unsent edits are merged
    /// field by field (`ProfileMerge`) instead of either side winning wholesale.
    func sync(with reader: ReaderProfileState?) {
        // Daemon-fed items are dropped on load, so they never count as edits.
        guard let reader else { return }
        observeTarget(reader.deviceID)
        guard !targetMismatch else { return }
        let incoming = reader.profile.withoutRetiredItems
        guard reader.generation != baseGeneration || incoming != base else { return }
        if isDirty && draft != incoming {
            let merged = ProfileMerge.merge(base: base, mine: draft, reader: incoming)
            draft = merged.profile
            note(merged.report)
        } else {
            draft = incoming
        }
        base = incoming
        baseGeneration = reader.generation
    }

    private func note(_ report: ProfileMerge.Report) {
        guard !report.isEmpty else { return }
        var combined = mergeReport ?? ProfileMerge.Report()
        combined.add(report)
        mergeReport = combined
    }

    func dismissMergeReport() { mergeReport = nil }

    /// Takes the reader's value for the fields both sides changed.
    func useReaderForBothChanged() {
        guard let fields = mergeReport?.bothChanged, !fields.isEmpty else { return }
        ProfileMerge.take(fields, from: base, into: &draft)
        ProfileMerge.take(fields, from: readingBase, into: &reading)
        mergeReport?.bothChanged = []
        if mergeReport?.isEmpty == true { mergeReport = nil }
    }

    /// What Apply would change on the reader, by field.
    var pendingFields: [ProfileMerge.Field] {
        ProfileMerge.pending(profile: draft, reader: base) + ProfileMerge.pending(preferences: reading, reader: readingBase)
    }

    /// Unsent edits to keep on disk; nil when there are none.
    var snapshot: ProfileEditSnapshot? {
        guard isDirty || readingDirty else { return nil }
        return ProfileEditSnapshot(draft: draft, base: base, baseGeneration: baseGeneration,
                                   reading: reading, readingBase: readingBase, savedAt: Date(), targetDeviceID: targetDeviceID, reviewDeviceID: reviewDeviceID)
    }

    /// Restores saved edits; the next reader load merges them with what the reader holds.
    func restore(_ snapshot: ProfileEditSnapshot?) {
        guard let snapshot else { return }
        mergeReport = nil
        connectedDeviceID = nil
        targetMismatch = false
        targetDeviceID = snapshot.targetDeviceID
        reviewDeviceID = snapshot.reviewDeviceID
        draft = snapshot.draft
        base = snapshot.base
        baseGeneration = snapshot.baseGeneration
        reading = snapshot.reading
        readingBase = snapshot.readingBase
    }

    /// Demo starts from a clean editor; its edits are never saved.
    func reset() {
        targetDeviceID = nil
        connectedDeviceID = nil
        reviewDeviceID = nil
        targetMismatch = false
        draft = .defaults
        base = .defaults
        baseGeneration = nil
        reading = Self.defaultReading
        readingBase = Self.defaultReading
        mergeReport = nil
    }

    private static let defaultReading = ReaderPreferences(orientation: .portrait, lineSpacing: .normal, screenMargin: 5, sideButtons: .previousNext,
                                                          frontButtonsFollowOrientation: false, sleepWakeIndicator: true)

    @Published var reading = ReaderPreferences(orientation: .portrait, lineSpacing: .normal, screenMargin: 5, sideButtons: .previousNext, frontButtonsFollowOrientation: false, sleepWakeIndicator: true)
    @Published private(set) var readingBase = ReaderPreferences(orientation: .portrait, lineSpacing: .normal, screenMargin: 5, sideButtons: .previousNext, frontButtonsFollowOrientation: false, sleepWakeIndicator: true)
    var readingDirty: Bool { reading != readingBase }

    /// Adopt untouched fields, retaining edits made before connecting
    /// (`ProfileMerge`); fields both sides changed are reported.
    func syncReading(_ loaded: ReaderPreferences?) {
        guard !targetMismatch, let loaded, loaded != readingBase else { return }
        let merged = ProfileMerge.merge(base: readingBase, mine: reading, reader: loaded)
        if readingDirty { note(merged.report) }
        readingBase = loaded
        reading = merged.preferences
    }

    func acceptReading(_ saved: ReaderPreferences?) {
        guard let saved else { return }
        readingBase = saved
        reading = saved
    }

    enum Scope: String, CaseIterable {
        case home = "Home", sleep = "Sleep", reading = "Reading"
        var fields: [ProfileMerge.Field] {
            switch self {
            case .home: [.homeItems, .dailyWord, .weather, .nextEvent, .startup]
            case .sleep: [.sleepMode, .sleepSections, .sleepCover, .sleepTimeout, .wakeCue]
            case .reading: [.textSize, .orientation, .lineSpacing, .screenMargin, .sideButtons, .frontButtons]
            }
        }
    }

    func report(in scope: Scope) -> ProfileMerge.Report? {
        guard var report = mergeReport else { return nil }
        report.fromReader = report.fromReader.filter { scope.fields.contains($0) }
        report.bothChanged = report.bothChanged.filter { scope.fields.contains($0) }
        return report.isEmpty ? nil : report
    }

    func dismissReport(in scope: Scope) {
        mergeReport?.fromReader.removeAll { scope.fields.contains($0) }
        mergeReport?.bothChanged.removeAll { scope.fields.contains($0) }
    }

    func useReader(in scope: Scope) {
        let fields = report(in: scope)?.bothChanged ?? []
        ProfileMerge.take(fields, from: base, into: &draft)
        ProfileMerge.take(fields, from: readingBase, into: &reading)
        dismissReport(in: scope)
    }

    func pending(in scope: Scope) -> [ProfileMerge.Field] {
        pendingFields.filter { scope.fields.contains($0) }
    }

    func profile(in scope: Scope) -> PocketProfile {
        var result = base
        ProfileMerge.take(scope.fields, from: draft, into: &result)
        return result
    }

    func preferences(in scope: Scope) -> ReaderPreferences {
        var result = readingBase
        ProfileMerge.take(scope.fields, from: reading, into: &result)
        return result
    }

    func revert(_ scope: Scope) {
        ProfileMerge.take(scope.fields, from: base, into: &draft)
        ProfileMerge.take(scope.fields, from: readingBase, into: &reading)
        mergeReport?.bothChanged.removeAll { scope.fields.contains($0) }
    }

    func revert() { draft = base; reading = readingBase }
}

/// Reader customization separates screen design from reading preferences.
/// Home, Sleep and Reading each apply or discard only their own settings.
/// Card content autosaves locally and has an explicit, separate Apply cards action.
struct ProfileStudioView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var model: PocketModel
    @ObservedObject var editor: ProfileEditorState
    @ObservedObject private var glanceSettings: GlanceSettings
    var contentPadding: CGFloat = 0
    let onConnect: () -> Void
    private let previewSelection: Binding<PreviewSurface>?
    let connectionContent: (() -> AnyView)?
    let cancelConnection: () -> Void
    let sourceTaskRequest: SourceTaskRequest?
    let onSourceTaskOpened: () -> Void
    let screenTaskRequest: ScreenTaskRequest?
    let onScreenTaskOpened: () -> Void
    @State private var activeContentEditor: StudioContentTask?
    @State private var preview: PreviewSurface = .home
    /// Compact layouts keep the preview small beside the controls; a tap
    /// shows it at full size without leaving the edit.
    @State private var enlargedPreview = false
    @State private var schematic: CGImage?
    @StateObject private var layout = LayoutPreviewModel()
    @State private var cards: ContentEditorModel?
    @State private var observedCards = ContentDraft()
    @State private var cardsError: String?
    @State private var confirmingDiscard = false
    @State private var confirmingTarget = false
    @State private var recoveringDraft = false
    @State private var targetError: String?
    @State private var recoveredDrafts: [ProfileEditSnapshot] = []
    private var showsReadingSample: Bool { preview == .reading }
    @State private var drag: ReorderDrag?
    /// Where Weather returns when switched back on.
    @State private var weatherWhenOn: PocketProfile.WeatherPanel = .bottom

    /// What the canvas draws. A card page belongs to Home: the selected card
    /// as the reader shows it when opened.
    enum PreviewSurface: String, CaseIterable { case home = "Home", reading = "Reading", card = "Card", sleep = "Sleep" }
    /// The screens the editor is organized around.
    typealias Screen = ProfileEditorState.Scope
    enum SourceEditor: Equatable, Sendable { case cards, weatherCalendar }
    struct ScreenTaskRequest: Equatable, Sendable {
        let id: UUID
        let screen: ReaderScreen
    }
    struct SourceTaskRequest: Equatable, Sendable {
        let id: UUID
        let destination: SourceEditor
    }
    @State private var appliedScope: Screen?

    init(model: PocketModel, editor: ProfileEditorState, contentPadding: CGFloat = 0,
         initialPreview: PreviewSurface = .home, previewSelection: Binding<PreviewSurface>? = nil,
         sourceTaskRequest: SourceTaskRequest? = nil, onSourceTaskOpened: @escaping () -> Void = {},
         screenTaskRequest: ScreenTaskRequest? = nil, onScreenTaskOpened: @escaping () -> Void = {},
         connectionContent: (() -> AnyView)? = nil, cancelConnection: @escaping () -> Void = {},
         onConnect: @escaping () -> Void = {}) {
        self.model = model
        self.editor = editor
        self.glanceSettings = model.glanceSettings
        self.contentPadding = contentPadding
        self.onConnect = onConnect
        self.previewSelection = previewSelection
        self.connectionContent = connectionContent
        self.cancelConnection = cancelConnection
        self.sourceTaskRequest = sourceTaskRequest
        self.onSourceTaskOpened = onSourceTaskOpened
        self.screenTaskRequest = screenTaskRequest
        self.onScreenTaskOpened = onScreenTaskOpened
        let surface = initialPreview == .card ? PreviewSurface.home : initialPreview
        _preview = State(initialValue: surface)
        _activeContentEditor = State(initialValue: sourceTaskRequest.map {
            $0.destination == .cards ? .cards : .glance
        } ?? (initialPreview == .card ? .cards : nil))
    }

    @ViewBuilder private var studioLayout: some View {
        if dynamicTypeSize.isAccessibilitySize {
            // Large text needs the whole height for controls. A dedicated
            // preview action keeps the full-size canvas available on demand.
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    settingPicker
                    Button("Show Preview", systemImage: "rectangle.portrait") { enlargedPreview = true }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("profile-preview-open")
                    controls
                    applyBar
                }
                .padding(contentPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("profile-controls")
        } else {
            standardStudioLayout
        }
    }

    private var standardStudioLayout: some View {
        GeometryReader { geometry in
            let sideBySide = geometry.size.width >= PocketDesign.splitLayoutWidth
            let condensed = !sideBySide && geometry.size.height < PocketDesign.condensedEditorHeight
            VStack(spacing: 12) {
                settingPicker
                if sideBySide { applyBar }
                if sideBySide {
                    HStack(alignment: .top, spacing: 24) {
                        canvas(height: min(470, max(140, geometry.size.height - 190)))
                            .frame(width: min(340, geometry.size.width * 0.43))
                        editorScroll
                    }
                } else {
                    canvas(height: condensed ? 60 : min(180, max(90, geometry.size.height * 0.24)), condensed: condensed,
                           enlargeable: true)
                    Divider()
                    editorScroll
                    // Even when short, Apply keeps its reason beside it.
                    if condensed { HStack(spacing: 12) { statusLabel.lineLimit(1); Spacer(minLength: 8); applyControls } } else { applyBar }
                }
            }
            .padding(contentPadding)
        }
    }

    var body: some View {
        studioLayout
        .onChange(of: preview) { _, value in previewSelection?.wrappedValue = value }
        .onChange(of: previewSelection?.wrappedValue) { _, value in
            if let value { preview = value == .card ? .home : value }
        }
        .sheet(isPresented: $enlargedPreview) { enlargedCanvas }
        .sheet(item: $activeContentEditor) { task in
            StudioContentSheet(model: model, task: task, cards: cards, loadError: cardsError,
                               reloadCards: { await openCards() }, connectionContent: connectionContent,
                               cancelConnection: cancelConnection)
        }
        .onChange(of: screenTaskRequest?.id) { _, _ in
            if let screenTaskRequest {
                preview = screenTaskRequest.screen == .home ? .home : .sleep
                onScreenTaskOpened()
            }
        }
        .onChange(of: sourceTaskRequest?.id) { _, _ in
            if let sourceTaskRequest {
                openSource(sourceTaskRequest.destination)
                onSourceTaskOpened()
            }
        }
        .onAppear {
            if let screenTaskRequest {
                preview = screenTaskRequest.screen == .home ? .home : .sleep
                onScreenTaskOpened()
            }
            if let sourceTaskRequest {
                openSource(sourceTaskRequest.destination)
                onSourceTaskOpened()
            }
            editor.observeTarget(model.readerStatus?.deviceID)
            editor.sync(with: model.readerProfile)
            if !model.preferencesDirty { editor.syncReading(model.preferences) }
            if editor.draft.home.weather != .off { weatherWhenOn = editor.draft.home.weather }
        }
        .onReceive(cards?.$draft.eraseToAnyPublisher() ?? Just(ContentDraft()).eraseToAnyPublisher()) {
            if observedCards != $0 { observedCards = $0 }
        }
        .onChange(of: model.readerStatus?.deviceID) { _, identity in editor.observeTarget(identity) }
        .onChange(of: model.preferences) { _, preferences in
            if !model.preferencesDirty { editor.syncReading(preferences) }
        }
        .onChange(of: model.preferencesDirty) { wasDirty, dirty in
            if wasDirty && !dirty { editor.syncReading(model.preferences) }
        }
        .onChange(of: model.preferencesBaseline) { _, saved in editor.syncReading(saved) }
        .alert("Discard \(screen.rawValue) edits?", isPresented: $confirmingDiscard) {
            Button("Discard Edits", role: .destructive) {
                editor.revert(screen)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restores \(screen.rawValue) to its last loaded settings. Edits in other sections stay.")
        }
        .alert("Use this draft with the connected reader?", isPresented: $confirmingTarget) {
            Button("Use a Copy") {
                guard let identity = model.readerStatus?.deviceID else { return }
                recoveringDraft = true
                Task {
                    defer { recoveringDraft = false }
                    do {
                    try await editor.useDraft(with: identity, store: model.profileEditStore)
                    recoveredDrafts = await loadRecoveredDrafts()
                    editor.sync(with: model.readerProfile)
                    editor.syncReading(model.preferences)
                    targetError = nil
                } catch { targetError = "Could not preserve the original draft. Try again. " + error.localizedDescription } }
            }
            Button("Keep Original", role: .cancel) {}
        } message: {
            Text("The original stays in local draft recovery. Review the merged changes before Apply to Reader.")
        }
        .onChange(of: model.readerProfile) { _, reader in editor.sync(with: reader) }
        .onChange(of: editor.draft.home.weather) { _, weather in if weather != .off { weatherWhenOn = weather } }
        .task(id: model.isDemoMode) {
            recoveredDrafts = model.isDemoMode ? [] : await loadRecoveredDrafts()
            await openCards()
        }
        .task(id: previewKey) {
            renderSchematic()
            if let request = layoutRequest { await layout.update(request) }
        }

    }

    /// Editing never scrolls the preview or Apply out of sight.
    private var editorScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                controls
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .id(screen)
        .accessibilityIdentifier("profile-controls")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var screen: Screen { preview == .reading ? .reading : preview == .sleep ? .sleep : .home }
    private var draftCards: ContentDraft { observedCards }
    // MARK: Canvas

    private struct PreviewKey: Equatable {
        let profile: PocketProfile
        let surface: PreviewSurface
        let hardware: PocketHardware
        let cards: ContentDraft
        let wakeIndicator: Bool
        let sleepCover: Bool
    }

    private var previewKey: PreviewKey {
        .init(profile: editor.draft, surface: preview, hardware: model.hardware, cards: draftCards,
              wakeIndicator: editor.reading.sleepWakeIndicator ?? true, sleepCover: editor.reading.pocketDailySleepCover)
    }

    /// The reader's own sleep screen and a card page are not layouts.
    private var layoutRequest: LayoutPreviewRequest? {
        if preview == .reading || preview == .card || (preview == .sleep && editor.draft.sleep.mode == .reader) { return nil }
        guard editor.draft.validationError == nil else { return nil }
        return LayoutPreviewRequest(profile: editor.draft, surface: preview == .home ? .home : .brief,
                                    hardware: model.hardware, cards: draftCards,
                                    wakeIndicator: editor.reading.sleepWakeIndicator ?? true,
                                    sleepCover: editor.reading.pocketDailySleepCover)
    }

    private var showsRender: Bool { layoutRequest != nil && layout.image != nil }
    private var canvasImage: CGImage? {
        if showsReadingSample { return ImageRenderer(content: readingSample).cgImage }
        return showsRender ? layout.image : schematic
    }

    /// A local setting scope, not another app destination. Menus fit long
    /// labels and Dynamic Type without squeezing three segmented titles.
    private var settingPicker: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                scopeMenu
                Spacer(minLength: 8)
                ReaderChip(model: model)
            }
            VStack(alignment: .leading, spacing: 8) {
                scopeMenu
                ReaderChip(model: model)
            }
        }
    }

    private var scopeMenu: some View {
        Menu {
            // A picker, so the current scope carries a checkmark.
            Picker("Reader setting", selection: Binding(get: { screen }, set: { scope in
                preview = scope == .reading ? .reading : scope == .sleep ? .sleep : .home
            })) {
                Text("Home Screen").tag(Screen.home)
                Text("Sleep Screen").tag(Screen.sleep)
                Text("Reading Preferences").tag(Screen.reading)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Text(screen == .reading ? "Reading Preferences" : screen.rawValue + " Screen")
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                PocketSymbol("chevron.down", role: .accessory)
            }
            .frame(minHeight: PocketDesign.actionTarget)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("reader-setting-scope")
        .accessibilityLabel("Reader setting")
        .accessibilityValue(screen == .reading ? "Reading Preferences" : screen.rawValue + " Screen")
    }

    private func canvas(height: CGFloat, condensed: Bool = false, enlargeable: Bool = false) -> some View {
        VStack(spacing: 10) {
            Group {
                if showsReadingSample, let image = canvasImage {
                    Image(decorative: image, scale: 1)
                        .resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .padding(8)
                        .background(PocketPalette.deviceTop, in: RoundedRectangle(cornerRadius: 12))
                } else {
                    PocketDevicePreview(hardware: model.hardware, status: model.readerStatus, renderedScreen: canvasImage)
                }
            }
                .frame(maxWidth: 340)
                .frame(height: height)
                .overlay(alignment: .bottomTrailing) {
                    if enlargeable && !condensed {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(6).background(.regularMaterial, in: Circle())
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if enlargeable { enlargedPreview = true } }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(canvasLabel)
                .accessibilityValue(canvasIsCurrent ? "Current" : "Updating")
                .accessibilityHint(enlargeable ? "Shows the preview at full size" : "")
                .accessibilityAddTraits(enlargeable ? .isButton : [])
                .accessibilityIdentifier("profile-canvas")
            if !condensed {
                Text(showsReadingSample ? "Reading preview · approximate appearance" : "Layout preview · not a live reader screen")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            if !showsReadingSample {
                HStack(spacing: 10) {
                    Label(canvasCaption, systemImage: showsRender ? "text.below.photo" : "square.dashed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(preview == .card ? "The card as the reader draws it when opened." :
                              showsRender ? "Preview uses your card drafts plus an example book, weather and schedule. It is not a live image of your reader." : "")
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(canvasCaption)
                        .accessibilityIdentifier("profile-canvas-caption")

                }
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    private var enlargedCanvas: some View {
        VStack(spacing: 16) {
            HStack {
                Text(showsReadingSample ? "Reading preview" : "\(screen == .sleep ? "Sleep" : "Home") preview")
                    .font(.headline)
                Spacer()
                Button("Done") { enlargedPreview = false }.accessibilityIdentifier("profile-canvas-done")
            }
            Group {
                if showsReadingSample, let image = canvasImage {
                    Image(decorative: image, scale: 1)
                        .resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .padding(10)
                        .background(PocketPalette.deviceTop, in: RoundedRectangle(cornerRadius: 14))
                } else {
                    PocketDevicePreview(hardware: model.hardware, status: model.readerStatus, renderedScreen: canvasImage)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(canvasLabel)
            Text(showsReadingSample ? "Reading preview · approximate appearance" : "Layout preview · not a live reader screen")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(PocketPalette.workspace)
    }

    private var canvasIsCurrent: Bool {
        if showsReadingSample { return true }
        return layoutRequest == nil || layout.renderedRequest == layoutRequest
    }

    private var canvasLabel: String {
        if showsReadingSample { return "Reading example, \(editor.reading.orientation?.title ?? "Portrait"), text size \(editor.reading.fontSize + 1) of 4" }
        return switch preview {
        case .reading: "Reading preview"
        case .card: "Home preview"
        case .home, .sleep:
            showsRender ? "Pocket Daily \(preview.rawValue.lowercased()) with sample content"
                        : "Outline of the Pocket Daily \(preview.rawValue.lowercased()) layout"
        }
    }

    private var canvasCaption: String {
        if showsReadingSample { return "Example article · actual font and pages depend on the book" }
        if showsRender {
            if model.isDemoMode { return "Demo cards · example book, weather & schedule" }
            return draftCards.cards.isEmpty ? "Example book, weather & schedule" : "Your cards · example book, weather & schedule"
        }
        if layoutRequest != nil, layout.error != nil { return "Layout outline · preview unavailable" }
        return "Layout outline"
    }

    // MARK: Apply

    private var scopedProfile: PocketProfile { editor.profile(in: screen) }
    private var defaultProfile: PocketProfile {
        var result = editor.base
        ProfileMerge.take(screen.fields, from: PocketProfile.defaults, into: &result)
        return result
    }
    private var scopedPreferences: ReaderPreferences { editor.preferences(in: screen) }
    private var profileDirty: Bool { model.canEditReaderProfile && scopedProfile != editor.base }
    private var preferencesDirty: Bool { scopedPreferences != editor.readingBase }
    private var anythingDirty: Bool { !editor.pending(in: screen).isEmpty }

    private var status: (text: String, symbol: String, color: Color) {
        if let error = editor.localSaveError { return ("Draft not saved · " + error, StatusTone.failure.symbol, PocketPalette.critical) }
        if editor.targetMismatch { return ("Draft belongs to another reader", "exclamationmark.triangle", PocketPalette.caution) }
        if model.isDemoMode { return ("Demo · nothing is sent", "info.circle", .secondary) }
        if model.readerStatus == nil {
            return (anythingDirty
                        ? "Local draft · not applied"
                        : "Preview without a reader", "info.circle", .secondary)
        }
        if preferencesDirty && model.preferences == nil {
            return ("Reconnect to reader Sync to load settings before applying", "exclamationmark.triangle", PocketPalette.caution)
        }
        if let error = scopedProfile.validationError { return (error, StatusTone.failure.symbol, PocketPalette.critical) }
        if model.profileSend == .sending { return ("Applying on the reader…", "arrow.triangle.2.circlepath", PocketPalette.accent) }
        if case .showing = model.screenShow { return ("Showing it on the reader…", "arrow.triangle.2.circlepath", PocketPalette.accent) }
        switch model.profileSend {
        case .conflict: return ("Changed on the reader · its version was loaded", "exclamationmark.triangle", PocketPalette.caution)
        case let .failed(message) where anythingDirty && appliedScope == screen: return ("Not applied · \(message)", "xmark.octagon", PocketPalette.critical)
        default: break
        }
        if !model.canEditReaderProfile && scopedProfile != editor.base {
            return ("Home & Sleep changes need compatible firmware. Open My Reader → Reader Options → Manage Reader.", "exclamationmark.triangle", PocketPalette.caution)
        }
        if anythingDirty, model.isWorking || recoveringDraft {
            return ("Waiting for the current reader task", "arrow.triangle.2.circlepath", PocketPalette.accent)
        }
        if anythingDirty { return ("\(screen.rawValue) · unapplied changes", "circle.dashed", PocketPalette.accent) }
        if appliedScope == screen, preview == .reading, case .saved = model.profileSend {
            return ("Saved on reader · open a book to see changes", "checkmark.circle.fill", PocketPalette.signal)
        }
        switch appliedScope == screen ? model.screenShow : .idle {
        case let .shown(screen, _):
            return ("Applied · \(screen == .home ? "Home" : "sleep screen") shown on the reader",
                    "checkmark.circle.fill", PocketPalette.signal)
        case .failed:
            return ("Applied · the reader shows it when you leave Sync", "checkmark.circle", PocketPalette.signal)
        default: break
        }
        // Without screen presentation the reader redraws Home and Sleep from a
        // saved profile only when it next paints Pocket Daily (when Sync ends).
        if appliedScope == screen, case .saved = model.profileSend {
            return ("Saved · shows when you leave Sync",
                    "checkmark.circle.fill", PocketPalette.signal)
        }
        return ("Up to date with the reader", "checkmark.circle.fill", PocketPalette.signal)
    }

    /// The screen being edited, for readers that draw it inside Sync. A card
    /// page is drawn by content presentation instead; the reader's own sleep
    /// screen is not a Pocket Daily frame.
    private var screenToShow: ReaderScreen? {
        switch preview {
        case .home: .home
        case .sleep: editor.draft.sleep.mode == .brief ? .brief : nil
        case .card, .reading: nil
        }
    }

    private var canApply: Bool {
        model.readerStatus?.deviceID != nil && !editor.targetMismatch && !model.isDemoMode && !model.isWorking && !recoveringDraft && anythingDirty &&
            (!preferencesDirty || model.preferences != nil) &&
            (scopedProfile == editor.base || model.canEditReaderProfile) && scopedProfile.validationError == nil
    }

    /// One line when it fits; otherwise the status above the buttons.
    private var applyBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                statusLabel.fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 12) {
                    applyControls.fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        statusLabel.lineLimit(1)
                        Spacer(minLength: 8)
                        applyControls
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        statusLabel
                        HStack(spacing: 12) {
                            Spacer()
                            applyControls
                        }
                    }
                }
            }
            Text(screen == .reading ? "Reading preferences on your reader" : screen.rawValue + " layout")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if editor.targetMismatch, !model.isDemoMode {
                Button("Use a Copy with This Reader…") { confirmingTarget = true }
                    .accessibilityIdentifier("profile-use-current-reader")
            }
            if let targetError { Text(targetError).font(.caption).foregroundStyle(PocketPalette.critical) }
            if let report = editor.report(in: screen), !model.isDemoMode {
                MergeNotice(report: report, pending: pendingNames, describe: describe,
                            useReader: { editor.useReader(in: screen) }, dismiss: { editor.dismissReport(in: screen) })
            } else if model.readerStatus != nil, !model.isDemoMode, let pendingNames {
                Text("Apply changes on the reader: " + pendingNames)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("profile-pending")
            }
        }
        .padding(.horizontal, PocketDesign.cardInset)
        .padding(.vertical, 10)
        .background(PocketPalette.panel, in: RoundedRectangle(cornerRadius: PocketDesign.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: PocketDesign.cardRadius).stroke(PocketPalette.line) }
    }

    /// What Apply would change, named as on screen; a setting hidden by another
    /// says why it is not visible. Nil when nothing would change.
    private var pendingNames: String? {
        let fields = editor.pending(in: screen)
        guard !fields.isEmpty else { return nil }
        return fields.map(describe).joined(separator: ", ")
    }

    private func describe(_ field: ProfileMerge.Field) -> String {
        if field == .nextEvent && editor.draft.home.weather == .off { return "Next event (shown when Daily panel is on)" }
        return field.title
    }

    private var statusLabel: some View {
        // The tone colors the symbol; the message keeps text contrast.
        Label {
            Text(status.text)
        } icon: {
            Image(systemName: status.symbol).foregroundStyle(status.color)
        }
        .font(.callout)
        .accessibilityIdentifier("profile-status")
    }

    @ViewBuilder private var applyControls: some View {
        Button("Discard Edits…") { confirmingDiscard = true }
        .disabled(!anythingDirty || model.isWorking)
        .help("Discard only \(screen.rawValue) edits.")
        .accessibilityIdentifier("profile-revert")
        if model.readerStatus == nil && !model.isDemoMode {
            Button("Connect Reader…", systemImage: "antenna.radiowaves.left.and.right", action: onConnect)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("profile-connect")
        } else {
            Button("Apply to Reader") {
                guard let identity = model.readerStatus?.deviceID, editor.bindForApply(to: identity) else { return }
                appliedScope = screen
                model.sendReaderLayout(profile: profileDirty ? scopedProfile : nil,
                                       cards: nil, show: screenToShow, drawCards: false,
                                       settingsOverride: preferencesDirty ? scopedPreferences : nil,
                                       includePendingPreferences: false,
                                       taskDestination: screen == .reading ? .reading : .screens,
                                       taskScreen: screen == .reading ? nil : screen == .sleep ? .brief : .home)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canApply)
            .help(preview != .reading && model.canShowScreens ? "Apply to the reader (⌘↩). It shows the screen you are editing and stays in Sync."
                                       : "Apply to the reader (⌘↩). The reader stays in Sync.")
            .accessibilityIdentifier("profile-apply")
        }
    }

    // MARK: Controls

    /// Writes one part of the draft and shows the surface it changes.
    private func edit<Value>(_ key: WritableKeyPath<PocketProfile, Value>, on surface: PreviewSurface) -> Binding<Value> {
        Binding(get: { editor.draft[keyPath: key] },
                set: { editor.draft[keyPath: key] = $0; preview = surface })
    }

    /// Locally editable reader settings, staged only by Apply.
    private func setting<Value>(_ get: @escaping (ReaderPreferences) -> Value,
                                _ set: @escaping (inout ReaderPreferences, Value) -> Void,
                                on surface: PreviewSurface? = nil) -> Binding<Value>? {
        Binding(get: { get(editor.reading) }, set: { value in
            set(&editor.reading, value)
            if let surface { preview = surface }
        })
    }

    private var homeItems: Set<PocketProfile.HomeItem> {
        (model.readerProfile?.homeItems ?? Set(PocketProfile.HomeItem.allCases))
            .subtracting(PocketProfile.retiredHomeItems)
    }
    private var sleepSections: Set<PocketProfile.SleepSection> {
        model.readerProfile?.sleepSections ?? Set(PocketProfile.SleepSection.allCases)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 24) {
            switch screen {
            case .home:
                homeControls
                if let startup = setting({ $0.startupApp == 1 }, { $0.startupApp = $1 ? 1 : 0 }, on: .home) {
                    Toggle("Open Pocket Daily at startup", isOn: startup)
                        .accessibilityIdentifier("profile-startup")
                }
            case .reading: readerSettings
            case .sleep: sleepControls
            }
            if screen != .reading {
                sharedContentControls
                recoveredDraftControls
                Button("Reset \(screen.rawValue) Layout") {
                        ProfileMerge.take(screen.fields, from: PocketProfile.defaults, into: &editor.draft)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(scopedProfile == defaultProfile)
                    .accessibilityIdentifier("profile-reset")
            }
        }
        .font(.callout)
        .disabled(model.isWorking || recoveringDraft)
    }

    /// Pages and the shared daily panel follow their order on the reader.
    /// The firmware places weather and the next event in that single panel.
    @ViewBuilder private var homeControls: some View {
        ControlGroup(title: "Layout", note: "Top to bottom · drag to arrange") {
            VStack(spacing: 0) {
                ForEach(homeBlocks, id: \.self) { block in
                    switch block {
                    case .weather: weatherBlock
                    case .pages: pagesBlock
                    }
                    if block != homeBlocks.last { Divider() }
                }
            }
            .background(PocketPalette.panel, in: RoundedRectangle(cornerRadius: PocketDesign.cardRadius))
            .overlay { RoundedRectangle(cornerRadius: PocketDesign.cardRadius).stroke(PocketPalette.line) }
        }

    }

    private enum HomeBlock: String { case weather, pages }

    /// Weather above Pages only when it is placed on top; switched off, it
    /// waits below where it will return.
    private var homeBlocks: [HomeBlock] {
        editor.draft.home.weather == .top ? [.weather, .pages] : [.pages, .weather]
    }

    private var weatherOn: Bool { editor.draft.home.weather != .off }

    private func placeWeather(_ position: PocketProfile.WeatherPanel) {
        editor.draft.home.weather = position
        preview = .home
    }

    private var weatherBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            blockHeader("Daily panel", detail: "Weather & calendar", identifier: "profile-home-weather-block",
                        draggable: weatherOn) {
                Toggle("Daily panel", isOn: Binding(get: { weatherOn },
                                                set: { placeWeather($0 ? weatherWhenOn : .off) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityIdentifier("profile-home-weather")
            }
            .accessibilityActions {
                if weatherOn {
                    Button(editor.draft.home.weather == .top ? "Move Below Pages" : "Move Above Pages") {
                        moveWeather()
                    }
                }
            }
            if weatherOn {
                Toggle("Show next event", isOn: edit(\.home.nextEvent, on: .home))
                    .font(.caption)
                    .padding(.horizontal, 30).padding(.bottom, 12)
                    .accessibilityIdentifier("profile-next-event")
            }
        }
    }

    private var pagesBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            blockHeader("Pages", detail: "Shown one at a time · up to \(PocketProfile.maxHomeItems)",
                        identifier: "profile-home-pages-block", draggable: weatherOn) { EmptyView() }
            ModuleList(selection: edit(\.home.items, on: .home), available: homeItems,
                       limit: PocketProfile.maxHomeItems, framed: false, identifier: "profile-home", drag: $drag,
                       title: { $0.title }, detail: { $0.detail }) { item in
                EmptyView()
            } expansion: { item in
                EmptyView()
            }
            .padding(.leading, 20)
            if editor.draft.home.items.contains(.study), !editor.draft.home.items.contains(.word) {
                Toggle("Daily word when there are no cards", isOn: edit(\.home.dailyWord, on: .home))
                    .font(.caption)
                    .padding(.leading, 30)
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("profile-daily-word")
            }
        }
    }

    /// A block's title row; dragged onto the other block to swap them.
    private func blockHeader<Accessory: View>(_ title: String, detail: String, identifier: String, draggable: Bool,
                                              @ViewBuilder accessory: () -> Accessory) -> some View {
        let row = HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .opacity(draggable ? 1 : 0)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        return Group {
            if draggable {
                row.reorderable(list: "home-blocks", id: title, order: homeBlocks.map { $0 == .weather ? "Daily panel" : "Pages" },
                                drag: $drag) { _, _ in moveWeather() }
                    .contextMenu {
                        Button(editor.draft.home.weather == .top ? "Move Daily Panel Below Pages" : "Move Daily Panel Above Pages") {
                            moveWeather()
                        }
                    }
            } else {
                row
            }
        }
    }

    /// Swaps Weather between above and below Pages.
    private func moveWeather() {
        guard weatherOn else { return }
        let next: PocketProfile.WeatherPanel = editor.draft.home.weather == .top ? .bottom : .top
        weatherWhenOn = next
        placeWeather(next)
    }

    private func openSource(_ source: SourceEditor) {
        activeContentEditor = source == .cards ? .cards : .glance
    }

    private var sharedContentControls: some View {
        ControlGroup(title: "Content") {
            sourceRow("My cards", value: "\(draftCards.cards.count) \(draftCards.cards.count == 1 ? "card" : "cards")", identifier: "profile-edit-cards") {
                openSource(.cards)
            }
            sourceRow("Weather & calendar", value: glanceSummary, identifier: "screen-glance-settings") {
                openSource(.weatherCalendar)
            }
        }
    }

    private var glanceSummary: String {
        if model.isDemoMode { return "Seoul · example events" }
        let city = glanceSettings.place?.name ?? "No weather city"
        let events = glanceSettings.includeEvents ? "Calendar on" : "Calendar off"
        return city + " · " + events
    }

    private func sourceRow(_ title: String, value: String, identifier: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.medium)
                    Text(value).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private var recoveredDraftControls: some View {
        let recovered = recoveredDrafts
        if !recovered.isEmpty, !model.isDemoMode {
            Menu("Recovered Drafts") {
                ForEach(Array(recovered.enumerated()), id: \.offset) { _, snapshot in
                    Button((snapshot.targetDeviceID ?? "Offline Draft") + " · " + snapshot.savedAt.formatted(date: .abbreviated, time: .shortened)) {
                        recoveringDraft = true
                        Task {
                            defer { recoveringDraft = false }
                            do {
                            if let current = editor.snapshot { try await Task.detached { [store = model.profileEditStore] in try store.archive(current) }.value }
                            editor.restore(snapshot)
                            editor.observeTarget(model.readerStatus?.deviceID)
                            editor.sync(with: model.readerProfile)
                            editor.syncReading(model.preferences)
                        } catch { targetError = error.localizedDescription } }
                    }
                }
            }
            .font(.caption)
        }
    }

    @ViewBuilder private var sleepControls: some View {
        ControlGroup(title: "Display", note: editor.draft.sleep.mode == .brief ? "Drag to reorder" : nil) {
            Picker("Sleep screen", selection: edit(\.sleep.mode, on: .sleep)) {
                ForEach(PocketProfile.SleepMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("profile-sleep-mode")
            if editor.draft.sleep.mode == .reader {
                Text("Uses the Sleep Screen set on the reader.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ModuleList(selection: edit(\.sleep.sections, on: .sleep), available: sleepSections,
                           identifier: "profile-sleep", drag: $drag,
                           title: { $0.title }, detail: { $0.detail }) { section in
                    if section == .card {
                        Button("Edit") {
                            openSource(.cards)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .accessibilityIdentifier("profile-sleep-edit-cards")
                    }
                } expansion: { section in
                    if section == .reading, editor.draft.sleep.sections.contains(.reading),
                       let cover = setting({ $0.pocketDailySleepCover }, { $0.pocketDailySleepCover = $1 }, on: .sleep) {
                        Toggle("Book cover", isOn: cover)
                            .font(.caption)
                            .padding(.leading, 30)
                            .padding(.trailing, 10)
                            .padding(.bottom, 8)
                            .accessibilityIdentifier("profile-sleep-cover")
                    }
                }
            }
        }
        ControlGroup(title: "Wake indicator", note: nil) {
            if editor.reading.sleepWakeIndicator != nil,
               let wake = setting({ $0.sleepWakeIndicator ?? true }, { $0.sleepWakeIndicator = $1 }, on: .sleep) {
                Toggle("Show WAKE on sleep screen", isOn: wake)
                    .accessibilityIdentifier("profile-sleep-wake")
                Text(model.hardware == .x3
                     ? "Marks the power button on the top edge of X3."
                     : "Marks the power button on the upper-right edge of X4.")
                    .font(.caption).foregroundStyle(.secondary)

            } else {
                Text("This reader’s firmware does not offer a WAKE indicator setting. Update to firmware that supports it to change the display.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if let timeout = setting({ $0.sleepTimeoutMinutes }, { $0.sleepTimeoutMinutes = $1 }, on: .sleep) {
            // The reader accepts 1-30 minutes; 31 means it never sleeps on its own.
            Stepper(timeout.wrappedValue >= ReaderPreferences.neverSleepMinutes
                        ? "Never sleep on its own" : "Sleep after \(timeout.wrappedValue) min",
                    value: timeout, in: 1...ReaderPreferences.neverSleepMinutes)
                .accessibilityIdentifier("profile-sleep-timeout")
        }
    }

    private var readerSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            ControlGroup(title: "Text size") {
                Picker("Text size", selection: $editor.reading.fontSize) {
                    Text("Small").tag(0)
                    Text("Medium").tag(1)
                    Text("Large").tag(2)
                    Text("Extra large").tag(3)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("profile-text-size")
            }
            if editor.reading.orientation != nil {
                ControlGroup(title: "Orientation") {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            orientationPicker.pickerStyle(.menu)
                        } else {
                            orientationPicker.pickerStyle(.segmented)
                        }
                    }
                    .labelsHidden()
                    .accessibilityIdentifier("profile-orientation")
                    Toggle("Flip 180°", isOn: Binding(
                        get: { readingReversed }, set: { reversed in
                            editor.reading.orientation = readingLandscape
                                ? (reversed ? .landscapeReversed : .landscape)
                                : (reversed ? .inverted : .portrait)
                        }))
                    .font(.caption)
                }
            }
            if editor.reading.lineSpacing != nil {
                ControlGroup(title: "Line spacing") {
                    Picker("Line spacing", selection: Binding(get: { editor.reading.lineSpacing ?? .normal },
                                                              set: { editor.reading.lineSpacing = $0 })) {
                        ForEach(ReaderPreferences.LineSpacing.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("profile-line-spacing")
                }
            }
            if editor.reading.screenMargin != nil {
                ControlGroup(title: "Margins") {
                    Text("\(editor.reading.screenMargin ?? 5) px").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(editor.reading.screenMargin ?? 5) },
                        set: { editor.reading.screenMargin = Int($0) }), in: 5...40, step: 5) {
                            Text("Margins")
                        } minimumValueLabel: { Text("Narrow").font(.caption) }
                          maximumValueLabel: { Text("Wide").font(.caption) }
                        .labelsHidden()
                        .frame(maxWidth: 360)
                        .accessibilityIdentifier("profile-margin")
                }
            }
            if editor.reading.sideButtons != nil || editor.reading.frontButtonsFollowOrientation != nil {
                ControlGroup(title: "Page buttons") {
                    if editor.reading.sideButtons != nil {
                        Picker("Page buttons", selection: Binding(get: { editor.reading.sideButtons ?? .previousNext },
                                                                 set: { editor.reading.sideButtons = $0 })) {
                            Text("Previous / Next").tag(ReaderPreferences.SideButtons.previousNext)
                            Text("Next / Previous").tag(ReaderPreferences.SideButtons.nextPrevious)
                            Text("Off").tag(ReaderPreferences.SideButtons.off)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .accessibilityIdentifier("profile-page-buttons")
                        ReaderButtonDiagram(hardware: model.hardware, preferences: editor.reading)
                    }
                    if editor.reading.frontButtonsFollowOrientation != nil {
                        Toggle("Follow screen rotation", isOn: Binding(
                            get: { editor.reading.frontButtonsFollowOrientation ?? false },
                            set: { editor.reading.frontButtonsFollowOrientation = $0 }))
                            .accessibilityIdentifier("profile-rotate-buttons")
                    }
                    DisclosureGroup("About button settings") {
                        Text("Rotation reverses page and navigation keys on inverted and counter-clockwise pages. Front key remapping stays on the reader.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if model.readerStatus != nil && editor.reading.orientation == nil {
                Text("More reading options require newer reader firmware.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var orientationPicker: some View {
        Picker("Orientation", selection: Binding(
            get: { readingLandscape }, set: { landscape in
                editor.reading.orientation = landscape
                    ? (readingReversed ? .landscapeReversed : .landscape)
                    : (readingReversed ? .inverted : .portrait)
            })) {
            Label("Portrait", systemImage: "rectangle.portrait").tag(false)
            Label("Landscape", systemImage: "rectangle").tag(true)
        }
    }

    private var readingReversed: Bool { editor.reading.orientation == .inverted || editor.reading.orientation == .landscapeReversed }

    private var readingLandscape: Bool { editor.reading.orientation?.isLandscape ?? false }

    /// An illustrative size comparison, never presented as the EPUB renderer.
    private var readingSample: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("SAVED ARTICLE").font(.system(size: 16, weight: .medium))
            Divider().overlay(.black)
            Text("A little time to read").font(.system(size: 30, weight: .bold, design: .serif))
            Text("Save an article when it catches your eye. Read it later on your reader, away from the busy screen.\n\nA few quiet minutes are enough to enjoy a good story. Choose a text size that feels comfortable, then keep reading at your own pace.\n\nYour saved articles will be waiting whenever you return.")
                .font(.system(size: CGFloat(22 + editor.reading.fontSize * 5), design: .serif))
                .lineSpacing(CGFloat((editor.reading.lineSpacing?.rawValue ?? 1) * 5))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            Divider().overlay(.black)
            Text("READING EXAMPLE").font(.system(size: 14))
        }
        .padding(CGFloat(editor.reading.screenMargin ?? 5) + 12)
        .frame(width: CGFloat(readingLandscape ? model.hardware.screenHeight : model.hardware.screenWidth),
               height: CGFloat(readingLandscape ? model.hardware.screenWidth : model.hardware.screenHeight))
        .foregroundStyle(.black)
        .background(.white)
        .environment(\.colorScheme, .light)
    }

    // MARK: Cards and schematic

    @MainActor private func openCards() async {
        cards = nil
        cardsError = nil
        await model.restorePendingContentActivation()
        do {
            let candidate = try model.contentEditorModel()
            if !model.isDemoMode && !candidate.hasLoaded { try await candidate.load() }
            // Demo shows a card; it lives only in this in-memory editor.
            if candidate.isDemo && candidate.draft.cards.isEmpty { candidate.edit(Self.demoCards) }
            cards = candidate
        } catch { cardsError = error.localizedDescription }
    }

    /// Demo cards show both uses: a QR contact card and a plain note.
    static let demoCards: ContentDraft = {
        var contact = ContentCard(id: "demo-contact", title: "If found",
                                  question: "Please return this reader. Scan to see how.",
                                  context: "Demo cards are never saved or sent.")
        var images: [String: Data] = [:]
        if let qr = try? ContentQRCode.image(for: "https://puritysb.github.io/pocket-daily/") {
            contact.imagePath = qr.path
            images[qr.path] = qr.data
        }
        return ContentDraft(cards: [
            contact,
            ContentCard(id: "demo-card-1", title: "Today's question",
                        question: "What is one thing from yesterday's reading you want to remember?"),
        ], images: images)
    }()

    private func loadRecoveredDrafts() async -> [ProfileEditSnapshot] {
        let store = model.profileEditStore
        return await Task.detached { store.recoveredDrafts() }.value
    }

    private func renderSchematic() {
        guard preview != .reading else { return }
        let size = CGSize(width: model.hardware.screenWidth, height: model.hardware.screenHeight)
        let renderer = ImageRenderer(content: PocketLayoutSchematic(profile: editor.draft,
                                                                   surface: preview == .home ? .home : .sleep)
            .frame(width: size.width, height: size.height))
        renderer.scale = 1
        schematic = renderer.cgImage
    }
}

/// A titled block of editor controls with an optional one-line note.
private struct ControlGroup<Content: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
    }
}

/// A structural drawing of the Pocket Daily Home or Daily Brief, sized to the
/// reader's logical screen. It shows placement and order, not real content.
struct PocketLayoutSchematic: View {
    let profile: PocketProfile
    let surface: ProfileStudioView.PreviewSurface

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pocket Daily").font(.system(size: 22, weight: .bold))
            Rectangle().fill(Color.black).frame(height: 2)
            if surface == .home { home } else { sleep }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(Color.black)
        .background(Color.white)
    }

    @ViewBuilder private var home: some View {
        block("Status", height: 22, filled: true)
        if profile.home.weather == .top { weatherPanel }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(profile.home.items.first?.title ?? "—").font(.system(size: 20, weight: .bold))
                Spacer()
                Text("1/\(profile.home.items.count)").font(.system(size: 14, weight: .semibold))
            }
            ForEach(Array(profile.home.items.dropFirst().enumerated()), id: \.offset) { offset, item in
                Text("\(offset + 2). \(item.title)").font(.system(size: 15))
            }
            if profile.home.items.contains(.study) {
                Text(profile.home.dailyWord ? "Study: app cards, else the daily word" : "Study: app cards only")
                    .font(.system(size: 13))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black, lineWidth: 2))
        if profile.home.weather == .bottom { weatherPanel }
        HStack {
            Text("Library"); Spacer(); Text("Select"); Spacer(); Text("—"); Spacer(); Text("Sync")
        }
        .font(.system(size: 15, weight: .semibold))
    }

    private var weatherPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Weather").font(.system(size: 17, weight: .bold))
            Text("Now · 5-day forecast").font(.system(size: 14))
            Spacer(minLength: 0)
            if profile.home.nextEvent {
                Rectangle().fill(Color.black).frame(height: 1)
                Text("Next event").font(.system(size: 14, weight: .semibold))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 230)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black, lineWidth: 2))
    }

    @ViewBuilder private var sleep: some View {
        if profile.sleep.mode == .reader {
            Spacer()
            Text("Reader's sleep screen").font(.system(size: 22, weight: .bold)).frame(maxWidth: .infinity)
            Text("Chosen on the reader in\nSettings → Sleep Screen").font(.system(size: 15))
                .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            Spacer()
        } else {
            ForEach(profile.sleep.sections, id: \.self) { section in
                block(section.title, height: height(of: section), filled: false)
            }
            Spacer(minLength: 0)
            Text("Powered off").font(.system(size: 13, weight: .semibold))
        }
    }

    private func height(of section: PocketProfile.SleepSection) -> CGFloat {
        switch section {
        case .card: 160
        case .reading: 190
        case .study: 110
        case .weather: profile.sleep.sections.last == .weather ? 230 : 200
        case .today: 80
        }
    }

    private func block(_ label: String, height: CGFloat, filled: Bool) -> some View {
        Text(label)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(filled ? Color.white : Color.black)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: height)
            .background(filled ? Color.black : Color.white)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black, lineWidth: filled ? 0 : 2))
    }
}

/// What happened when unsent edits met the reader's own settings, and the rule
/// that decided it (`ProfileMerge`).
private struct MergeNotice: View {
    let report: ProfileMerge.Report
    /// What Apply would still change on the reader, if anything.
    let pending: String?
    let describe: (ProfileMerge.Field) -> String
    let useReader: () -> Void
    let dismiss: () -> Void

    private func names(_ fields: [ProfileMerge.Field]) -> String { fields.map(describe).joined(separator: ", ") }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Merged with the reader’s settings", systemImage: "arrow.triangle.merge")
                .font(.callout.weight(.semibold))
            if !report.fromReader.isEmpty {
                Text("Taken from the reader, because you had not changed them: \(names(report.fromReader)).")
            }
            if !report.bothChanged.isEmpty {
                PocketStatusLabel("Changed in both places: \(names(report.bothChanged)). Your edits are kept and replace the reader’s when you apply.",
                                  tone: .pending, symbol: "exclamationmark.triangle")
            }
            Text(pending.map { "Apply changes on the reader: \($0)." }
                 ?? "Nothing else differs from the reader; Apply has nothing to send.")
                .accessibilityIdentifier("merge-pending")
            HStack {
                if !report.bothChanged.isEmpty {
                    Button("Use Reader’s Values", action: useReader)
                        .accessibilityIdentifier("merge-use-reader")
                }
                Spacer()
                Button("OK", action: dismiss).accessibilityIdentifier("merge-dismiss")
            }
            .buttonStyle(.bordered)
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .background(PocketPalette.card, in: RoundedRectangle(cornerRadius: PocketDesign.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: PocketDesign.cardRadius).stroke(PocketPalette.line) }
        .help("Each setting is merged on its own: one you did not touch follows the reader, one the reader did not change keeps your edit.")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("merge-notice")
    }
}
