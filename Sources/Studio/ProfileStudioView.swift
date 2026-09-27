import SwiftUI

/// Draft of the Home & Sleep profile. Lives with the app window so switching
/// tabs keeps unsent edits.
@MainActor
final class ProfileEditorState: ObservableObject {
    @Published var draft: PocketProfile = .defaults
    /// The reader profile the draft started from (defaults when none).
    @Published private(set) var base: PocketProfile = .defaults
    private var baseGeneration: UInt32?

    var isDirty: Bool { draft != base }

    /// Adopt a newly loaded or saved reader profile unless it would discard
    /// unsent edits made against an older base.
    func sync(with reader: ReaderProfileState?) {
        // Daemon-fed items are dropped on load, so they never count as edits.
        guard let reader else { return }
        let incoming = reader.profile.withoutRetiredItems
        guard reader.generation != baseGeneration || incoming != base else { return }
        if !isDirty || draft == incoming { draft = incoming }
        base = incoming
        baseGeneration = reader.generation
    }

    @Published var reading = ReaderPreferences(sideButtons: .previousNext, frontButtonsFollowOrientation: false)
    @Published private(set) var readingBase = ReaderPreferences(sideButtons: .previousNext, frontButtonsFollowOrientation: false)
    var readingDirty: Bool { reading != readingBase }

    /// Adopt untouched fields, retaining edits made before connecting.
    func syncReading(_ loaded: ReaderPreferences?) {
        guard let loaded else { return }
        var merged = loaded
        if reading.startupApp != readingBase.startupApp { merged.startupApp = reading.startupApp }
        if reading.pocketDailySleepCover != readingBase.pocketDailySleepCover { merged.pocketDailySleepCover = reading.pocketDailySleepCover }
        if reading.sleepTimeoutMinutes != readingBase.sleepTimeoutMinutes { merged.sleepTimeoutMinutes = reading.sleepTimeoutMinutes }
        if reading.fontSize != readingBase.fontSize { merged.fontSize = reading.fontSize }
        if loaded.sideButtons != nil, reading.sideButtons != readingBase.sideButtons { merged.sideButtons = reading.sideButtons }
        if loaded.frontButtonsFollowOrientation != nil, reading.frontButtonsFollowOrientation != readingBase.frontButtonsFollowOrientation {
            merged.frontButtonsFollowOrientation = reading.frontButtonsFollowOrientation
        }
        readingBase = loaded
        reading = merged
    }

    func acceptReading(_ saved: ReaderPreferences?) {
        guard let saved else { return }
        readingBase = saved
        reading = saved
    }

    func revert() { draft = base; reading = readingBase }
}

/// Home & Sleep editor, organized around the reader's two Pocket Daily screens.
/// Pick one and the canvas shows it drawn by the firmware painter with the
/// user's own cards and sample content (an outline when that renderer is
/// unavailable); the controls beside it (below when `stacked`) edit only that
/// screen. Its pages or sections are modules switched on and dragged into
/// order, and My cards live inside Home. Reading size follows screen settings,
/// and one Apply sends everything that changed.
struct ProfileStudioView: View {
    @ObservedObject var model: PocketModel
    @ObservedObject var editor: ProfileEditorState
    var stacked = false
    /// Side by side in a fixed-height window: the controls scroll on their own.
    var scrollsControls = false
    /// Stacked on a phone: the editor scrolls on its own and the Apply bar
    /// stays pinned above the tab bar instead of scrolling away.
    var pinsApplyBar = false
    /// Shown above the editor when it scrolls on its own (a firmware notice).
    var header: AnyView? = nil
    @State private var preview: PreviewSurface = .home
    @State private var schematic: CGImage?
    @StateObject private var layout = LayoutPreviewModel()
    @StateObject private var cardPreview = ContentPreviewModel()
    @State private var cards: ContentEditorModel?
    @State private var cardsError: String?
    @State private var selectedCardID: String?
    @State private var editingCards: Bool
    @State private var confirmingDiscard = false
    @State private var showsReadingSample = false
    @State private var drag: ReorderDrag?
    /// Where Weather returns when switched back on.
    @State private var weatherWhenOn: PocketProfile.WeatherPanel = .bottom

