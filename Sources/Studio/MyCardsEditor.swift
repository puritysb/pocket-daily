import SwiftUI
import UniformTypeIdentifiers

/// "My cards": up to three pages the user writes for the reader's Home (and the
/// first one for the sleep screen), each with an optional 1-bit image such as a
/// QR code. Edits autosave locally; sending is the Home & Sleep Send.
struct MyCardsEditor: View {
    @ObservedObject var editor: ContentEditorModel
    @ObservedObject var model: PocketModel
    @Binding var selectedID: String?
    /// Called when a card is edited, so the canvas can show it.
    let onEdit: () -> Void
    @Environment(\.undoManager) private var undoManager
    @State private var operationError: String?
    @State private var notice: String?
    @State private var lastRemoved: RemovedContentCard?
    @State private var choosingImage = false
    @State private var imageTask: Task<Void, Never>?
    @State private var qrRequest: ImageRequest?
    @State private var loadingReaderCards = false
    @State private var confirmingRecovery = false

    private var cards: [ContentCard] { editor.draft.cards }
    private var selectedIndex: Int? {
        cards.firstIndex { $0.id == selectedID } ?? (cards.isEmpty ? nil : 0)
    }
    private var locked: Bool { model.isDemoMode || editor.isDemo }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardStrip
            if let index = selectedIndex {
                fields(index)
            } else {
                Text("Write a short note, a question, or add a QR code. Cards appear as Home pages.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let removed = lastRemoved {
                HStack {
                    Label("Removed “\(removed.card.title.isEmpty ? "Untitled" : removed.card.title)”", systemImage: "trash")
                        .font(.caption)
                    Spacer()
                    Button("Undo") { restore(removed) }
                        .font(.caption)
                        .disabled(locked || editor.isBusy)
                        .accessibilityIdentifier("cards-undo-remove")
                }
                .padding(8)
                .background(PocketPalette.panel, in: RoundedRectangle(cornerRadius: 8))
            }
            footer
        }
        .task(id: AutosaveKey(draft: editor.draft, busy: editor.isBusy)) { await autosave() }
        .onDisappear {
            imageTask?.cancel()
            if let id = editor.pendingImport?.id { editor.cancelImport(id: id) }
        }
        .modifier(TransferFilePicker(isPresented: $choosingImage,
                                    allowedContentTypes: [.image, UTType(filenameExtension: "pbm") ?? .data]) { result in
            guard let cardID = selectedIndex.map({ cards[$0].id }) else { return }
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                imageTask = Task {
                    do { try await editor.importImage(from: url, cardID: cardID); operationError = nil; onEdit() }
                    catch is CancellationError { }
                    catch { operationError = error.localizedDescription }
                }
            case let .failure(error): operationError = error.localizedDescription
            }
        })
        .sheet(item: $qrRequest) { request in
            CardImageSheet(kind: request.kind) { imported in
                do {
                    try editor.attachImage(imported, cardID: request.cardID)
                    operationError = nil
                    onEdit()
                } catch { operationError = error.localizedDescription }
            }
        }
        // Replacing every card goes through a side-by-side review.
        .sheet(item: Binding(get: { editor.pendingImport }, set: { value in
            if value == nil, let id = editor.pendingImport?.id { editor.cancelImport(id: id) }
        })) { proposal in
            ContentImportReview(proposal: proposal, error: nil, cancel: {
                editor.cancelImport(id: proposal.id)
            }, confirm: {
                guard !locked, !model.isWorking else { return }
                do { try editor.confirmImport(id: proposal.id); selectedID = nil; onEdit() }
                catch { operationError = error.localizedDescription }
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

    // MARK: Cards

    private var cardStrip: some View {
        HStack(spacing: 8) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                Button {
                    selectedID = card.id
                    onEdit()
                } label: {
                    Text("\(index + 1) · \(card.title.isEmpty ? "Untitled" : card.title)")
                        .lineLimit(1)
                        .frame(maxWidth: 120)
                }
                .buttonStyle(.bordered)
                .tint(index == selectedIndex ? .accentColor : .secondary)
                .accessibilityIdentifier("cards-card-\(index)")
            }
            Button {
                addCard()
            } label: {
                Label("Add card", systemImage: "plus")
            }
            .labelStyle(cards.isEmpty ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
            .buttonStyle(.bordered)
            .disabled(cards.count >= 3 || editor.isBusy)
            .help(cards.count >= 3 ? "Up to three cards" : "Add card")
            .accessibilityIdentifier("cards-add")
        }
    }

    @ViewBuilder private func fields(_ index: Int) -> some View {
        TextField("Title", text: field(index, \.title))
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("cards-title")
        TextField("Text", text: field(index, \.question), axis: .vertical)
            .lineLimit(2...6)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("cards-text")
        TextField("Note (optional)", text: field(index, \.context), axis: .vertical)
            .lineLimit(1...3)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("cards-note")
        Text("Title \(cards[index].title.utf8.count)/24 · Text \(cards[index].question.utf8.count)/160 bytes")
            .font(.caption2).foregroundStyle(.secondary)
        imageControls(cards[index])
        HStack {
            Button { move(index, by: -1) } label: { Image(systemName: "arrow.left") }
                .disabled(index == 0)
                .help("Earlier page")
            Button { move(index, by: 1) } label: { Image(systemName: "arrow.right") }
                .disabled(index + 1 >= cards.count)
                .help("Later page")
            Spacer()
            Button("Remove card", role: .destructive) { remove(index) }
                .accessibilityIdentifier("cards-remove")
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    @ViewBuilder private func imageControls(_ card: ContentCard) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let data = editor.draft.images[card.imagePath] {
                ContentImagePreview(data: data, showsCaption: false)
                    .frame(maxWidth: 88, maxHeight: 88)
            }
            VStack(alignment: .leading, spacing: 6) {
                Menu {
                    Button("QR code from text or link…", systemImage: "qrcode") {
                        qrRequest = .init(kind: .qrCode, cardID: card.id)
                    }
                    Button("Image from a link…", systemImage: "link") {
                        qrRequest = .init(kind: .link, cardID: card.id)
                    }
                    Button("Choose an image file…", systemImage: "photo") { choosingImage = true }
                } label: {
                    Label(card.imagePath.isEmpty ? "Add image or QR code" : "Replace image", systemImage: "qrcode")
                }
                .fixedSize()
                .accessibilityIdentifier("cards-image-menu")
                if !card.imagePath.isEmpty {
                    Picker("Layout", selection: layoutBinding) {
                        ForEach(ContentCard.Layout.allCases, id: \.rawValue) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    .help("Where the image sits when the card is opened on the reader")
                    Button("Remove image", role: .destructive) {
                        do { try editor.removeImage(cardID: card.id); operationError = nil; onEdit() }
                        catch { operationError = error.localizedDescription }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
        .disabled(editor.isBusy)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = operationError ?? editor.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
                if editor.lastError != nil && !locked {
                    Button("Preserve saved file and recover…") { confirmingRecovery = true }
                        .font(.caption).disabled(editor.isBusy)
                }
            }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text(draftStateLabel).accessibilityIdentifier("cards-draft-state")
                Spacer()
                if model.canLoadReaderCards {
                    Button {
                        loadReaderCards()
                    } label: {
                        Label(loadingReaderCards ? "Loading…" : "Load from reader", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(loadingReaderCards || editor.isBusy || model.isWorking || locked)
                    .help("Brings the cards the reader has now into this editor for review. The reader is not changed.")
                    .accessibilityIdentifier("cards-load-reader")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let backup = editor.recoveryBackup {
                Text("Previous saved cards preserved: \(backup.lastPathComponent)")
                    .font(.caption2).textSelection(.enabled)
            }
        }
    }

    private var draftStateLabel: String {
        if locked { return "Demo · cards are not saved" }
        if editor.isBusy { return "Saving…" }
        return editor.hasUnsavedChanges ? "Saving shortly" : "Saved on this device"
    }

    // MARK: Actions

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
        onEdit()
    }

    private func move(_ index: Int, by offset: Int) {
        var draft = editor.draft
        let target = index + offset
        guard draft.cards.indices.contains(index), draft.cards.indices.contains(target) else { return }
        draft.cards.swapAt(index, target)
        editor.edit(draft)
        onEdit()
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

    /// Read-only: the verified set opens in the review above.
    private func loadReaderCards() {
        guard !locked else { return }
        operationError = nil
        notice = nil
        let device = model.readerStatus?.device ?? "the reader"
        loadingReaderCards = model.loadReaderCards { result in
            loadingReaderCards = false
            switch result {
            case .success(nil):
                notice = "\(device) has no cards from this app."
            case let .success(draft?):
                if draft == editor.draft {
                    notice = "These cards already match \(device)."
                    return
                }
                do { try editor.prepareImport(draft, sourceName: "Cards on \(device)") }
                catch { operationError = error.localizedDescription }
            case let .failure(error):
                operationError = error.localizedDescription
            }
        }
    }

    private var layoutBinding: Binding<ContentCard.Layout> {
        Binding(get: { selectedIndex.map { cards[$0].layout } ?? .textFirst },
                set: { value in
                    guard let index = selectedIndex else { return }
                    var draft = editor.draft
                    draft.cards[index].layout = value
                    editor.edit(draft)
                    onEdit()
                })
    }

    private func field(_ index: Int, _ key: WritableKeyPath<ContentCard, String>) -> Binding<String> {
        Binding(get: { editor.draft.cards.indices.contains(index) ? editor.draft.cards[index][keyPath: key] : "" },
                set: { value in
                    var draft = editor.draft
                    guard draft.cards.indices.contains(index) else { return }
                    draft.cards[index][keyPath: key] = value
                    editor.edit(draft)
                    onEdit()
                })
    }

    static func describe(_ error: Error) -> String {
        if let invalid = error as? ContentCard.ValidationError {
            switch invalid {
            case .identifier: return "Each card needs a unique ID."
            case let .text(field, maximumBytes):
                return "Check the card \(field == "question" ? "text" : field): up to \(maximumBytes) bytes; title and text are required."
            case .imagePath: return "A card image is invalid."
            }
        }
        return "Check the cards and images before sending."
    }

    struct ImageRequest: Identifiable {
        enum Kind { case qrCode, link }
        let id = UUID()
        let kind: Kind
        let cardID: String
    }
}

/// Makes a card image from text (as a QR code) or from an image link.
private struct CardImageSheet: View {
    let kind: MyCardsEditor.ImageRequest.Kind
    let attach: (ContentImageImport.Imported) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result: ContentImageImport.Imported?
    @State private var error: String?
    @State private var loading = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(kind == .qrCode ? "Text or link, e.g. https://example.com" : "https://… link to an image",
                              text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(kind == .qrCode ? .default : .URL)
#endif
                        .accessibilityIdentifier("card-image-input")
                } footer: {
                    Text(kind == .qrCode
                         ? "Encoded on this device. Links, Wi-Fi details or contact text all work; up to \(ContentQRCode.maximumBytes) bytes."
                         : "For a service that returns a QR code or picture as an image. The image is fetched once over HTTPS and stored with the card.")
                }
                Section {
                    if let result {
                        ContentImagePreview(data: result.data)
                            .frame(maxWidth: 200, maxHeight: 220)
                            .frame(maxWidth: .infinity)
                    } else if loading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if let error {
                        Text(error).foregroundStyle(.red).font(.callout)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(kind == .qrCode ? "QR code" : "Image from a link")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add to card") {
                        guard let result else { return }
                        attach(result)
                        dismiss()
                    }
                    .disabled(result == nil)
                    .accessibilityIdentifier("card-image-add")
                }
            }
            .task(id: text) { await refresh() }
            .onDisappear { task?.cancel() }
        }
        .frame(minWidth: 380, minHeight: 420)
    }

    /// QR codes redraw as you type; links load after a short pause.
    private func refresh() async {
        result = nil
        error = nil
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        switch kind {
        case .qrCode:
            do { result = try ContentQRCode.image(for: value) } catch { self.error = error.localizedDescription }
        case .link:
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard let url = URL(string: value) else {
                error = ContentImageImport.RemoteFailure.scheme.localizedDescription
                return
            }
            loading = true
            defer { loading = false }
            do { result = try await ContentImageImport.load(remote: url) }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// Type-erased label style so one control can switch between styles.
private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<Style: LabelStyle>(_ style: Style) { make = { AnyView(Label($0).labelStyle(style)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
