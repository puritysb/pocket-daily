import SwiftUI
import UniformTypeIdentifiers

struct ContentEditorSheet: View {
    @ObservedObject var model: PocketModel
    @Environment(\.dismiss) private var dismiss
    @State private var editor: ContentEditorModel?
    @State private var loadError: String?
    @State private var confirmingRecovery = false
    @State private var recovering = false

    var body: some View {
        NavigationStack {
            Group {
                if let editor {
                    ContentEditorForm(editor: editor, model: model)
                } else if let loadError {
                    VStack(spacing: 16) {
                        Text(loadError)
                        Button("Retry loading") { Task { await open() } }
                        if !model.isDemoMode {
                            Button("Preserve saved file and recover…") { confirmingRecovery = true }
                        }
                    }.padding().disabled(recovering)
                } else {
                    ProgressView("Loading local draft…")
                }
            }
            .navigationTitle("Content cards")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 320, idealWidth: 560, minHeight: 420, idealHeight: 640)
        .task { await open() }
        .confirmationDialog("Recover the local draft?", isPresented: $confirmingRecovery, titleVisibility: .visible) {
            Button("Preserve file and recover") { Task { await recover() } }
        } message: {
            Text("The saved file will be kept as a separate backup. Current in-memory edits will become the saved draft, or an empty draft if none were loaded. Nothing is sent to a reader.")
        }
    }

    @MainActor private func open() async {
        await model.restorePendingContentActivation()
        do {
            let candidate = try model.contentEditorModel()
            if !model.isDemoMode && !candidate.hasLoaded { try await candidate.load() }
            editor = candidate
            loadError = nil
        } catch { loadError = error.localizedDescription }
    }

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

private struct ContentEditorForm: View {
    @ObservedObject var editor: ContentEditorModel
    @ObservedObject var model: PocketModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var liveApply = ContentLiveApply()
    @State private var confirmingLiveApply = false
    @State private var liveSession: PocketModel.ContentEditingSession?
    @State private var operationError: String?
    @State private var confirmingApply = false
    @State private var choosingImage = false
    @State private var imageCardID: String?
    @State private var imageTask: Task<Void, Never>?
    @State private var confirmingRecovery = false
    @State private var choosingDraft = false
    @State private var exportingDraft = false
    @State private var exportDocument: ContentDraftDocument?
    @State private var importTask: Task<Void, Never>?
    @State private var importError: String?

    private var validation: String? {
        do { _ = try editor.deploymentSnapshot(); return nil }
        catch let error as ContentCard.ValidationError {
            switch error {
            case .identifier: return "Each card needs a unique lowercase ID."
            case let .text(field, maximumBytes): return "Check \(field): maximum \(maximumBytes) UTF-8 bytes; title and text are required."
            case .imagePath: return "The card image path is invalid."
            }
        } catch { return "Check card IDs, image references and content limits before applying." }
    }