    /// What the canvas draws. A card page belongs to Home: the selected card
    /// as the reader shows it when opened.
    enum PreviewSurface: String, CaseIterable { case home = "Home", card = "Card", sleep = "Sleep" }
    /// The screens the editor is organized around.
    enum Screen: String, CaseIterable { case home = "Home", sleep = "Sleep" }

    init(model: PocketModel, editor: ProfileEditorState, stacked: Bool = false, scrollsControls: Bool = false,
         pinsApplyBar: Bool = false, header: AnyView? = nil, initialPreview: PreviewSurface = .home) {
        self.model = model
        self.editor = editor
        self.stacked = stacked
        self.scrollsControls = scrollsControls && !stacked
        self.pinsApplyBar = pinsApplyBar && stacked
        self.header = header
        _preview = State(initialValue: initialPreview)
        _editingCards = State(initialValue: initialPreview == .card)
    }

    var body: some View {
        Group {
            if pinsApplyBar {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        editorColumns
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    applyBar
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    applyBar
                    editorColumns
                }
            }
        }
        .onAppear {
            editor.sync(with: model.readerProfile)
            if !model.preferencesDirty { editor.syncReading(model.preferences) }
            if editor.draft.home.weather != .off { weatherWhenOn = editor.draft.home.weather }
        }
        .onChange(of: model.preferences) { _, preferences in
            if !model.preferencesDirty { editor.syncReading(preferences) }
        }
        .onChange(of: model.preferencesDirty) { wasDirty, dirty in
            if wasDirty && !dirty { editor.acceptReading(model.preferences) }
        }
        .alert("Discard layout and reading-setting edits?", isPresented: $confirmingDiscard) {
            Button("Discard edits", role: .destructive) {
                editor.revert()
                model.revertPreferences()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Restores the last loaded layout and reading settings, or their starting defaults before connecting. Card edits stay. Nothing is sent to the reader.")
        }
        .onChange(of: model.readerProfile) { _, reader in editor.sync(with: reader) }
        .onChange(of: editor.draft) { _, _ in showsReadingSample = false }
        .onChange(of: editor.draft.home.weather) { _, weather in if weather != .off { weatherWhenOn = weather } }
        .task(id: model.isDemoMode) { await openCards() }
        .task(id: previewKey) {
            renderSchematic()
            if let request = layoutRequest { await layout.update(request) }
        }
        .task(id: cardRequest) {
            if let cardRequest { await cardPreview.update(cardRequest) } else { cardPreview.cancel() }
        }
        .onDisappear { cardPreview.cancel() }
    }

    /// The canvas and its controls, side by side or stacked.
    @ViewBuilder private var editorColumns: some View {
        let columns = stacked ? AnyLayout(VStackLayout(alignment: .center, spacing: 20))
                              : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
        columns {
            canvas
            if scrollsControls {
                ScrollView {
                    controls.padding(.bottom, 24)
                }
                .frame(maxWidth: 380, maxHeight: .infinity, alignment: .topLeading)
                .scrollIndicators(.visible)
            } else {
                controls
                    .frame(maxWidth: stacked ? .infinity : 360, alignment: .topLeading)
            }
        }
    }

    private var screen: Screen { preview == .sleep ? .sleep : .home }
    private var draftCards: ContentDraft { cards?.draft ?? .init() }
    private var selectedCard: ContentCard? {
        draftCards.cards.first { $0.id == selectedCardID } ?? draftCards.cards.first
    }

    // MARK: Canvas

    private struct PreviewKey: Equatable {
        let profile: PocketProfile
        let surface: PreviewSurface
        let hardware: PocketHardware
        let cards: ContentDraft
    }

    private var previewKey: PreviewKey {
        .init(profile: editor.draft, surface: preview, hardware: model.hardware, cards: draftCards)
    }

    /// The reader's own sleep screen and a card page are not layouts.
    private var layoutRequest: LayoutPreviewRequest? {
        if preview == .card || (preview == .sleep && editor.draft.sleep.mode == .reader) { return nil }
        guard editor.draft.validationError == nil else { return nil }
        return LayoutPreviewRequest(profile: editor.draft, surface: preview == .home ? .home : .brief,
                                    hardware: model.hardware, cards: draftCards)
    }

