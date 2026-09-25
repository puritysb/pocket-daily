import SwiftUI
import UniformTypeIdentifiers

/// Card studio on every platform: the reader-sized canvas is the editing
/// surface. One explicit Send to reader (each send refreshes e-ink), optional
/// auto-send for the current reader session, and automatic local draft
/// saving. Storage activation and the redraw receipt remain separate facts
/// (ContentSendStatus). `stacked` puts the fields below the canvas.
struct ContentStudioView: View {
    @ObservedObject var model: PocketModel
    var stacked = false
    @State private var editor: ContentEditorModel?
    @State private var loadError: String?
    @State private var confirmingRecovery = false
    @State private var recovering = false

    var body: some View {
        Group {
            if let editor {
                ContentStudioWorkspace(editor: editor, model: model, stacked: stacked)
            } else if let loadError {
                VStack(alignment: .leading, spacing: 12) {
                    Label("The local card draft could not be loaded.", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(loadError).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Retry loading") { Task { await open() } }
                        if !model.isDemoMode {
                            Button("Preserve saved file and start fresh…") { confirmingRecovery = true }
                        }
                    }
                }
                .disabled(recovering)
                .frame(maxWidth: 560, alignment: .leading)
            } else {
                ProgressView("Loading local draft…")
            }
        }
        .task(id: model.isDemoMode) { await open() }
        // Data-loss guard for an error-only path; ordinary editing has no dialogs.
        .confirmationDialog("Recover the local draft?", isPresented: $confirmingRecovery, titleVisibility: .visible) {
            Button("Preserve file and recover") { Task { await recover() } }
        } message: {
            Text("The saved file is kept as a separate backup and editing starts from an empty draft. Nothing is sent to a reader.")
        }
    }

    @MainActor private func open() async {
        editor = nil
        await model.restorePendingContentActivation()
        do {
            let candidate = try model.contentEditorModel()
            if !model.isDemoMode && !candidate.hasLoaded { try await candidate.load() }
            // Demo shows a card on the canvas; it lives only in this in-memory editor.
            if candidate.isDemo && candidate.draft.cards.isEmpty { candidate.edit(Self.demoDraft) }
            editor = candidate
            loadError = nil
        } catch { loadError = error.localizedDescription }
    }

    static let demoDraft = ContentDraft(cards: [
        ContentCard(id: "demo-card-1", title: "Today's question",
                    question: "What is one thing from yesterday's reading you want to remember?",
                    context: "Demo cards are never saved or sent."),
    ])

    @MainActor private func recover() async {
        guard !model.isDemoMode, !recovering else { return }
        recovering = true
        defer { recovering = false }
        do {
            let candidate = try model.contentEditorModel()
            try await candidate.recoverKeepingEdits()
            editor = candidate
            loadError = nil
        } catch { loadError = error.localizedDescription }
    }
}

private struct ContentStudioWorkspace: View {
    @ObservedObject var editor: ContentEditorModel
    @ObservedObject var model: PocketModel
    let stacked: Bool
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var preview = ContentPreviewModel()
    @StateObject private var autoSend = ContentLiveApply()
    @State private var selectedID: String?
    @State private var orientation = HostRendererBridge.Orientation.portrait
    @State private var revision: ContentRevision?
    @State private var validation: String?
    @State private var autoSendSession: PocketModel.ContentEditingSession?
    @State private var operationError: String?
    @State private var confirmingRecovery = false
    @State private var choosingImage = false
    @State private var imageTask: Task<Void, Never>?
    @State private var choosingDraft = false
    @State private var exportingDraft = false
    @State private var exportDocument: ContentDraftDocument?
    @State private var importTask: Task<Void, Never>?
    @State private var importError: String?
    @State private var lastRemoved: RemovedContentCard?
    @State private var loadingReaderCards = false
    @State private var readerCardsNotice: String?
    @Environment(\.undoManager) private var undoManager

    private var cards: [ContentCard] { editor.draft.cards }
    private var selectedIndex: Int? {
        cards.firstIndex { $0.id == selectedID } ?? (cards.isEmpty ? nil : 0)
    }
    private var selectedCard: ContentCard? { selectedIndex.map { cards[$0] } }
    private var locked: Bool { model.isDemoMode || editor.isDemo }