    var body: some View {
        Form {
            Section {
                Text(model.isDemoMode ? "Local demo · saving and device changes disabled" :
                     "Edit up to three cards offline. Save keeps a local draft; Apply changes the selected reader without flashing firmware.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(editor.draft.cards.indices, id: \.self) { index in
                    Section("Card \(index + 1)") {
                        TextField("Title", text: field(index, \.title))
                            .accessibilityIdentifier("content-title-\(index)")
                        TextField("Text", text: field(index, \.question), axis: .vertical)
                            .lineLimit(2...5).accessibilityIdentifier("content-text-\(index)")
                        TextField("Context (optional)", text: field(index, \.context), axis: .vertical)
                            .lineLimit(1...4)
                        Text("Title \(editor.draft.cards[index].title.utf8.count)/24 bytes · Text \(editor.draft.cards[index].question.utf8.count)/160 bytes")
                            .font(.caption2).foregroundStyle(.secondary)
                        imageControls(editor.draft.cards[index])
                        Picker("Card layout", selection: Binding(
                            get: { editor.draft.cards[index].layout },
                            set: { value in
                                var draft = editor.draft
                                draft.cards[index].layout = value
                                editor.edit(draft)
                            })) {
                            ForEach(ContentCard.Layout.allCases, id: \.rawValue) { layout in
                                Text(layout.title).tag(layout)
                            }
                        }
                        .accessibilityIdentifier("content-layout-\(index)")
                        Text("Title and navigation stay fixed. Image layouts apply when a card has an image and require a layout-capable reader.")
                            .font(.caption2).foregroundStyle(.secondary)
                        HStack {
                            Button("Move up") { moveUp(index) }.disabled(index == 0)
                            Spacer()
                            Button("Remove card", role: .destructive) { remove(index) }
                        }
                    }
                }
                Button("Add card") {
                    var draft = editor.draft
                    draft.cards.append(.init(id: String(UUID().uuidString.lowercased().prefix(32)), title: "", question: ""))
                    editor.edit(draft)
                }
                .accessibilityIdentifier("content-add")
                .disabled(editor.draft.cards.count >= 3)
            }.disabled(editor.isBusy || model.isWorking)

            Section("Content files") {
                Button("Import content draft…") {
                    guard !model.isDemoMode, !editor.isDemo, !model.isWorking else { return }
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
                    .accessibilityIdentifier("content-import")
                Button("Export content draft…") {
                    do { exportDocument = try editor.exportDocument(); exportingDraft = true; operationError = nil }
                    catch { operationError = error.localizedDescription }
                }
                .accessibilityIdentifier("content-export")
                Text("One JSON file includes cards, images and layouts. Import is reviewed before replacing local edits; it never saves or applies automatically.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .disabled(model.isDemoMode || editor.isDemo || editor.isBusy || model.isWorking)

            ContentCardPreview(draft: editor.draft, hardware: model.hardware)

            Section("Save and apply") {
                ContentJournalRecovery(model: model)
                if let validation { Text(validation).font(.caption).foregroundStyle(.orange) }
                if let error = operationError ?? editor.lastError { Text(error).font(.caption).foregroundStyle(.red) }
                if editor.lastError != nil && !model.isDemoMode {
                    Button("Preserve saved file and recover with these edits…") { confirmingRecovery = true }
                        .disabled(editor.isBusy)
                }
                if let backup = editor.recoveryBackup {
                    Text("Previous saved draft preserved: \(backup.lastPathComponent)")
                        .font(.caption).textSelection(.enabled)
                    ShareLink("Export preserved draft", item: backup)
                }
                Text(editor.hasUnsavedChanges ? "Unsaved local changes" : "No unsaved local changes")
                    .font(.caption).accessibilityIdentifier("content-dirty-state")
                Button("Save draft") {
                    Task {
                        do { try await editor.save(); operationError = nil }
                        catch { operationError = error.localizedDescription }
                    }
                }
                .accessibilityIdentifier("content-save")
                .disabled(model.isDemoMode || editor.isBusy || !editor.hasUnsavedChanges)
                Button("Apply content to reader") { confirmingApply = true }
                    .accessibilityIdentifier("content-apply")
                    .disabled(liveApply.isEnabled || model.isDemoMode || model.readerStatus?.deviceID == nil || model.isWorking || editor.isBusy || validation != nil)
                Button(liveApply.isEnabled ? "Stop live apply" : "Start live apply…") {
                    if liveApply.isEnabled { liveApply.stop() }
                    else {
                        liveSession = model.contentEditingSession
                        confirmingLiveApply = true
                    }
                }
                .accessibilityIdentifier("content-live-apply")
                .disabled(!liveApply.isEnabled && (model.contentEditingSession == nil || model.isWorking || editor.isBusy || validation != nil))
                Text(liveApply.message).font(.caption)
                    .accessibilityIdentifier("content-live-state")
                Text("Attached-image thumbnails show stored pixels. The offline reader preview uses the reference layout shown above, not the connected reader’s settings. Storage activation is verified separately from screen display.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let deployment = model.contentDeployment { ContentDeploymentStatus(deployment: deployment, model: model) }
                Text(model.message).font(.caption)
                if model.isTransferring { Button("Cancel transfer") { model.pauseTransfer() } }
            }
        }
        .formStyle(.grouped)
#if os(iOS)
        .scrollDismissesKeyboard(.immediately)
#endif
        .modifier(TransferFilePicker(isPresented: $choosingImage,
                                    allowedContentTypes: [.image, UTType(filenameExtension: "pbm") ?? .data]) { result in
            guard let cardID = imageCardID else { return }
            imageCardID = nil
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
            guard !model.isDemoMode, !editor.isDemo, !model.isWorking else { return }
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
                      defaultFilename: "Pocket Daily content") { result in
            if case let .failure(error) = result, (error as? CocoaError)?.code != .userCancelled {
                operationError = error.localizedDescription
            }
            exportDocument = nil
        }
        .sheet(item: Binding(get: { editor.pendingImport }, set: { value in
            if value == nil, let id = editor.pendingImport?.id { editor.cancelImport(id: id) }
        })) { proposal in
            ContentImportReview(proposal: proposal, error: importError, cancel: {
                editor.cancelImport(id: proposal.id)
            }, confirm: {
                guard !model.isDemoMode, !model.isWorking else { return }
                do { try editor.confirmImport(id: proposal.id); importError = nil }
                catch { importError = error.localizedDescription }
            })
        }
        .onDisappear {
            liveApply.stop()
            imageTask?.cancel()
            importTask?.cancel()
            if let id = editor.pendingImport?.id { editor.cancelImport(id: id) }
        }
        .onChange(of: editor.draft) { _, _ in liveApply.update(try? editor.deploymentSnapshot()) }
        .onChange(of: model.contentEditingSession) { _, session in
            if liveApply.isEnabled && session != liveSession {
                liveApply.stop(message: "Live apply stopped because the reader session changed.")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { liveApply.stop() }
        }
        .onChange(of: choosingDraft) { _, choosing in if choosing { liveApply.stop() } }
        .onChange(of: confirmingRecovery) { _, confirming in if confirming { liveApply.stop() } }
        .confirmationDialog("Start live apply for this reader session?", isPresented: $confirmingLiveApply, titleVisibility: .visible) {
            Button("Start live apply") {
                guard !model.isWorking, !editor.isBusy, let session = liveSession,
                      model.contentEditingSession == session else { return }
                do {
                    let revision = try editor.deploymentSnapshot()
                    liveSession = session
                    liveApply.start(revision: revision) { revision in
                        await model.applyLiveContent(revision, session: session)
                    }
                } catch { operationError = error.localizedDescription }
            }
        } message: {
            Text("The current cards and subsequent valid edits will replace this reader’s card set after a short pause, including clearing it if empty. Closing the editor, importing a draft, leaving the app or an unconfirmed result stops live apply. Local drafts are not saved and firmware is never installed.")
        }
        .confirmationDialog("Recover using these edits?", isPresented: $confirmingRecovery, titleVisibility: .visible) {
            Button("Preserve file and save these edits") {
                Task {
                    do { try await editor.recoverKeepingEdits(); operationError = nil }
                    catch { operationError = error.localizedDescription }
                }
            }
        } message: {
            Text("The current saved file will be preserved as a separate backup before these edits replace it. Nothing is sent to a reader.")
        }
        .confirmationDialog("Apply these cards to the connected reader?", isPresented: $confirmingApply, titleVisibility: .visible) {
            Button("Apply content") {
                do { model.applyContent(try editor.deploymentSnapshot()); operationError = nil }
                catch { operationError = error.localizedDescription }
            }
        } message: {
            Text("This replaces the active app-authored card set, including clearing it if the draft is empty. It does not install firmware or save your local draft.")
        }
    }

    @ViewBuilder private func imageControls(_ card: ContentCard) -> some View {
        if let data = editor.draft.images[card.imagePath] {
            ContentImagePreview(data: data)
        }
        HStack {
            Button(card.imagePath.isEmpty ? "Choose image…" : "Replace image…") {
                imageCardID = card.id
                choosingImage = true
            }.accessibilityIdentifier("content-choose-image-\(card.id)")
            if !card.imagePath.isEmpty {
                Button("Remove image", role: .destructive) {
                    do { try editor.removeImage(cardID: card.id); operationError = nil }
                    catch { operationError = error.localizedDescription }
                }
            }
        }
        .buttonStyle(.borderless)
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
    private func moveUp(_ index: Int) {
        var draft = editor.draft
        guard index > 0, draft.cards.indices.contains(index) else { return }
        draft.cards.swapAt(index, index - 1)
        editor.edit(draft)
    }
    private func remove(_ index: Int) {
        var draft = editor.draft
        guard draft.cards.indices.contains(index) else { return }
        draft.cards.remove(at: index)
        let referenced = Set(draft.cards.map(\.imagePath))
        draft.images = draft.images.filter { referenced.contains($0.key) }
        editor.edit(draft)
    }
}

private struct ContentImportReview: View {
    let proposal: ContentEditorModel.ImportProposal
    let error: String?
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Text(proposal.sourceName).font(.headline)
                Text("Compare the complete sets below. Replace discards unsaved edits in memory only. The saved draft and reader stay unchanged until you explicitly Save or Apply.")
                    .font(.caption)
                if proposal.draft.cards.isEmpty {
                    Text("The imported draft is empty. Confirming will remove all cards from this editor.")
                        .foregroundStyle(.orange)
                }
                cards("Current cards", draft: proposal.before)
                cards("Imported cards", draft: proposal.draft)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Import content draft")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Replace draft", action: confirm).accessibilityIdentifier("content-confirm-import")
                }
            }
        }
        .frame(minWidth: 300, minHeight: 450)
    }

    @ViewBuilder private func cards(_ title: String, draft: ContentDraft) -> some View {
        Section(title) {
            if draft.cards.isEmpty { Text("No cards") }
            ForEach(draft.cards.indices, id: \.self) { index in
                let card = draft.cards[index]
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(index + 1). \(card.title.isEmpty ? "Untitled draft" : card.title)").font(.headline)
                    Text("ID: \(card.id) · \(card.layout.title)").font(.caption)
                    Text(card.question.isEmpty ? "Empty text (finish before applying)" : card.question)
                    if !card.context.isEmpty { Text(card.context).foregroundStyle(.secondary) }
                    if let image = draft.images[card.imagePath] {
                        ContentImagePreview(data: image)
                        Text(card.imagePath).font(.caption2)
                    }
                }.textSelection(.enabled)
            }
        }
    }
}

private struct ContentImagePreview: View {
    let data: Data
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading) {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.none)
                    .scaledToFit().frame(maxWidth: 300, maxHeight: 180)
                    .accessibilityLabel("Black-and-white content image")
                Text("\(image.width) × \(image.height) · Image preview, not reader layout")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if failed {
                Text("Image cannot be previewed. Replace or remove it.").font(.caption).foregroundStyle(.red)
            } else { ProgressView("Preparing image preview…") }
        }
        .task(id: data) {
            image = nil
            failed = false
            let bytes = data
            let decoded = await Task.detached(priority: .userInitiated) {
                try? ContentImage.decode(bytes).previewImage()
            }.value
            guard !Task.isCancelled else { return }
            image = decoded
            failed = decoded == nil
        }
    }
}

