import SwiftUI
import UniformTypeIdentifiers

struct ContentImportReview: View {
    let proposal: ContentEditorModel.ImportProposal
    let error: String?
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Text(proposal.sourceName).font(.headline)
                Text("Replace swaps every card in this editor for the set below. The reader does not change until you choose Send.")
                    .font(.caption)
                if proposal.draft.cards.isEmpty {
                    Text("The imported draft is empty. Confirming will remove all cards from this editor.")
                        .foregroundStyle(.orange)
                }
                cards("Current cards", draft: proposal.before)
                cards("Imported cards", draft: proposal.draft)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Replace cards?")
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

struct ContentImagePreview: View {
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

struct ContentJournalRecovery: View {
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

struct ContentDeploymentStatus: View {
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