    private var cardRequest: ContentPreviewRequest? {
        guard preview == .card, let card = selectedCard else { return nil }
        return .init(card: card, image: draftCards.images[card.imagePath], hardware: model.hardware,
                     orientation: .portrait, style: model.readerDisplay.map(PreviewStyle.init(reader:)) ?? .reference)
    }

    private var showsRender: Bool {
        preview == .card ? cardPreview.image != nil : layoutRequest != nil && layout.image != nil
    }
    private var canvasImage: CGImage? {
        if showsReadingSample { return ImageRenderer(content: readingSample).cgImage }
        if preview == .card { return cardPreview.image }
        return showsRender ? layout.image : schematic
    }

    private var canvas: some View {
        VStack(spacing: 10) {
            Picker("Screen", selection: Binding(get: { screen }, set: { showsReadingSample = false; preview = $0 == .home ? .home : .sleep })) {
                ForEach(Screen.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            .accessibilityIdentifier("profile-screen")
            PocketDevicePreview(hardware: model.hardware, status: model.readerStatus, renderedScreen: canvasImage)
                .frame(maxWidth: 340)
                .frame(height: 470)
                .overlay { canvasOverlay }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(canvasLabel)
                .accessibilityValue(canvasIsCurrent ? "Current" : "Updating")
                .accessibilityIdentifier("profile-canvas")
            Text(showsReadingSample ? "Text size example · approximate appearance" : "Layout preview · not a live reader screen")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Label(canvasCaption, systemImage: showsRender ? "text.below.photo" : "square.dashed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(preview == .card ? "The card as the reader draws it when opened." :
                          showsRender ? "Preview uses your card drafts plus an example book, weather and schedule. It is not a live image of your reader." : "")
                    .accessibilityIdentifier("profile-canvas-caption")
                if showsReadingSample {
                    Button("Back to layout") { showsReadingSample = false }
                        .font(.caption2).accessibilityIdentifier("profile-back-to-layout")
                } else if preview == .card {
                    Button("Show Home") { preview = .home }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                        .accessibilityIdentifier("profile-show-home")
                }
            }
        }
        .frame(width: stacked ? nil : 340)
    }

    @ViewBuilder private var canvasOverlay: some View {
        if showsReadingSample {
            EmptyView()
        } else if preview == .card, selectedCard == nil {
            Text("Add a card to see it here").font(.caption)
                .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        } else if preview == .card, cardPreview.image == nil, let error = cardPreview.error {
            Text(error).font(.caption).multilineTextAlignment(.center)
                .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(40)
        }
    }

    private var canvasIsCurrent: Bool {
        if showsReadingSample { return true }
        if preview == .card { return cardPreview.image != nil || cardRequest == nil }
        return layoutRequest == nil || layout.renderedRequest == layoutRequest
    }

    private var canvasLabel: String {
        if showsReadingSample { return "Reading example, text size \(editor.reading.fontSize + 1) of 4" }
        return switch preview {
        case .card: selectedCard.map { "Card \($0.title)" } ?? "No card"
        case .home, .sleep:
            showsRender ? "Pocket Daily \(preview.rawValue.lowercased()) with sample content"
                        : "Outline of the Pocket Daily \(preview.rawValue.lowercased()) layout"
        }
    }

    private var canvasCaption: String {
        if showsReadingSample { return "Example article · actual font and pages depend on the book" }
        if preview == .card { return "Card page" }
        if showsRender {
            if model.isDemoMode { return "Demo cards · example book, weather & schedule" }
            return draftCards.cards.isEmpty ? "Example book, weather & schedule" : "Your cards · example book, weather & schedule"
        }
        if layoutRequest != nil, layout.error != nil { return "Layout outline · preview unavailable" }
        return "Layout outline"
    }

    // MARK: Apply

    private var cardsRevision: ContentRevision? {
        guard let cards, !cards.draft.cards.isEmpty else { return nil }
        return try? cards.deploymentSnapshot()
    }

    private var cardsValidation: String? {
        guard let cards, !cards.draft.cards.isEmpty else { return nil }
        do { _ = try cards.deploymentSnapshot(); return nil } catch { return MyCardsEditor.describe(error) }
    }

    /// My cards differ from what the reader has (or the reader's set is unknown).
    private var cardsDirty: Bool {
        guard model.contentEditingSession != nil, let revision = cardsRevision else { return false }
        return revision.revision != model.readerContentRevision
    }

    private var cardStatus: ContentSendStatus {
        ContentSendStatus.evaluate(.init(
            isDemo: model.isDemoMode, connected: model.readerStatus != nil,
            canPresent: model.contentEditingSession != nil, validation: cardsValidation,
            cardCount: draftCards.cards.count, draftRevision: cardsRevision?.revision,
            phase: model.contentDeployment?.phase, redrawConfirmed: model.contentRedrawReceipt,
            busy: model.isWorking))
    }

    private var profileDirty: Bool { model.canEditReaderProfile && editor.isDirty }
    private var anythingDirty: Bool { profileDirty || editor.readingDirty || model.preferencesDirty || cardsDirty }

    private var status: (text: String, symbol: String, color: Color) {
        if model.isDemoMode { return ("Demo · nothing is sent", "info.circle", .secondary) }
        if model.readerStatus == nil { return ("Editing in the app · connect to reader Sync to apply", "info.circle", .secondary) }
        if editor.readingDirty && model.preferences == nil {
            return ("Reconnect to reader Sync to load settings before applying", "info.circle", .orange)
        }
        if let error = editor.draft.validationError ?? cardsValidation { return (error, "exclamationmark.triangle", .red) }
        if case let .sending(step) = cardStatus { return ("\(step)…", "arrow.triangle.2.circlepath", .secondary) }
        if model.profileSend == .sending { return ("Applying on the reader…", "arrow.triangle.2.circlepath", .secondary) }
        if case .showing = model.screenShow { return ("Showing it on the reader…", "arrow.triangle.2.circlepath", .secondary) }
        switch model.profileSend {
        case .conflict: return ("Changed on the reader · its version was loaded", "exclamationmark.triangle", .orange)
        case let .failed(message) where anythingDirty: return ("Not applied · \(message)", "xmark.octagon", .red)
        default: break
        }
        switch cardStatus {
        case .needsCheck: return (cardStatus.label, cardStatus.symbol, .orange)
        case .failed where cardsDirty: return ("Cards not applied · \(model.message)", "xmark.octagon", .red)
        default: break
        }
        if anythingDirty { return ("Edits in the app · not yet applied to reader", "circle.dashed", .orange) }
        if case .storedNotShown = cardStatus { return (cardStatus.label, cardStatus.symbol, .orange) }
        if !model.canEditReaderProfile && editor.isDirty {
            return ("This reader's firmware can't store Home & Sleep yet", "exclamationmark.triangle", .orange)
        }
        switch model.screenShow {
        case let .shown(screen, _):
            return ("Applied · \(screen == .home ? "Home" : "sleep screen") shown on the reader",
                    "checkmark.circle.fill", .green)
        case .failed:
            return ("Applied · the reader shows it when you leave Sync", "checkmark.circle", .orange)
        default: break
        }
        // Without screen presentation the reader redraws Home and Sleep from a
        // saved profile only when it next paints Pocket Daily (when Sync ends).
        if case .saved = model.profileSend {
            return (cardStatus == .shown ? "Applied · card on screen now, Home and Sleep when you leave Sync"
                                         : "Applied · Home and Sleep show when you leave Sync",
                    "checkmark.circle.fill", .green)
        }
        if cardStatus == .shown { return ("Applied · card shown on the reader", "checkmark.circle.fill", .green) }
        return ("Up to date with the reader", "checkmark.circle.fill", .green)
    }

    /// The screen being edited, for readers that draw it inside Sync. A card
    /// page is drawn by content presentation instead; the reader's own sleep
    /// screen is not a Pocket Daily frame.
    private var screenToShow: ReaderScreen? {
        switch preview {
        case .home: .home
        case .sleep: editor.draft.sleep.mode == .brief ? .brief : nil
        case .card: nil
        }
    }

    private var canApply: Bool {
        model.readerStatus != nil && !model.isDemoMode && !model.isWorking && anythingDirty &&
            (!editor.readingDirty || model.preferences != nil) &&
            editor.draft.validationError == nil && (cardsValidation == nil || !cardsDirty)
    }

    /// One line when it fits; otherwise the status above the buttons.
    private var applyBar: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            if case .needsCheck = cardStatus, let deployment = model.contentDeployment {
                ContentDeploymentStatus(deployment: deployment, model: model)
            }
            ContentJournalRecovery(model: model)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(PocketPalette.panel, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(pinsApplyBar ? 0.08 : 0), radius: 8, y: 2)
    }