private struct ContentJournalRecovery: View {
    @ObservedObject var model: PocketModel
    @State private var confirming = false

    var body: some View {
        if let error = model.activationRecordError, !model.isDemoMode {
            Text("Saved activation record could not be read: \(error)")
                .font(.caption).foregroundStyle(.red)
            Button("Preserve unreadable record and recover…") { confirming = true }
                .disabled(model.isWorking)
                .confirmationDialog("Recover local activation tracking?", isPresented: $confirming, titleVisibility: .visible) {
                    Button("Preserve record and reset tracking", role: .destructive) {
                        Task { await model.recoverContentActivationRecord() }
                    }
                } message: {
                    Text("The unreadable file will be preserved before local tracking is reset. The reader may already have applied content. This does not undo activation, upload content or retry the deployment.")
                }
        }
        if let backup = model.activationRecordBackup, !model.isDemoMode {
            ShareLink("Export preserved activation record", item: backup)
        }
    }
}

private struct ContentDeploymentStatus: View {
    @ObservedObject var deployment: ContentDeployment
    @ObservedObject var model: PocketModel
    @State private var confirmingArchive = false
    var body: some View {
        Text(label).font(.caption).accessibilityIdentifier("content-deployment-state")
        if deployment.phase == .needsConfirmation {
            Button("Check activation outcome") { model.confirmContentActivation() }
                .disabled(model.isWorking || model.isDemoMode || model.readerStatus == nil)
                .accessibilityIdentifier("content-confirm-activation")
            Button("Archive pending check…") { confirmingArchive = true }
                .disabled(model.isWorking || model.isDemoMode)
                .confirmationDialog("Stop waiting for this activation result?", isPresented: $confirmingArchive,
                                    titleVisibility: .visible) {
                    Button("Preserve record and stop checking", role: .destructive) {
                        Task { await model.archivePendingContentActivation() }
                    }
                } message: {
                    Text("This preserves the pending record and allows a new Apply. It does not cancel or undo anything on the reader. The content may already be active. No new content will be sent automatically.")
                }
        }
        if let archive = deployment.archivedRecord {
            ShareLink("Export archived activation record", item: archive)
        }
    }
    private var label: String {
        switch deployment.phase {
        case .idle: "Ready"
        case .checking: "Checking reader"
        case .preparing: "Preparing content"
        case let .uploading(_, index, total): "Verifying file \(index) of \(total)"
        case .activating: "Activating stored content"
        case .confirming: "Confirming active revision"
        case let .complete(active): model.contentRedrawReceipt == active
            ? "Content activated · reader redraw confirmed"
            : "Storage activation confirmed · screen not confirmed"
        case .failed: "Content was not activated"
        case .cancelled: "Cancelled before activation"
        case .needsConfirmation: "Activation outcome unknown · check state before retrying"
        case .archived: "Pending check archived · reader outcome remains unknown"
        }
    }
}