    private var status: ContentSendStatus {
        ContentSendStatus.evaluate(.init(
            isDemo: model.isDemoMode,
            connected: model.readerStatus != nil,
            canPresent: model.contentEditingSession != nil,
            validation: validation,
            cardCount: cards.count,
            draftRevision: revision?.revision,
            phase: model.contentDeployment?.phase,
            redrawConfirmed: model.contentRedrawReceipt,
            busy: model.isWorking))
    }

    private var previewStyle: PreviewStyle {
        model.readerDisplay.map(PreviewStyle.init(reader:)) ?? .reference
    }

    private var previewRequest: ContentPreviewRequest {
        .init(card: selectedCard, image: selectedCard.flatMap { editor.draft.images[$0.imagePath] },
              hardware: model.hardware, orientation: orientation, style: previewStyle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sendBar
            let columns = stacked ? AnyLayout(VStackLayout(alignment: .center, spacing: 20))
                                  : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
            columns {
                VStack(spacing: 10) {
                    canvasToolbar
                    PocketDevicePreview(hardware: model.hardware, status: model.readerStatus,
                                        screenImageData: nil, renderedScreen: preview.image)
                        .frame(maxWidth: 340)
                        .frame(height: 470)
                        .overlay { canvasOverlay }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(preview.image == nil ? "Reader preview is rendering" : "Reader preview of the selected card")
                        .accessibilityIdentifier("studio-canvas")
                    Label(previewStyle.caption, systemImage: previewStyle.source == .reference ? "info.circle" : "checkmark.seal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("studio-preview-source")
                    cardStrip
                }
                .frame(width: stacked ? nil : 340)
                cardFields
                    .frame(maxWidth: stacked ? .infinity : 340, alignment: .topLeading)
            }
        }
        .task(id: previewRequest) { await preview.update(previewRequest) }
        .task(id: editor.draft) { refreshRevision() }
        .task(id: AutosaveKey(draft: editor.draft, busy: editor.isBusy)) { await autosave() }
        .onDisappear {
            autoSend.stop()
            preview.cancel()
            imageTask?.cancel()
            importTask?.cancel()
        }
        .onChange(of: model.contentEditingSession) { _, session in
            if autoSend.isEnabled && session != autoSendSession {
                autoSend.stop(message: "Auto-send stopped because the reader session changed.")
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { autoSend.stop() } }
        .onChange(of: choosingDraft) { _, choosing in if choosing { autoSend.stop() } }
        .modifier(TransferFilePicker(isPresented: $choosingImage,
                                    allowedContentTypes: [.image, UTType(filenameExtension: "pbm") ?? .data]) { result in
            guard let cardID = selectedCard?.id else { return }
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                imageTask = Task {
                    do { try await editor.importImage(from: url, cardID: cardID); operationError = nil }
                    catch is CancellationError { }
                    catch { operationError = error.localizedDescription }
                }
            case let .failure(error): operationError = error.localizedDescription
            }
        })
        .modifier(TransferFilePicker(isPresented: $choosingDraft, allowedContentTypes: [.json]) { result in
            guard !locked, !model.isWorking else { return }
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                importError = nil
                importTask = Task {
                    do { try await editor.prepareImport(from: url); operationError = nil }
                    catch is CancellationError { }
                    catch { operationError = error.localizedDescription }
                }
            case let .failure(error): operationError = error.localizedDescription
            }
        })
        .fileExporter(isPresented: $exportingDraft, document: exportDocument, contentType: .json,
                      defaultFilename: "Pocket Daily cards") { result in
            if case let .failure(error) = result, (error as? CocoaError)?.code != .userCancelled {
                operationError = error.localizedDescription
            }
            exportDocument = nil
        }
        // Import replaces every card in memory, so its side-by-side review stays.
        .sheet(item: Binding(get: { editor.pendingImport }, set: { value in
            if value == nil, let id = editor.pendingImport?.id { editor.cancelImport(id: id) }
        })) { proposal in
            ContentImportReview(proposal: proposal, error: importError, cancel: {
                editor.cancelImport(id: proposal.id)
            }, confirm: {
                guard !locked, !model.isWorking else { return }
                do { try editor.confirmImport(id: proposal.id); importError = nil; selectedID = nil }
                catch { importError = error.localizedDescription }
            })
        }
        .confirmationDialog("Recover using these edits?", isPresented: $confirmingRecovery, titleVisibility: .visible) {
            Button("Preserve file and save these edits") {
                Task {
                    do { try await editor.recoverKeepingEdits(); operationError = nil }
                    catch { operationError = error.localizedDescription }
                }
            }
        } message: {
            Text("The current saved file is preserved as a separate backup before these edits replace it. Nothing is sent to a reader.")
        }
    }

