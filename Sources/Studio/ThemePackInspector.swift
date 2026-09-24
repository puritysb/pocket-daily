import SwiftUI
import UniformTypeIdentifiers

/// Local theme draft; only explicit Apply/Revert may contact a reader.
/// Activation confirmation is distinct from a captured screen or pixel parity.
struct ThemePackInspector: View {
    @ObservedObject var model: PocketModel
    @State private var editor: ThemeEditorModel?
    @State private var openingError: String?

    var body: some View {
        InspectorCard(title: "THEME PACK", symbol: "paintpalette") {
            if let editor {
                ThemeDraftControls(model: model, editor: editor).id(ObjectIdentifier(editor))
            } else if let openingError {
                Text(openingError).font(.caption).foregroundStyle(.red)
                Button("Retry opening theme draft") { open() }
            } else { ProgressView("Opening local theme draft…") }
        }
        .task(id: model.isDemoMode) { open() }
    }

    private func open() {
        do { editor = try model.themeEditorModel(); openingError = nil }
        catch { editor = nil; openingError = error.localizedDescription }
    }
}

private struct ThemeDraftControls: View {
    @ObservedObject var model: PocketModel
    @ObservedObject var editor: ThemeEditorModel
    @State private var operationError: String?
    @State private var confirmingRecovery = false
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument: ThemeDraftDocument?
    @State private var fileError: String?

    private var packCapable: Bool { model.readerStatus?.liveStudio?.uiPacks == true }
    private var canChangeReader: Bool {
        packCapable && !model.isWorking && !model.isDemoMode &&
        (try? UiPackVerification.identity(model.readerStatus?.deviceID)) != nil
    }
    private var canApply: Bool {
        canChangeReader && editor.hasLoaded && !editor.isBusy && !editor.isDemo
    }

    private func field<Value>(_ keyPath: WritableKeyPath<ThemeDraft, Value>) -> Binding<Value> {
        Binding(get: { editor.draft[keyPath: keyPath] }, set: { value in
            var draft = editor.draft
            draft[keyPath: keyPath] = value
            editor.edit(draft)
        })
    }

