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
        let incoming = (reader?.profile ?? .defaults).withoutRetiredItems
        guard reader?.generation != baseGeneration || incoming != base else { return }
        if !isDirty || draft == incoming { draft = incoming }
        base = incoming
        baseGeneration = reader?.generation
    }

    func revert() { draft = base }
}

/// Home & Sleep editor, organized around the reader's two Pocket Daily screens.
/// Pick one and the canvas shows it drawn by the firmware painter with the
/// user's own cards and sample content (an outline when that renderer is
/// unavailable); the controls beside it (below when `stacked`) edit only that
/// screen. Its pages or sections are modules switched on and dragged into
/// order, and My cards live inside Home. Reader-wide settings sit underneath,
/// and one Apply sends everything that changed.
struct ProfileStudioView: View {
    @ObservedObject var model: PocketModel
    @ObservedObject var editor: ProfileEditorState
    var stacked = false
    /// Side by side in a fixed-height window: the controls scroll on their own.
    var scrollsControls = false
    @State private var preview: PreviewSurface = .home
    @State private var schematic: CGImage?
    @StateObject private var layout = LayoutPreviewModel()
    @StateObject private var cardPreview = ContentPreviewModel()
    @State private var cards: ContentEditorModel?
    @State private var cardsError: String?
    @State private var selectedCardID: String?
    @State private var editingCards: Bool
    @State private var showsReaderSettings = false
    @State private var drag: ReorderDrag?

    /// What the canvas draws. A card page belongs to Home: the selected card
    /// as the reader shows it when opened.
    enum PreviewSurface: String, CaseIterable { case home = "Home", card = "Card", sleep = "Sleep" }
    /// The screens the editor is organized around.
    enum Screen: String, CaseIterable { case home = "Home", sleep = "Sleep" }

    init(model: PocketModel, editor: ProfileEditorState, stacked: Bool = false, scrollsControls: Bool = false,
         initialPreview: PreviewSurface = .home) {
        self.model = model
        self.editor = editor
        self.stacked = stacked
        self.scrollsControls = scrollsControls && !stacked
        _preview = State(initialValue: initialPreview)
        _editingCards = State(initialValue: initialPreview == .card)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            applyBar
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
        .onAppear { editor.sync(with: model.readerProfile) }
        .onChange(of: model.readerProfile) { _, reader in editor.sync(with: reader) }
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
        if preview == .card { return cardPreview.image }
        return showsRender ? layout.image : schematic
    }

