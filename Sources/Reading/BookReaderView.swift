import SwiftUI

/// Resolves a library book and presents it full screen (iOS) or in its own
/// window (macOS).
struct ReaderContainer: View {
    let bookID: UUID
    @ObservedObject var library: LibraryModel
    @ObservedObject var sync: ReadingSync
    var close: () -> Void

    @State private var session: ReaderSession?
    @State private var failure: String?

    var body: some View {
        Group {
            if let session, let book = library.book(bookID) {
                BookReaderView(book: book, session: session, library: library, sync: sync, close: close)
            } else if let failure {
                ContentUnavailableView {
                    Label("Can't open this book", systemImage: "book.closed")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Close", action: close)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ReaderAppearanceStore.shared.appearance.theme.background.ignoresSafeArea())
        .task(id: bookID) { await prepare() }
    }

    private func prepare() async {
        if library.books.isEmpty { await library.load() }
        guard let book = library.book(bookID) else {
            failure = LibraryError.missing.localizedDescription
            return
        }
        do {
            let url = try await library.fileURL(for: book)
            let session = ReaderSession(bookFile: url, appearance: ReaderAppearanceStore.shared.appearance)
            session.open(at: book.position)
            self.session = session
            library.markOpened(book.id)
        } catch {
            failure = error.localizedDescription
        }
    }
}

struct BookReaderView: View {
    let book: LibraryBook
    @ObservedObject var session: ReaderSession
    @ObservedObject var library: LibraryModel
    @ObservedObject var sync: ReadingSync
    var close: () -> Void

    @ObservedObject private var appearanceStore = ReaderAppearanceStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var showingContents = false
    @State private var showingAppearance = false
    @State private var scrubbing: Double?
    @State private var suggestion: ReadingSync.Suggestion?
    @State private var pendingLink: URL?

    private var theme: ReaderAppearance.Theme { appearanceStore.appearance.theme }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                theme.background.ignoresSafeArea()
                ReaderWebView(session: session)
                    .ignoresSafeArea()
                    .opacity(session.phase == .ready ? 1 : 0)
                    .accessibilityIdentifier("reader-page")
                    .onAppear { updateInsets(proxy) }
                    .onChange(of: proxy.safeAreaInsets) { _, _ in updateInsets(proxy) }
                phaseOverlay
                if session.chromeVisible || session.phase != .ready {
                    chrome.transition(.opacity)
                } else {
                    footerHint
                }
                if let suggestion {
                    VStack {
                        Spacer()
                        suggestionBanner(suggestion)
                            .padding(.bottom, session.chromeVisible ? 96 : 24)
                    }
                    .padding(.horizontal)
                }
            }
        }
        .foregroundStyle(theme.foreground)
        .preferredColorScheme(theme.colorScheme)
#if os(iOS)
        .statusBarHidden(!session.chromeVisible)
        .persistentSystemOverlays(session.chromeVisible ? .automatic : .hidden)
#endif
        .animation(.easeOut(duration: 0.15), value: session.chromeVisible)
        .sheet(isPresented: $showingContents) { contents }
        .sheet(isPresented: $showingAppearance) {
            ReaderAppearancePanel(store: appearanceStore)
                .presentationDetents([.medium])
        }
        .confirmationDialog("Open this link in your browser?", isPresented: Binding(
            get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }), titleVisibility: .visible) {
                if let pendingLink {
                    Button("Open \(pendingLink.host ?? pendingLink.absoluteString)") { openURL(pendingLink) }
                }
        }
        .onChange(of: appearanceStore.appearance) { _, value in session.apply(value) }
        .onChange(of: session.phase) { _, phase in
            if phase == .ready { Task { await checkRemote() } }
        }
        .onChange(of: sync.remoteRevision) { _, _ in Task { await checkRemote() } }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await leave(pushing: true) } }
            else { Task { await checkRemote() } }
        }
        .onAppear {
            session.onPosition = { position in
                library.savePosition(position, for: book.id)
                sync.positionChanged(position, for: book)
            }
            session.onExternalLink = { pendingLink = $0 }
            session.onEscape = { finish() }
        }
        .onDisappear { Task { await leave(pushing: true) } }
    }

    // MARK: Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                Button(action: finish) {
                    Image(systemName: "chevron.backward").font(.body.weight(.semibold))
                }
                .accessibilityLabel("Library")
                .accessibilityIdentifier("reader-close")
                .keyboardShortcut(.cancelAction)
                Spacer(minLength: 8)
                Text(book.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button { showingContents = true } label: { Image(systemName: "list.bullet") }
                    .accessibilityLabel("Contents")
                    .disabled(session.toc.isEmpty)
                Button { showingAppearance = true } label: { Image(systemName: "textformat.size") }
                    .accessibilityLabel("Text and page")
                    .accessibilityIdentifier("reader-appearance")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(theme.background.opacity(0.97))
            Divider().opacity(0.4)
            Spacer()
            Divider().opacity(0.4)
            VStack(spacing: 6) {
                HStack {
                    Text(session.position?.chapter ?? " ").lineLimit(1)
                    Spacer()
                    Text(percent(scrubbing ?? session.position?.fraction ?? book.progress))
                        .monospacedDigit()
                        .accessibilityIdentifier("reader-progress")
                }
                .font(.caption)
                Slider(value: Binding(
                    get: { scrubbing ?? session.position?.fraction ?? book.progress },
                    set: { scrubbing = $0 }
                ), in: 0...1) { editing in
                    if !editing, let value = scrubbing {
                        session.go(toFraction: value)
                        scrubbing = nil
                    }
                }
                .tint(theme.foreground.opacity(0.7))
                .accessibilityLabel("Book position")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(theme.background.opacity(0.97))
        }
        .disabled(session.phase != .ready && !isFailed)
    }

    /// While reading, only the progress shows, like a reader's status line.
    private var footerHint: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text(percent(session.position?.fraction ?? book.progress))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(theme.foreground.opacity(0.45))
                    .accessibilityIdentifier("reader-progress")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private var phaseOverlay: some View {
        switch session.phase {
        case .loading:
            ProgressView().controlSize(.large)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can't open this book", systemImage: "book.closed")
            } description: {
                Text(message)
            } actions: {
                Button("Back to Library", action: finish)
            }
        case .ready:
            EmptyView()
        }
    }

    private var isFailed: Bool {
        if case .failed = session.phase { true } else { false }
    }

    private var contents: some View {
        NavigationStack {
            List(session.toc) { item in
                Button {
                    session.go(to: item.href)
                    showingContents = false
                    session.chromeVisible = false
                } label: {
                    Text(item.label)
                        .padding(.leading, CGFloat(item.depth) * 16)
                        .foregroundStyle(item.label == session.position?.chapter ? Color.accentColor : .primary)
                }
            }
            .navigationTitle("Contents")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { showingContents = false } }
            }
        }