    private var statusLabel: some View {
        Label(status.text, systemImage: status.symbol)
            .font(.callout)
            .foregroundStyle(status.color)
            .accessibilityIdentifier("profile-status")
    }

    @ViewBuilder private var applyControls: some View {
        Button("Discard edits…") { confirmingDiscard = true }
        .disabled(!(editor.isDirty || editor.readingDirty || model.preferencesDirty) || model.isWorking)
        .help("Discard layout and reading-setting edits. Card edits stay; nothing is sent to the reader.")
        .accessibilityIdentifier("profile-revert")
        Button("Apply to reader") {
            if editor.readingDirty { model.stageReadingPreferences(editor.reading) }
            model.sendReaderLayout(profile: profileDirty ? editor.draft : nil,
                                   cards: cardsDirty ? cardsRevision : nil, show: screenToShow)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canApply)
        .help(model.canShowScreens ? "Apply to the reader (⌘↩). It shows the screen you are editing and stays in Sync."
                                   : "Apply to the reader (⌘↩). The reader stays in Sync.")
        .accessibilityIdentifier("profile-apply")
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
            if let surface { showsReadingSample = false; preview = surface }
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
        VStack(alignment: .leading, spacing: 22) {
            switch screen {
            case .home:
                homeControls
                readerSettings
            case .sleep: sleepControls
            }
            Button("Reset to default layout") { editor.draft = .defaults }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(editor.draft == .defaults)
                .accessibilityIdentifier("profile-reset")
        }
        .font(.callout)
        .disabled(model.isWorking)
    }

