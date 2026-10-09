import SwiftUI
import UniformTypeIdentifiers

/// This sheet displays an app-owned job. Dismissing it does not cancel that job.
struct BookTransferSheet<Connection: View>: View {
    @ObservedObject var model: PocketModel
    let jobID: UUID
    @ObservedObject var library: LibraryModel
    @ViewBuilder let connection: () -> Connection
    let cancelConnection: () -> Void
    let onInventory: () -> Void
    let onDevice: () -> Void
    let onCurrentTask: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var connecting = false
    @State private var changingTarget = false
    @State private var discarding = false
    @State private var forgettingLocally = false
    @State private var choosingSD = false
    @State private var sdFolder: URL?
    @State private var sdFolderError: String?
    private var job: BookTransferJob? { model.bookTransferJob(jobID) }
    private var isSDDestination: Bool {
#if os(macOS)
        job?.destination == .sdCard
#else
        false
#endif
    }
    private var destinationBinding: Binding<BookTransferDestination> {
        Binding(get: { job?.destination ?? .readerWiFi }, set: { destination in
            Task { _ = await model.selectBookTransferDestination(jobID, destination: destination) }
        })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let job {
#if os(macOS)
                        Picker("Send to", selection: destinationBinding) {
                            ForEach(BookTransferDestination.allCases, id: \.self) { destination in
                                Text(destination.title).tag(destination)
                            }
                        }
                        .pickerStyle(.segmented).disabled(model.isWorking || job.stage == .discarded)
                        .accessibilityIdentifier("book-transfer-destination")
#endif
                        Label(isSDDestination ? sdTitle(job) : effectiveStage(job).displayTitle,
                              systemImage: isSDDestination ? "sdcard" : stageSymbol(effectiveStage(job)))
                            .font(.title3.weight(.semibold)).accessibilityIdentifier("book-transfer-stage")
                        if isSDDestination {
                            LabeledContent("Folder", value: sdFolder?.lastPathComponent ?? job.latestSDCopy?.folderName ?? "Not selected")
                            if job.needsConfirmation {
                                PocketStatusLabel("The earlier Wi-Fi transfer still needs its saved result checked. Copying to SD does not resolve that result.",
                                                  tone: .pending, symbol: "exclamationmark.triangle")
                                    .font(.caption)
                                Button("Review Wi-Fi Result") {
                                    Task { _ = await model.selectBookTransferDestination(jobID, destination: .readerWiFi) }
                                }.disabled(model.isWorking)
                            }
                        } else {
                            LabeledContent("Reader", value: job.target?.displayName ?? model.readerStatus?.device ?? "Choose after connecting")
                            if job.target?.readerID == nil, job.target != nil, !model.isDemoMode {
                                Text("This reader has no unique identity. Its connection must be selected again before sending.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(job.items) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    itemSymbol(job, item)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.title).font(.headline)
                                        if isSDDestination {
                                            let copied = job.latestSDCopy?.items.first { $0.bookID == item.bookID }
                                            Text(sdItemTitle(copied?.result)).font(.caption).foregroundStyle(.secondary)
                                            if let path = copied?.path { Text(path).font(.caption2).foregroundStyle(.secondary) }
                                            if let failure = copied?.failure { Text(failure).font(.caption) }
                                        } else {
                                            Text(itemTitle(item.result)).font(.caption).foregroundStyle(.secondary)
                                            if let path = item.publishedPath { Text(path).font(.caption2).foregroundStyle(.secondary) }
                                            if let failure = item.failure { Text(failure).font(.caption) }
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        if !isSDDestination, job.stage == .sending || job.stage == .checking {
                            ProgressView(value: job.progress).progressViewStyle(.pocketBar)
                            Text("\(job.savedCount) of \(job.items.count) saved")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let failure = isSDDestination ? job.latestSDCopy?.failure : job.failure {
                            PocketStatusLabel(failure, tone: .pending, symbol: "exclamationmark.triangle").font(.callout)
                        }
                        if let error = model.bookTransferError { PocketStatusLabel(error, tone: .failure).font(.callout) }
                        if !model.isDemoMode, !isSDDestination, connecting || job.stage == .connecting {
                            connection()
                        }
                        if !isSDDestination, !model.isDemoMode, job.stage != .sending && job.stage != .checking && job.stage != .preparing && !job.isFinished {
                            if !job.needsConfirmation {
                                Button("Discard This Transfer…", role: .destructive) { discarding = true }
                                    .font(.callout).disabled(model.isWorking)
                            }
                            if needsLocalRecovery(job) {
                                DisclosureGroup("Recovery options") {
                                    Button("Forget Local Prepared Copies…", role: .destructive) { forgettingLocally = true }
                                        .font(.callout).disabled(model.isWorking)
                                        .accessibilityIdentifier("book-transfer-forget-local")
                                }
                                .font(.callout)
                            }
                        }
                    } else {
                        Text("This transfer is no longer available.").foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
            // The task's actions keep one place at the bottom through every
            // step, above however many books the list holds.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let job {
                    VStack(alignment: .leading, spacing: 8) {
                        if model.isDemoMode {
                            Text("Demo does not connect or send files.").font(.callout).foregroundStyle(.secondary)
                        } else if isSDDestination {
                            sdActions(job)
                        } else if connecting || job.stage == .connecting {
                            // Returns to this transfer; an attempt still running is stopped first.
                            Button("Back to Transfer", systemImage: "chevron.left") { cancelConnection(); connecting = false }
                                .accessibilityIdentifier("book-transfer-connection-back")
                        } else {
                            actions(job)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.vertical, 12)
                    .background(PocketPalette.panel)
                    .overlay(alignment: .top) { Divider() }
                }
            }
            .navigationTitle("Send to Reader")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }.accessibilityIdentifier("book-transfer-close")
                }
            }
            .onChange(of: model.device.isConnected) { _, connected in
                if connected { connecting = false }
            }
            .confirmationDialog("Use the connected reader?", isPresented: $changingTarget, titleVisibility: .visible) {
                if let status = model.readerStatus {
                    Button("Use \(status.device)") {
                        Task { _ = await model.selectBookTransferTarget(jobID, target: .init(readerID: status.deviceID, displayName: status.device)) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The selected books stay the same. Sending starts only when you choose Send.")
            }
            .confirmationDialog("Forget local copies of \(jobName)?", isPresented: $forgettingLocally, titleVisibility: .visible) {
                Button("Forget Local Copies", role: .destructive) { model.discardBookTransferJob(jobID, localOnly: true) }
                Button("Keep Transfer", role: .cancel) {}
            } message: {
                Text("The reader may already have saved these books. This removes only local prepared copies and tracking; it cannot confirm or remove files on the reader. Your Library stays. No automatic retry follows.")
            }
            .confirmationDialog("Discard sending \(jobName)?", isPresented: $discarding, titleVisibility: .visible) {
                Button("Discard Transfer", role: .destructive) { model.discardBookTransferJob(jobID) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes this task’s prepared copies and tracked temporary reader files. Your Library and books already saved on the reader stay.")
            }
        }
#if os(macOS)
        .frame(width: 560, height: 500)
        .fileImporter(isPresented: $choosingSD, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            guard !model.isDemoMode else { return }
            do { sdFolder = try result.get().first; sdFolderError = nil }
            catch { sdFolderError = error.localizedDescription }
        }
#endif
        .accessibilityIdentifier("book-transfer-sheet")
    }

    @ViewBuilder private func actions(_ job: BookTransferJob) -> some View {
        switch job.stage {
        case .preparing:
            ProgressView(job.stage.displayTitle)
            Button("Stop Preparation") { model.pauseBookTransferJob(jobID) }
        case .waitingForOtherWork:
            Text("Finish the current reader task, then retry these selected books.").font(.caption).foregroundStyle(.secondary)
            Button("Retry Preparation") { Task { await model.retryBookTransferJob(jobID, library: library) } }
                .disabled(model.isWorking).buttonStyle(.bordered)
            if model.isWorking { Button("View Current Task", action: onCurrentTask) }
        case .sending, .checking:
            Button("Stop") { model.pauseBookTransferJob(jobID) }.buttonStyle(.bordered)
                .accessibilityIdentifier("book-transfer-stop")
        case .completed:
            Text("Reading positions are exchanged separately.").font(.caption).foregroundStyle(.secondary)
            Button("View Reader Library", action: onInventory).buttonStyle(.bordered)
        case .discarded:
            EmptyView()
        default:
            if !model.device.isConnected {
                Button("Connect Reader…") { connecting = true }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("book-transfer-connect")
            } else if job.needsConfirmation {
                if job.target?.readerID != nil, job.target?.readerID != model.readerStatus?.deviceID {
                    Text("Connect the original reader to check whether it saved these books.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reconnect Selected Reader…") { reconnectSelectedReader() }
                        .buttonStyle(.borderedProminent).disabled(model.isWorking)
                        .accessibilityIdentifier("book-transfer-reconnect-original")
                } else {
                    Button("Check Saved Results") { model.checkBookTransferJob(jobID) }.buttonStyle(.borderedProminent)
                        .disabled(model.isWorking).accessibilityIdentifier("book-transfer-check")
                }
            } else if model.readerStatus?.supportsAtomicUpload != true {
                Text("This reader’s firmware does not support safe book transfers. Update compatible firmware in Manage Reader, then return to this task.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Manage Reader", action: onDevice).buttonStyle(.bordered)
            } else if model.canSendBookTransferJob(jobID) {
                let remaining = job.items.filter { $0.transferID != nil && $0.result != .saved && $0.result != .discarded }.count
                Button("Send \(remaining) \(remaining == 1 ? "Book" : "Books")") { model.sendBookTransferJob(jobID) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("book-transfer-send")
            } else if !model.isWorking, job.target?.readerID != nil, job.target?.readerID != model.readerStatus?.deviceID {
                Text("The connected reader differs from this transfer’s target.").font(.caption).foregroundStyle(.secondary)
                if requiresOriginalTarget(job) {
                    Text("Reconnect the original reader to continue this transfer.").font(.caption).foregroundStyle(.secondary)
                    Button("Reconnect Selected Reader…") { reconnectSelectedReader() }.buttonStyle(.bordered)
                } else {
                    Button("Choose Connected Reader…") { changingTarget = true }.buttonStyle(.bordered)
                }
            } else if job.items.contains(where: { $0.result == .unprepared || $0.result == .failed }) {
                Button("Retry Preparation") { Task { await model.retryBookTransferJob(jobID, library: library) } }
                    .buttonStyle(.borderedProminent).disabled(model.isWorking)
            } else if !model.isWorking {
                Button("Choose Connected Reader…") { changingTarget = true }.buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("book-transfer-select-target")
            }
            // A disabled action above says why and where the blocking work is.
            if model.device.isConnected, model.isWorking {
                Text("Available after the current reader task.").font(.caption).foregroundStyle(.secondary)
                Button("View Current Task", action: onCurrentTask).buttonStyle(.bordered)
            }
        }
    }

    /// The books by name, for confirmations: “Dune” or “Dune” and 2 more.
    private var jobName: String {
        guard let job, let first = job.items.first?.title else { return "these books" }
        return job.items.count > 1 ? "“\(first)” and \(job.items.count - 1) more" : "“\(first)”"
    }

    /// Each book says its own result: saved, failed or not yet sent.
    @ViewBuilder private func itemSymbol(_ job: BookTransferJob, _ item: BookTransferJob.Item) -> some View {
        let copied = job.latestSDCopy?.items.first { $0.bookID == item.bookID }
        let done = isSDDestination ? copied?.result == .copied : item.result == .saved
        let failed = isSDDestination ? copied?.failure != nil || copied?.result == .failed : item.failure != nil || item.result == .failed
        if done {
            Image(systemName: StatusTone.success.symbol).foregroundStyle(StatusTone.success.color).accessibilityLabel("Saved")
        } else if failed {
            Image(systemName: StatusTone.failure.symbol).foregroundStyle(StatusTone.failure.color).accessibilityLabel("Not sent")
        } else {
            Image(systemName: "book.closed").foregroundStyle(.secondary).accessibilityHidden(true)
        }
    }

    private func reconnectSelectedReader() {
        Task {
            if await model.disconnectForBookTransferRecovery(jobID) { connecting = true }
        }
    }

    @ViewBuilder private func sdActions(_ job: BookTransferJob) -> some View {
        if model.isBookSDCopyActive(jobID) {
            ProgressView("Copying selected books")
            Button("Stop Copying") { model.pauseBookTransferJob(jobID) }.buttonStyle(.bordered)
        } else {
            if job.latestSDCopy?.stage == .completed {
                Text("Copied to SD card. Insert the card in the reader to use these books.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if job.latestSDCopy?.stage == .confirmationUnknown {
                Text("The previous copy may have finished. Check the selected folder before retrying. Existing files will not be overwritten.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if job.latestSDCopy?.copiedCount ?? 0 > 0 {
                Text("\(job.latestSDCopy?.copiedCount ?? 0) of \(job.items.count) copied. Check the folder before starting another copy.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = sdFolderError { PocketStatusLabel(error, tone: .failure).font(.callout) }
            Button(sdFolder == nil ? "Choose SD Card Folder…" : "Choose Another Folder…") { choosingSD = true }
                .disabled(model.isWorking || model.isDemoMode)
                .accessibilityIdentifier("book-transfer-sd-folder")
            if let sdFolder {
                Button("Copy \(job.items.count) \(job.items.count == 1 ? "Book" : "Books") to SD Card") {
                    model.copyBookTransferJobToSD(jobID, root: sdFolder, library: library)
                }.buttonStyle(.borderedProminent).disabled(!model.canPrepareFiles)
                    .accessibilityIdentifier("book-transfer-sd-copy")
            }
            if model.isWorking { Button("View Current Task", action: onCurrentTask) }
        }
    }

    private func sdTitle(_ job: BookTransferJob) -> String { job.presentationStatus }

    private func sdItemTitle(_ result: BookSDCopy.Result?) -> String {
        switch result {
        case nil, .waiting: return "Not copied"
        case .copying: return "Copying"
        case .copied: return "Copied to SD card"
        case .confirmationUnknown: return "Check selected folder"
        case .failed: return "Not copied · needs attention"
        }
    }

    private func effectiveStage(_ job: BookTransferJob) -> BookTransferJob.Stage {
        guard [.needsConnection, .connecting, .ready].contains(job.stage) else { return job.stage }
        if model.device.link == .connecting || model.canCancelConnection { return .connecting }
        if model.canSendBookTransferJob(jobID) { return .ready }
        if model.isWorking { return .waitingForOtherWork }
        return .needsConnection
    }

    private func needsLocalRecovery(_ job: BookTransferJob) -> Bool {
        job.needsConfirmation || model.preparedTransfers.contains { copy in
            copy.bookJobID == jobID && copy.stagingID != nil && job.items.contains {
                $0.transferID == copy.id && $0.bookID == copy.libraryBookID && $0.result != .saved
            }
        }
    }

    private func requiresOriginalTarget(_ job: BookTransferJob) -> Bool {
        job.savedCount > 0 || job.needsConfirmation || model.preparedTransfers.contains {
            $0.bookJobID == jobID && $0.stagingID != nil
        }
    }

    private func itemTitle(_ result: BookTransferJob.Result) -> String {
        switch result {
        case .unprepared: "Not prepared"
        case .prepared: "Ready"
        case .sending: "Sending"
        case .confirmationUnknown: "Check whether saved"
        case .saved: "Saved on reader"
        case .failed: "Needs attention"
        case .discarded: "Discarded"
        }
    }

    private func stageSymbol(_ stage: BookTransferJob.Stage) -> String {
        switch stage {
        case .completed: "checkmark.circle"
        case .failed, .confirmationUnknown, .partialCompletion: "exclamationmark.triangle"
        case .sending, .checking: "arrow.up.doc"
        default: "books.vertical"
        }
    }
}