#if os(macOS)
        .frame(minWidth: 380, minHeight: 480)
#endif
    }

    private func suggestionBanner(_ suggestion: ReadingSync.Suggestion) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.kind == .lastRead
                     ? "\(suggestion.device) last read at \(percent(suggestion.position.fraction))"
                     : "\(suggestion.device) read further, to \(percent(suggestion.position.fraction))")
                    .font(.subheadline.weight(.semibold))
                Text("You're at \(percent(session.position?.fraction ?? book.progress)) here.")
                    .font(.caption)
            }
            Spacer()
            Button("Go") {
                session.go(to: suggestion.position)
                self.suggestion = nil
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("reader-sync-go")
            Button {
                sync.dismiss(suggestion)
                self.suggestion = nil
            } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Stay here")
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.primary)
    }

    // MARK: Actions

    private func updateInsets(_ proxy: GeometryProxy) {
        session.setInsets(top: proxy.safeAreaInsets.top, bottom: proxy.safeAreaInsets.bottom)
    }

    private func checkRemote() async {
        guard session.phase == .ready else { return }
        suggestion = await sync.suggestion(for: book, current: session.position ?? book.position)
    }

    private func leave(pushing: Bool) async {
        await library.flushPositions()
        if pushing, let position = session.position { await sync.pushNow(position, for: book) }
    }

    private func finish() {
        Task { await leave(pushing: true) }
        close()
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }
}

struct ReaderAppearancePanel: View {
    @ObservedObject var store: ReaderAppearanceStore

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Button { store.appearance.stepFont(-1) } label: {
                            Image(systemName: "textformat.size.smaller").frame(maxWidth: .infinity)
                        }
                        .accessibilityLabel("Smaller text")
                        Text("\(store.appearance.fontScale)%").monospacedDigit().frame(minWidth: 56)
                        Button { store.appearance.stepFont(1) } label: {
                            Image(systemName: "textformat.size.larger").frame(maxWidth: .infinity)
                        }
                        .accessibilityLabel("Larger text")
                    }
                    .buttonStyle(.bordered)
                    Picker("Font", selection: $store.appearance.fontFamily) {
                        ForEach(ReaderAppearance.FontFamily.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Page") {
                    Picker("Color", selection: $store.appearance.theme) {
                        ForEach(ReaderAppearance.Theme.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Line spacing", selection: $store.appearance.lineHeight) {
                        ForEach(ReaderAppearance.lineHeights, id: \.self) {
                            Text($0.formatted(.number.precision(.fractionLength(1...2)))).tag($0)
                        }
                    }
                    Picker("Margins", selection: $store.appearance.margin) {
                        ForEach(ReaderAppearance.Margin.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Justify text", isOn: $store.appearance.justify)
                    Toggle("Hyphenate", isOn: $store.appearance.hyphenate)
                    Toggle("Two pages when wide", isOn: $store.appearance.allowsTwoColumns)
                }
            }
            .navigationTitle("Text & Page")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
#if os(macOS)
        .frame(minWidth: 360, minHeight: 420)
#endif
    }
}
