import SwiftUI
import Combine

enum StudioContentTask: String, Identifiable {
    case cards, glance
    var id: String { rawValue }
    var title: String { self == .cards ? "My cards" : "Weather & calendar" }
}

/// Shared originals are a separate editing task. Connection replaces this
/// sheet's content temporarily; the task and local draft stay in this window.
struct StudioContentSheet: View {
    @ObservedObject var model: PocketModel
    @ObservedObject private var settings: GlanceSettings
    let task: StudioContentTask
    var cards: ContentEditorModel?
    var loadError: String?
    var reloadCards: () async -> Void = {}
    var connectionContent: (() -> AnyView)?
    var cancelConnection: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var connecting = false
    @State private var selectedCardID: String?
    @State private var draft = ContentDraft()
    @State private var drag: ReorderDrag?
    @StateObject private var preview = ContentPreviewModel()

    init(model: PocketModel, task: StudioContentTask, cards: ContentEditorModel? = nil,
         loadError: String? = nil, reloadCards: @escaping () async -> Void = {},
         connectionContent: (() -> AnyView)? = nil, cancelConnection: @escaping () -> Void = {}) {
        self.model = model
        self.settings = model.glanceSettings
        self.task = task
        self.cards = cards
        self.loadError = loadError
        self.reloadCards = reloadCards
        self.connectionContent = connectionContent
        self.cancelConnection = cancelConnection
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Keep the source form's identity while connecting, including
                // an unconfirmed city query and the selected calendar controls.
                VStack(alignment: .leading, spacing: 0) {
                    Text("Used by Home & Sleep")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 20).padding(.top, 12)
                    if task == .cards { cardWorkspace }
                    else { glanceWorkspace }
                    Divider()
                    applyBar
                }
                .opacity(connecting ? 0 : 1)
                .allowsHitTesting(!connecting)
                .disabled(connecting)
                .accessibilityHidden(connecting)
                if connecting {
                    VStack(alignment: .leading, spacing: 0) {
                        if let connectionContent { connectionContent() }
                        else { Text("Reader connection controls are unavailable.").foregroundStyle(.secondary).padding(20) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("content-connection")
                }
            }
            .navigationTitle(connecting ? "Connect Reader" : task.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if connecting {
                        Button("Back", systemImage: "chevron.left") { cancelConnection(); connecting = false }
                            .accessibilityLabel("Back to \(task.title)")
                            .accessibilityIdentifier("content-connection-back")
                    } else {
                        Button("Close") { dismiss() }.accessibilityIdentifier("content-editor-close")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: task == .cards ? 660 : 540, idealWidth: task == .cards ? 800 : 540,
               maxWidth: task == .cards ? nil : 540, minHeight: task == .cards ? 580 : 500,
               idealHeight: task == .cards ? 680 : 500, maxHeight: task == .cards ? nil : 500)
        #endif
        .accessibilityIdentifier("content-editor-sheet")
        .onReceive(cards?.$draft.eraseToAnyPublisher() ?? Just(ContentDraft()).eraseToAnyPublisher()) {
            if draft != $0 { draft = $0 }
        }
        .task(id: previewRequest) {
            if task == .cards { await preview.update(previewRequest) }
        }
        .onChange(of: model.readerStatus) { _, status in
            if status != nil && !model.isWorking { connecting = false }
        }
        .onChange(of: model.isWorking) { _, working in
            if !working && model.readerStatus != nil { connecting = false }
        }
        .onDisappear {
            preview.cancel()
            if connecting { cancelConnection() }
            Task { await persistCardDraft() }
        }
    }

    private var selectedCard: ContentCard? {
        draft.cards.first { $0.id == selectedCardID } ?? draft.cards.first
    }
    private var previewRequest: ContentPreviewRequest {
        .init(card: selectedCard, image: selectedCard.flatMap { draft.images[$0.imagePath] },
              hardware: model.hardware, orientation: .portrait,
              style: model.readerDisplay.map(PreviewStyle.init(reader:)) ?? .reference)
    }

    private var cardWorkspace: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= PocketDesign.splitLayoutWidth
            if wide {
                HStack(alignment: .top, spacing: 20) {
                    cardPreview(height: min(400, geometry.size.height - 30))
                        .frame(width: min(260, geometry.size.width * 0.36))
                    cardFields
                }.padding(20)
            } else {
                VStack(spacing: 8) {
                    cardPreview(height: min(160, max(65, geometry.size.height * 0.26)))
                    Divider()
                    cardFields
                }.padding(.horizontal, 16).padding(.top, 12)
            }
        }
    }

    private func cardPreview(height: CGFloat) -> some View {
        VStack(spacing: 6) {
            PocketDevicePreview(hardware: model.hardware, status: model.readerStatus, renderedScreen: preview.image)
                .frame(height: max(60, height))
                .overlay {
                    if let error = preview.error {
                        Text(error).font(.caption).padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(selectedCard.map { "Card \($0.title)" } ?? "No card")
                .accessibilityValue(preview.renderedRequest == previewRequest ? "Current" : "Updating")
                .accessibilityIdentifier("card-editor-canvas")
            Text("Card preview · not a live reader screen")
                .font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("card-editor-caption")
        }.frame(maxWidth: .infinity)
    }

    private var cardFields: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let cards {
                    MyCardsEditor(editor: cards, model: model, selectedID: $selectedCardID, drag: $drag) {}
                    if let deployment = model.contentDeployment {
                        ContentDeploymentStatus(deployment: deployment, model: model)
                    }
                    ContentJournalRecovery(model: model)
                } else if let loadError {
                    PocketStatusLabel(loadError, tone: .failure).font(.callout)
                    Button("Retry Loading Cards") { Task { await reloadCards() } }
                } else { ProgressView("Loading cards…") }
            }.padding(.bottom, 20)
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("card-editor-controls")
    }

    private var glanceWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Weather", systemImage: "cloud.sun").font(.headline)
                    WeatherControls(settings: settings, model: model)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Label("Calendar", systemImage: "calendar").font(.headline)
                    CalendarControls(settings: settings, model: model)
                }
            }.padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("glance-editor-controls")
    }

    private var revision: ContentRevision? {
        guard let cards, !cards.draft.cards.isEmpty else { return nil }
        return try? cards.deploymentSnapshot()
    }
    private var validation: String? {
        guard let cards, !cards.draft.cards.isEmpty else { return nil }
        do { _ = try cards.deploymentSnapshot(); return nil }
        catch { return MyCardsEditor.describe(error) }
    }
    private var cardStatus: ContentSendStatus {
        ContentSendStatus.evaluate(.init(isDemo: model.isDemoMode, connected: model.readerStatus != nil,
            canPresent: model.contentEditingSession != nil, validation: validation, cardCount: draft.cards.count,
            draftRevision: revision?.revision, phase: model.contentDeployment?.phase,
            redrawConfirmed: model.contentRedrawReceipt, busy: model.isWorking))
    }
    private var status: (text: String, tone: StatusTone, symbol: String) {
        if task == .cards { return (cardStatus.label, cardStatus.tone, cardStatus.symbol) }
        if model.isDemoMode { return ("Demo · nothing is sent", .neutral, "info.circle") }
        if model.readerStatus != nil && !model.canSendGlance {
            return ("This reader needs compatible weather & calendar firmware.", .pending, "exclamationmark.triangle")
        }
        if model.activeReaderTask == .weatherCalendar { return ("Applying to reader…", .onReader, "arrow.triangle.2.circlepath") }
        if let error = model.glanceError { return ("Not applied · " + error, .failure, StatusTone.failure.symbol) }
        if settings.hasUnappliedSourceChanges { return ("Saved locally · not applied", .onReader, "circle.dashed") }
        if let sent = model.glanceSentAt {
            return ("Saved on reader at " + sent.formatted(date: .omitted, time: .shortened), .success, "checkmark.circle.fill")
        }
        return (model.readerStatus == nil ? "Saved locally" : "Current sources", .neutral, "info.circle")
    }
    private var canApply: Bool {
        guard !model.isDemoMode, !model.isWorking else { return false }
        if task == .glance { return model.canSendGlance }
        return model.contentEditingSession != nil && validation == nil && revision != nil &&
            revision?.revision != model.readerContentRevision &&
            ContentSendStatus.canSend(cardStatus, busy: model.isWorking, autoSend: false)
    }

    /// Closing or opening connection cannot cancel the debounce and leave the
    /// newest valid local card draft unsaved. Recovery errors remain untouched.
    @MainActor private func persistCardDraft() async {
        guard task == .cards, let cards, !model.isDemoMode, !cards.isDemo else { return }
        if cards.isBusy {
            for await busy in cards.$isBusy.values { if !busy { break } }
        }
        guard cards.hasLoaded, cards.hasUnsavedChanges, cards.lastError == nil else { return }
        do { try await cards.save() } catch { /* The existing draft recovery displays lastError. */ }
    }

    private var applyBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                statusLabel.lineLimit(2)
                Spacer(minLength: 8)
                applyAction
            }
            VStack(alignment: .leading, spacing: 8) {
                statusLabel
                HStack { Spacer(); applyAction }
            }
        }
        .padding(.horizontal, PocketDesign.pageInset).padding(.vertical, 12)
    }

    private var statusLabel: some View {
        PocketStatusLabel(status.text, tone: status.tone, symbol: status.symbol).font(.caption)
            .accessibilityIdentifier("content-editor-status")
    }

    @ViewBuilder private var applyAction: some View {
        if model.readerStatus == nil && !model.isDemoMode {
            Button("Connect Reader…", systemImage: "antenna.radiowaves.left.and.right") {
                Task { await persistCardDraft() }
                connecting = true
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("content-editor-connect")
        } else {
            Button("Apply to Reader") {
                if task == .cards, let revision { _ = model.applyContent(revision) }
                else if task == .glance { model.pushGlance(applyDraft: true) }
            }
            .buttonStyle(.borderedProminent).disabled(!canApply)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityIdentifier("content-editor-apply")
        }
    }
}