    /// Home top to bottom: the Weather block and the Pages block in screen
    /// order. Dragging Weather above or below Pages places it; its switch
    /// removes it. Weather's own settings open inside it.
    @ViewBuilder private var homeControls: some View {
        ControlGroup(title: "Home screen", note: "Top to bottom · drag to arrange") {
            VStack(spacing: 0) {
                ForEach(homeBlocks, id: \.self) { block in
                    switch block {
                    case .weather: weatherBlock
                    case .pages: pagesBlock
                    }
                    if block != homeBlocks.last { Divider() }
                }
            }
            .background(PocketPalette.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(PocketPalette.line) }
        }
        if let startup = setting({ $0.startupApp == 1 }, { $0.startupApp = $1 ? 1 : 0 }, on: .home) {
            Toggle("Open Pocket Daily when the reader starts", isOn: startup)
                .accessibilityIdentifier("profile-startup")
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
            blockHeader("Weather", detail: "Now and five days", identifier: "profile-home-weather-block",
                        draggable: weatherOn) {
                Toggle("Weather", isOn: Binding(get: { weatherOn },
                                                set: { placeWeather($0 ? weatherWhenOn : .off) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityIdentifier("profile-home-weather")
            }
            .accessibilityActions {
                if weatherOn {
                    Button(editor.draft.home.weather == .top ? "Move below pages" : "Move above pages") {
                        moveWeather()
                    }
                }
            }
            if weatherOn {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Next event", isOn: edit(\.home.nextEvent, on: .home))
                        .accessibilityIdentifier("profile-next-event")
                    GlanceControls(settings: model.glanceSettings, model: model)
                }
                .padding(.horizontal, 12)
                .padding(.leading, 20)
                .padding(.bottom, 12)
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
                if item == .study { cardsDisclosure }
            } expansion: { item in
                if item == .study, editingCards { cardsEditor }
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
                row.reorderable(list: "home-blocks", id: title, order: homeBlocks.map(\.rawValue.capitalized),
                                drag: $drag) { _, _ in moveWeather() }
                    .contextMenu {
                        Button(editor.draft.home.weather == .top ? "Move Weather Below Pages" : "Move Weather Above Pages") {
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

    /// Opens My cards under their Home page, with the canvas on the selected card.
    private var cardsDisclosure: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { editingCards.toggle() }
            preview = editingCards && selectedCard != nil ? .card : .home
        } label: {
            HStack(spacing: 4) {
                if !draftCards.cards.isEmpty { Text("\(draftCards.cards.count)").monospacedDigit() }
                Image(systemName: "chevron.right").rotationEffect(.degrees(editingCards ? 90 : 0))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(editingCards ? "Hide My cards" : "Edit My cards")
        .accessibilityIdentifier("profile-edit-cards")
    }

    @ViewBuilder private var cardsEditor: some View {
        Group {
            if let cards {
                MyCardsEditor(editor: cards, model: model, selectedID: $selectedCardID, drag: $drag) { preview = .card }
            } else if let cardsError {
                Text(cardsError).font(.caption).foregroundStyle(.red)
                Button("Retry loading cards") { Task { await openCards() } }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var sleepControls: some View {
        ControlGroup(title: "Sleep screen", note: editor.draft.sleep.mode == .brief ? "Drag to reorder" : nil) {
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
                            preview = .card
                            editingCards = true
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .accessibilityIdentifier("profile-sleep-edit-cards")
                    }
                } expansion: { section in
                    if section == sleepGlanceSection {
                        GlanceControls(settings: model.glanceSettings, model: model)
                            .padding(.leading, 30)
                            .padding(.trailing, 10)
                            .padding(.bottom, 10)
                    }
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
        if let timeout = setting({ $0.sleepTimeoutMinutes }, { $0.sleepTimeoutMinutes = $1 }, on: .sleep) {
            // The reader accepts 1-30 minutes; 31 means it never sleeps on its own.
            Stepper(timeout.wrappedValue >= ReaderPreferences.neverSleepMinutes
                        ? "Never sleep on its own" : "Sleep after \(timeout.wrappedValue) min",
                    value: timeout, in: 1...ReaderPreferences.neverSleepMinutes)
                .accessibilityIdentifier("profile-sleep-timeout")
        }
    }

    /// The sleep section that carries the city and calendar settings: Weather
    /// when shown, else Today's schedule.
    private var sleepGlanceSection: PocketProfile.SleepSection? {
        let sections = editor.draft.sleep.sections
        return sections.contains(.weather) ? .weather : sections.contains(.today) ? .today : nil
    }

    private var readerSettings: some View {
        ControlGroup(title: "Reading", note: "Books & saved articles") {
            Picker("Text size", selection: Binding(get: { editor.reading.fontSize }, set: { editor.reading.fontSize = $0; showsReadingSample = true })) {
                Text("Small").tag(0)
                Text("Medium").tag(1)
                Text("Large").tag(2)
                Text("Extra large").tag(3)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("profile-text-size")
            HStack {
                Text("Changes book text, not Home or Sleep.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Preview") { showsReadingSample = true }
                    .font(.caption).accessibilityIdentifier("profile-preview-reading")
            }
        }
    }

    /// An illustrative size comparison, never presented as the EPUB renderer.
    private var readingSample: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("SAVED ARTICLE").font(.system(size: 16, weight: .medium))
            Divider().overlay(.black)
            Text("A little time to read").font(.system(size: 30, weight: .bold, design: .serif))
            Text("Save an article when it catches your eye. Read it later on your reader, away from the busy screen.\n\nA few quiet minutes are enough to enjoy a good story. Choose a text size that feels comfortable, then keep reading at your own pace.\n\nYour saved articles will be waiting whenever you return.")
                .font(.system(size: CGFloat(22 + editor.reading.fontSize * 5), design: .serif))
                .lineSpacing(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            Divider().overlay(.black)
            Text("TEXT SIZE EXAMPLE").font(.system(size: 14))
        }
        .padding(30)
        .frame(width: 480, height: 800)
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

    private func renderSchematic() {
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
            HStack(alignment: .firstTextBaseline) {
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