    // MARK: Send bar

    private var sendBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            // One line when it fits; otherwise the status above the controls.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    statusLabel.lineLimit(1)
                    Spacer(minLength: 8)
                    sendControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    statusLabel
                    HStack(spacing: 12) {
                        Spacer()
                        sendControls
                    }
                }
            }
            if autoSend.isEnabled {
                Text(autoSend.message).font(.caption).foregroundStyle(.secondary)
            }
            if case .needsCheck = status, let deployment = model.contentDeployment {
                ContentDeploymentStatus(deployment: deployment, model: model)
            }
            if let error = operationError ?? editor.lastError {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red)
                    if editor.lastError != nil && !locked {
                        Button("Preserve saved file and recover…") { confirmingRecovery = true }
                            .font(.caption).disabled(editor.isBusy)
                    }
                }
            } else if case .failed = status {
                Text(model.message).font(.caption).foregroundStyle(.secondary)
            } else if case .storedNotShown = status {
                Text(model.message).font(.caption).foregroundStyle(.secondary)
            }
            ContentJournalRecovery(model: model)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(PocketPalette.panel, in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusLabel: some View {
        Label(status.label, systemImage: status.symbol)
            .font(.callout)
            .foregroundStyle(statusColor)
            .accessibilityIdentifier("studio-status")
    }

    @ViewBuilder private var sendControls: some View {
        Toggle("Auto", isOn: Binding(get: { autoSend.isEnabled }, set: setAutoSend))
            .toggleStyle(.switch)
            .fixedSize()
            .disabled(!autoSend.isEnabled && (model.contentEditingSession == nil || revision == nil || model.isWorking))
            .help("Auto-send: sends each change after you pause typing. Every send refreshes the e-ink screen.")
            .accessibilityLabel("Auto-send")
            .accessibilityIdentifier("studio-auto-send")
        Button {
            send()
        } label: {
            Label("Send", systemImage: "paperplane.fill")
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
        .help("Send to reader (⌘↩)")
        .disabled(!ContentSendStatus.canSend(status, busy: model.isWorking || editor.isBusy,
                                            autoSend: autoSend.isEnabled) || revision == nil)
        .accessibilityIdentifier("studio-send")
    }

    private var statusColor: Color {
        switch status {
        case .shown: .green
        case .failed, .invalid: .red
        case .storedNotShown, .needsCheck, .unsupported, .changed: .orange
        default: .secondary
        }
    }

    // MARK: Canvas

    private var canvasToolbar: some View {
        HStack {
            Picker("Layout", selection: layoutBinding) {
                ForEach(ContentCard.Layout.allCases, id: \.rawValue) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(selectedIndex == nil || editor.isBusy)
            .help("Image layouts apply when a card has an image and need a layout-capable reader.")
            .accessibilityIdentifier("studio-layout")
            Menu {
                Picker("Orientation", selection: $orientation) {
                    Text("Portrait").tag(HostRendererBridge.Orientation.portrait)
                    Text("Clockwise").tag(HostRendererBridge.Orientation.clockwise)
                    Text("Inverted").tag(HostRendererBridge.Orientation.inverted)
                    Text("Counterclockwise").tag(HostRendererBridge.Orientation.counterclockwise)
                }
            } label: {
                Image(systemName: "rotate.right")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(previewStyle.orientation != nil)
            .help(previewStyle.orientation != nil ? "Using the reader's orientation" : "Preview orientation")
        }
    }

    @ViewBuilder private var canvasOverlay: some View {
        if preview.image == nil, let error = preview.error {
            Text(error).font(.caption).multilineTextAlignment(.center)
                .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(40)
        } else if preview.image == nil, preview.isRendering {
            ProgressView()
        }
    }

    private var cardStrip: some View {
        HStack(spacing: 8) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                Button {
                    selectedID = card.id
                } label: {
                    Text("\(index + 1) · \(card.title.isEmpty ? "Untitled" : card.title)")
                        .lineLimit(1)
                        .frame(maxWidth: 110)
                }
                .buttonStyle(.bordered)
                .tint(index == selectedIndex ? .accentColor : .secondary)
                .accessibilityIdentifier("studio-card-\(index)")
            }
            Button {
                addCard()
            } label: {
                Label("Add card", systemImage: "plus")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .disabled(cards.count >= 3 || editor.isBusy)
            .help(cards.count >= 3 ? "Up to three cards" : "Add card")
            .accessibilityIdentifier("studio-add-card")
        }
    }

    // MARK: Fields

    @ViewBuilder private var cardFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let index = selectedIndex {
                Text("Card \(index + 1)").font(.headline)
                TextField("Title", text: field(index, \.title))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("studio-title")
                TextField("Text", text: field(index, \.question), axis: .vertical)
                    .lineLimit(3...7)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("studio-text")
                TextField("Context (optional)", text: field(index, \.context), axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("studio-context")
                Text("Title \(cards[index].title.utf8.count)/24 · Text \(cards[index].question.utf8.count)/160 bytes")
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("studio-byte-count")
                imageControls(cards[index])
                HStack {
                    Button("Move earlier") { move(index, by: -1) }.disabled(index == 0)
                    Button("Move later") { move(index, by: 1) }.disabled(index + 1 >= cards.count)
                    Spacer()
                    Button("Remove card", role: .destructive) { remove(index) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else {
                Text("No cards yet").font(.headline)
                Button("Add card") { addCard() }
                    .buttonStyle(.bordered)
                    .disabled(editor.isBusy)
            }
            if let removed = lastRemoved {
                HStack {
                    Label("Removed “\(removed.card.title.isEmpty ? "Untitled" : removed.card.title)”", systemImage: "trash")
                        .font(.caption)
                    Spacer()
                    Button("Undo") { restore(removed) }
                        .font(.caption)
                        .disabled(locked || editor.isBusy)
                        .accessibilityIdentifier("studio-undo-remove")
                }
                .padding(8)
                .background(PocketPalette.panel, in: RoundedRectangle(cornerRadius: 8))
            }
            Divider().padding(.vertical, 4)
            draftFooter
        }
        .disabled(model.isWorking && !autoSend.isEnabled)
    }

    private var draftFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(draftStateLabel).font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("studio-draft-state")
            if model.canLoadReaderCards {
                Button {
                    loadReaderCards()
                } label: {
                    if loadingReaderCards {
                        Label("Loading cards from the reader…", systemImage: "arrow.down.circle")
                    } else {
                        Label("Load cards from the reader…", systemImage: "arrow.down.circle")
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(loadingReaderCards || editor.isBusy || model.isWorking || autoSend.isEnabled)
                .help("Brings the cards the reader shows now into this editor for review. The reader is not changed.")
                .accessibilityIdentifier("studio-load-reader")
            }
            if let readerCardsNotice {
                Text(readerCardsNotice).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Import cards…") {
                    guard !locked, !model.isWorking else { return }
                    importError = nil
                    #if DEBUG
                    if let raw = ProcessInfo.processInfo.environment["POCKET_UI_TEST_CONTENT_FILES_ID"],
                       let id = UUID(uuidString: raw) {
                        importTask = Task {
                            do { try await editor.prepareImport(from: ContentDraftUITestFiles.importFixture(id)); operationError = nil }
                            catch is CancellationError { }
                            catch { operationError = error.localizedDescription }
                        }
                        return
                    }
                    #endif
                    choosingDraft = true
                }
                .accessibilityIdentifier("studio-import")
                Button("Export cards…") {
                    do { exportDocument = try editor.exportDocument(); exportingDraft = true; operationError = nil }
                    catch { operationError = error.localizedDescription }
                }
                .accessibilityIdentifier("studio-export")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .disabled(locked || editor.isBusy || model.isWorking)
            if let backup = editor.recoveryBackup {
                Text("Previous saved draft preserved: \(backup.lastPathComponent)")
                    .font(.caption2).textSelection(.enabled)
            }
        }
    }

    private var draftStateLabel: String {
        if locked { return "Demo · edits are not saved" }
        if editor.isBusy { return "Saving…" }
        return editor.hasUnsavedChanges ? "Unsaved edits · saving shortly" : "Saved on this device"
    }

    @ViewBuilder private func imageControls(_ card: ContentCard) -> some View {
        if let data = editor.draft.images[card.imagePath] {
            ContentImagePreview(data: data)
        }
        HStack {
            Button(card.imagePath.isEmpty ? "Add image…" : "Replace image…") { choosingImage = true }
            if !card.imagePath.isEmpty {
                Button("Remove image", role: .destructive) {
                    do { try editor.removeImage(cardID: card.id); operationError = nil }
                    catch { operationError = error.localizedDescription }
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .disabled(editor.isBusy)
    }

    // MARK: Actions

    /// Read-only: the verified set opens in the same review as a file import.
    private func loadReaderCards() {
        guard !locked else { return }
        operationError = nil
        readerCardsNotice = nil
        let device = model.readerStatus?.device ?? "the reader"
        loadingReaderCards = model.loadReaderCards { result in
            loadingReaderCards = false
            switch result {
            case .success(nil):
                readerCardsNotice = "\(device) has no cards from this app."
            case let .success(draft?):
                if draft == editor.draft {
                    readerCardsNotice = "This editor already matches the cards on \(device)."
                    return
                }
                do { try editor.prepareImport(draft, sourceName: "Cards on \(device)") }
                catch { operationError = error.localizedDescription }
            case let .failure(error):
                operationError = error.localizedDescription
            }
        }
    }

    private func send() {
        guard let revision, !autoSend.isEnabled else { return }
        operationError = nil
        model.applyContent(revision)
    }

    private func setAutoSend(_ enabled: Bool) {
        guard enabled else { autoSend.stop(); return }
        guard !model.isWorking, let session = model.contentEditingSession, let revision else { return }
        autoSendSession = session
        autoSend.start(revision: revision) { revision in
            await model.applyLiveContent(revision, session: session)
        }
    }

    private func refreshRevision() {
        do {
            let snapshot = try editor.deploymentSnapshot()
            revision = snapshot
            validation = nil
            autoSend.update(snapshot)
        } catch {
            revision = nil
            validation = Self.describe(error)
            autoSend.update(nil)
        }
    }

    private struct AutosaveKey: Equatable {
        let draft: ContentDraft
        let busy: Bool
    }

    /// Local persistence only; never opens a connection. Waits for typing to pause.
    private func autosave() async {
        guard !locked, !editor.isBusy, editor.hasLoaded, editor.hasUnsavedChanges, editor.lastError == nil else { return }
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard !editor.isBusy, editor.hasUnsavedChanges else { return }
        do { try await editor.save() } catch { /* lastError drives the recovery affordance */ }
    }

    private func addCard() {
        guard cards.count < 3 else { return }
        var draft = editor.draft
        let id = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(32))
        draft.cards.append(.init(id: id, title: "", question: ""))
        editor.edit(draft)
        selectedID = id
    }

    private func move(_ index: Int, by offset: Int) {
        var draft = editor.draft
        let target = index + offset
        guard draft.cards.indices.contains(index), draft.cards.indices.contains(target) else { return }
        draft.cards.swapAt(index, target)
        editor.edit(draft)
    }

    /// Deleting is autosaved, so it is always undoable: inline and with ⌘Z.
    private func remove(_ index: Int) {
        guard let (draft, removed) = editor.draft.removingCard(at: index) else { return }
        editor.edit(draft)
        selectedID = draft.cards.isEmpty ? nil : draft.cards[min(index, draft.cards.count - 1)].id
        lastRemoved = removed
        undoManager?.registerUndo(withTarget: editor) { _ in
            Task { @MainActor in restore(removed) }
        }
        undoManager?.setActionName("Remove Card")
    }

    private func restore(_ removed: RemovedContentCard) {
        guard let draft = editor.draft.restoring(removed) else {
            operationError = "The removed card cannot be restored: the card limit is reached or its ID is in use."
            return
        }
        editor.edit(draft)
        selectedID = removed.card.id
        if lastRemoved == removed { lastRemoved = nil }
    }

    private var layoutBinding: Binding<ContentCard.Layout> {
        Binding(get: { selectedCard?.layout ?? .textFirst },
                set: { value in
                    guard let index = selectedIndex else { return }
                    var draft = editor.draft
                    draft.cards[index].layout = value
                    editor.edit(draft)
                })
    }

    private func field(_ index: Int, _ key: WritableKeyPath<ContentCard, String>) -> Binding<String> {
        Binding(get: { editor.draft.cards.indices.contains(index) ? editor.draft.cards[index][keyPath: key] : "" },
                set: { value in
                    var draft = editor.draft
                    guard draft.cards.indices.contains(index) else { return }
                    draft.cards[index][keyPath: key] = value
                    editor.edit(draft)
                })
    }

    static func describe(_ error: Error) -> String {
        if let invalid = error as? ContentCard.ValidationError {
            switch invalid {
            case .identifier: return "Each card needs a unique ID."
            case let .text(field, maximumBytes): return "Check \(field): up to \(maximumBytes) bytes; title and text are required."
            case .imagePath: return "The card image path is invalid."
            }
        }
        return "Check the cards, images and limits before sending."
    }
}