    var body: some View {
        Group {
            DisclosureGroup("Edit theme metrics offline") {
                Stepper("Header \(editor.draft.headerHeight)", value: field(\.headerHeight), in: 20...120)
                    .accessibilityIdentifier("theme-header-height")
                Stepper("List rows \(editor.draft.listRowHeight)", value: field(\.listRowHeight), in: 30...120)
                Stepper("Menu rows \(editor.draft.menuRowHeight)", value: field(\.menuRowHeight), in: 30...120)
                Stepper("Menu spacing \(editor.draft.menuSpacing)", value: field(\.menuSpacing), in: 0...32)
                Stepper("Tab bar \(editor.draft.tabBarHeight)", value: field(\.tabBarHeight), in: 20...80)
                Stepper("Side padding \(editor.draft.contentSidePadding)", value: field(\.contentSidePadding), in: 0...64)
                Stepper("Popup radius \(editor.draft.popupCornerRadius)", value: field(\.popupCornerRadius), in: 0...32)
                Toggle("Bold popup text", isOn: field(\.popupTextBold))
                Text(editor.isDemo ? "Local demo draft · saving and device changes disabled" :
                     "Local draft values, not the reader’s current settings. Save keeps these edits across app launches without applying them.")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(editor.hasUnsavedChanges ? "Unsaved theme changes" : "No unsaved theme changes")
                    .font(.caption).accessibilityIdentifier("theme-dirty-state")
                Button("Save theme draft") {
                    guard !model.isDemoMode else { return }
                    Task {
                        do { try await editor.save(); operationError = nil }
                        catch { operationError = error.localizedDescription }
                    }
                }
                .accessibilityIdentifier("theme-save")
                .disabled(model.isDemoMode || editor.isDemo || !editor.hasUnsavedChanges)
                HStack {
                    Button("Import theme draft…") {
                        guard !model.isDemoMode && !editor.isDemo else { return }
                        fileError = nil
                        #if DEBUG
                        if let raw = ProcessInfo.processInfo.environment["POCKET_UI_TEST_THEME_IMPORT_ID"],
                           let id = UUID(uuidString: raw) {
                            Task {
                                do { try await editor.prepareImport(from: ThemeDraftUITestStore.importFixture(id: id)) }
                                catch { fileError = error.localizedDescription }
                            }
                            return
                        }
                        #endif
                        importing = true
                    }
                    .accessibilityIdentifier("theme-import")
                    Button("Export theme draft…") {
                        guard !model.isDemoMode else { return }
                        do {
                            exportDocument = try editor.exportDocument()
                            fileError = nil
                            exporting = true
                        } catch { fileError = error.localizedDescription }
                    }
                    .accessibilityIdentifier("theme-export")
                }
                .disabled(model.isDemoMode || editor.isDemo)
                Text("Theme draft JSON contains these eight metrics only, not fonts, resources or firmware. Import replaces only the in-memory draft after confirmation; Save and Apply are separate.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .disabled(!editor.hasLoaded || editor.isBusy)
            if let fileError { Text(fileError).font(.caption).foregroundStyle(.red) }
            if let error = operationError ?? editor.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
                if !model.isDemoMode && !editor.isDemo {
                    Button("Preserve saved theme and recover…") { confirmingRecovery = true }
                        .disabled(editor.isBusy)
                        .accessibilityIdentifier("theme-recover")
                }
            }
            if let backup = editor.recoveryBackup {
                Text("Previous theme draft preserved: \(backup.lastPathComponent)")
                    .font(.caption).textSelection(.enabled)
                ShareLink("Export preserved theme draft", item: backup)
            }
            if !editor.hasLoaded {
                if editor.isBusy { ProgressView("Loading theme draft…") }
                else { Button("Retry loading theme draft") { Task { await load() } } }
            }
            if let pack = model.readerStatus?.liveStudio?.activePack {
                Text("Active on reader: \(pack)\(model.readerStatus?.liveStudio?.activePackVersion.map { " v\($0)" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Apply live") { model.applyThemePack(editor.draft.overrides) }
                    .accessibilityIdentifier("theme-apply")
                    .buttonStyle(.borderedProminent).disabled(!canApply)
                Button("Revert") { model.revertThemePack() }
                    .accessibilityIdentifier("theme-revert")
                    .buttonStyle(.bordered).disabled(!canChangeReader)
            }
            Text(canApply ? "Apply sends a data pack, never firmware. Activation is verified separately from the displayed screen." :
                 "Edit without a reader. Applying or reverting requires an identified reader with UI-pack support; demo mode never changes a device.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .task { if !editor.hasLoaded && !editor.isBusy { await load() } }
        .modifier(TransferFilePicker(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard !model.isDemoMode && !editor.isDemo else { return }
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    do { try await editor.prepareImport(from: url); fileError = nil }
                    catch is CancellationError { }
                    catch { fileError = error.localizedDescription }
                }
            case .failure(let error): fileError = error.localizedDescription
            }
        })
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                      defaultFilename: "Pocket Theme.pocket-theme.json") { result in
            if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled {
                fileError = error.localizedDescription
            }
            exportDocument = nil
        }
        .sheet(item: Binding(get: { editor.pendingImport }, set: { value in
            if value == nil, let id = editor.pendingImport?.id { editor.cancelImport(id: id) }
        })) { proposal in
            ThemeImportReview(proposal: proposal, error: fileError, cancel: {
                editor.cancelImport(id: proposal.id)
            }, confirm: {
                guard !model.isDemoMode else { return }
                do { try editor.confirmImport(id: proposal.id); fileError = nil }
                catch { fileError = error.localizedDescription }
            })
        }
        .alert("Recover the local theme draft?", isPresented: $confirmingRecovery) {
            Button("Cancel", role: .cancel) { }
            Button("Preserve file and recover theme", role: .destructive) {
                guard !model.isDemoMode && !editor.isDemo else { return }
                Task {
                    do { try await editor.recoverKeepingEdits(); operationError = nil }
                    catch { operationError = error.localizedDescription }
                }
            }
        } message: {
            Text("The saved file will be copied to a separate backup before replacement. Current in-memory values will become the saved draft; if loading failed, these are the editor’s default values. Nothing is sent to a reader.")
        }
    }

    private func load() async {
        do { try await editor.load(); operationError = nil }
        catch is CancellationError { }
        catch { operationError = error.localizedDescription }
    }
}

private struct ThemeImportReview: View {
    let proposal: ThemeEditorModel.ImportProposal
    let error: String?
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Text(proposal.sourceName).font(.headline)
                Text("Current → Imported. Confirming replaces any unsaved theme edits in memory. The saved draft and reader stay unchanged until you explicitly Save or Apply.")
                    .font(.caption)
                row("Header", \.headerHeight)
                row("List rows", \.listRowHeight)
                row("Menu rows", \.menuRowHeight)
                row("Menu spacing", \.menuSpacing)
                row("Tab bar", \.tabBarHeight)
                row("Side padding", \.contentSidePadding)
                row("Popup radius", \.popupCornerRadius)
                LabeledContent("Bold popup text", value: "\(proposal.before.popupTextBold ? "On" : "Off") → \(proposal.draft.popupTextBold ? "On" : "Off")")
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Import theme draft")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Replace draft", action: confirm).accessibilityIdentifier("theme-confirm-import")
                }
            }
        }
        .frame(minWidth: 300, minHeight: 450)
    }

    private func row(_ name: String, _ keyPath: KeyPath<ThemeDraft, Int>) -> some View {
        LabeledContent(name, value: "\(proposal.before[keyPath: keyPath]) → \(proposal.draft[keyPath: keyPath])")
    }
}