    private var canvas: some View {
        VStack(spacing: 10) {
            Picker("Screen", selection: Binding(get: { screen }, set: { preview = $0 == .home ? .home : .sleep })) {
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
            HStack(spacing: 10) {
                Label(canvasCaption, systemImage: showsRender ? "text.below.photo" : "square.dashed")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(preview == .card ? "The card as the reader draws it when opened." :
                          showsRender ? "Drawn by the reader's own layout code with your cards and sample content. Your reader shows its own books and weather." : "")
                    .accessibilityIdentifier("profile-canvas-caption")
                if preview == .card {
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
        if preview == .card, selectedCard == nil {
            Text("Add a card to see it here").font(.caption)
                .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        } else if preview == .card, cardPreview.image == nil, let error = cardPreview.error {
            Text(error).font(.caption).multilineTextAlignment(.center)
                .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(40)
        }
    }

    private var canvasIsCurrent: Bool {
        if preview == .card { return cardPreview.image != nil || cardRequest == nil }
        return layoutRequest == nil || layout.renderedRequest == layoutRequest
    }

    private var canvasLabel: String {
        switch preview {
        case .card: selectedCard.map { "Card \($0.title)" } ?? "No card"
        case .home, .sleep:
            showsRender ? "Pocket Daily \(preview.rawValue.lowercased()) with sample content"
                        : "Outline of the Pocket Daily \(preview.rawValue.lowercased()) layout"
        }
    }

    private var canvasCaption: String {
        if preview == .card { return "Card page" }
        if showsRender { return draftCards.cards.isEmpty ? "Sample content" : "Your cards · sample content" }
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
    private var anythingDirty: Bool { profileDirty || model.preferencesDirty || cardsDirty }

    private var status: (text: String, symbol: String, color: Color) {
        if model.isDemoMode { return ("Demo · nothing is sent", "info.circle", .secondary) }
        if model.readerStatus == nil { return ("Connect a reader to apply changes", "info.circle", .secondary) }
        if let error = editor.draft.validationError ?? cardsValidation { return (error, "exclamationmark.triangle", .red) }
        if case let .sending(step) = cardStatus { return ("\(step)…", "arrow.triangle.2.circlepath", .secondary) }
        if model.profileSend == .sending { return ("Applying on the reader…", "arrow.triangle.2.circlepath", .secondary) }
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
        if anythingDirty { return ("Changes not applied", "circle.dashed", .orange) }
        if case .storedNotShown = cardStatus { return (cardStatus.label, cardStatus.symbol, .orange) }
        if !model.canEditReaderProfile && editor.isDirty {
            return ("This reader's firmware can't store Home & Sleep yet", "exclamationmark.triangle", .orange)
        }
        // The reader redraws Home and Sleep from a saved profile only when it
        // next paints Pocket Daily, which is when Sync ends.
        if case .saved = model.profileSend {
            return (cardStatus == .shown ? "Applied · card on screen now, Home and Sleep when you leave Sync"
                                         : "Applied · Home and Sleep show when you leave Sync",
                    "checkmark.circle.fill", .green)
        }
        if cardStatus == .shown { return ("Applied · card shown on the reader", "checkmark.circle.fill", .green) }
        return ("Up to date with the reader", "checkmark.circle.fill", .green)
    }

    private var canApply: Bool {
        model.readerStatus != nil && !model.isDemoMode && !model.isWorking && anythingDirty &&
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
    }

    private var statusLabel: some View {
        Label(status.text, systemImage: status.symbol)
            .font(.callout)
            .foregroundStyle(status.color)
            .accessibilityIdentifier("profile-status")
    }

    @ViewBuilder private var applyControls: some View {
        Button("Revert") {
            editor.revert()
            model.revertPreferences()
        }
        .disabled(!(editor.isDirty || model.preferencesDirty) || model.isWorking)
        .help("Back to what the reader has. Your cards stay as they are.")
        .accessibilityIdentifier("profile-revert")
        Button("Apply") {
            model.sendReaderLayout(profile: profileDirty ? editor.draft : nil,
                                   cards: cardsDirty ? cardsRevision : nil)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canApply)
        .help("Apply to the reader (⌘↩). The reader stays in Sync.")
        .accessibilityIdentifier("profile-apply")
    }

    // MARK: Controls

    /// Writes one part of the draft and shows the surface it changes.
    private func edit<Value>(_ key: WritableKeyPath<PocketProfile, Value>, on surface: PreviewSurface) -> Binding<Value> {
        Binding(get: { editor.draft[keyPath: key] },
                set: { editor.draft[keyPath: key] = $0; preview = surface })
    }

    /// Reader settings (applied with the same Apply); shown once loaded.
    private func setting<Value>(_ get: @escaping (ReaderPreferences) -> Value,
                                _ set: @escaping (Value) -> Void, on surface: PreviewSurface? = nil) -> Binding<Value>? {
        guard let preferences = model.preferences else { return nil }
        return Binding(get: { get(model.preferences ?? preferences) },
                       set: { set($0); if let surface { preview = surface } })
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
            case .home: homeControls
            case .sleep: sleepControls
            }
            readerSettings
            Button("Reset to default layout") { editor.draft = .defaults }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(editor.draft == .defaults)
                .accessibilityIdentifier("profile-reset")
        }
        .font(.callout)
        .disabled(model.isWorking)
    }

    @ViewBuilder private var homeControls: some View {
        ControlGroup(title: "Home pages", note: "Drag to reorder · up to \(PocketProfile.maxHomeItems)") {
            ModuleList(selection: edit(\.home.items, on: .home), available: homeItems,
                       limit: PocketProfile.maxHomeItems, identifier: "profile-home", drag: $drag,
                       title: { $0.title }, detail: { $0.detail }) { item in
                if item == .study { cardsDisclosure }
            } expansion: { item in
                if item == .study, editingCards { cardsEditor }
            }
            if editor.draft.home.items.contains(.study), !editor.draft.home.items.contains(.word) {
                Toggle("Daily word when there are no cards", isOn: edit(\.home.dailyWord, on: .home))
                    .accessibilityIdentifier("profile-daily-word")
            }
        }
        ControlGroup(title: "Weather and events") {
            Picker("Weather panel", selection: edit(\.home.weather, on: .home)) {
                ForEach(PocketProfile.WeatherPanel.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("profile-weather")
            Toggle("Next event", isOn: edit(\.home.nextEvent, on: .home))
                .disabled(editor.draft.home.weather == .off)
                .accessibilityIdentifier("profile-next-event")
            GlanceControls(settings: model.glanceSettings, model: model)
        }
        if let startup = setting({ $0.startupApp == 1 }, model.setStartupPocketDaily, on: .home) {
            Toggle("Open Pocket Daily when the reader starts", isOn: startup)
                .accessibilityIdentifier("profile-startup")
        }
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
                    if section == .reading, editor.draft.sleep.sections.contains(.reading),
                       let cover = setting({ $0.pocketDailySleepCover }, model.setPocketDailySleepCover, on: .sleep) {
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
        if let timeout = setting({ $0.sleepTimeoutMinutes }, model.setSleepTimeout, on: .sleep) {
            // The reader accepts 1-30 minutes; 31 means it never sleeps on its own.
            Stepper(timeout.wrappedValue >= ReaderPreferences.neverSleepMinutes
                        ? "Never sleep on its own" : "Sleep after \(timeout.wrappedValue) min",
                    value: timeout, in: 1...ReaderPreferences.neverSleepMinutes)
                .accessibilityIdentifier("profile-sleep-timeout")
        }
    }

    /// Settings for the whole reader rather than one screen; folded by default.
    @ViewBuilder private var readerSettings: some View {
        if let preferences = model.preferences {
            DisclosureGroup(isExpanded: $showsReaderSettings) {
                VStack(alignment: .leading, spacing: 10) {
                    if let size = setting({ $0.fontSize }, model.setFontSize) {
                        LabeledContent("Text size") {
                            Picker("Text size", selection: size) {
                                Text("S").tag(0); Text("M").tag(1); Text("L").tag(2); Text("XL").tag(3)
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 200)
                        }
                        .accessibilityIdentifier("profile-text-size")
                    }
                    if preferences.hasButtonSettings,
                       let side = setting({ $0.sideButtons ?? .previousNext }, model.setSideButtons),
                       let follow = setting({ $0.frontButtonsFollowOrientation ?? false },
                                            model.setFrontButtonsFollowOrientation) {
                        LabeledContent("Side buttons") {
                            Picker("Side buttons", selection: side) {
                                ForEach(ReaderPreferences.SideButtons.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        .help("Page turns with the side buttons while reading")
                        .accessibilityIdentifier("profile-side-buttons")
                        Toggle("Front buttons follow screen rotation", isOn: follow)
                            .help("When the book is upside down or turned left, the front buttons swap to match")
                            .accessibilityIdentifier("profile-front-buttons")
                    } else {
                        Text("Button settings need a newer reader firmware.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Reader settings").font(.headline)
                    Text(readerSummary(preferences)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityIdentifier("profile-reader-settings")
        }
    }

    private func readerSummary(_ preferences: ReaderPreferences) -> String {
        let size = ["S", "M", "L", "XL"].indices.contains(preferences.fontSize)
            ? ["S", "M", "L", "XL"][preferences.fontSize] : "\(preferences.fontSize)"
        var parts = ["Text \(size)"]
        if let side = preferences.sideButtons { parts.append("Side: \(side.title.lowercased())") }
        return parts.joined(separator: " · ")
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
