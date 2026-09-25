import SwiftUI

/// Draft of the Home & Sleep profile. Lives with the studio so switching
/// between Cards and Home & Sleep keeps unsent edits.
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
        let incoming = reader?.profile ?? .defaults
        guard reader?.generation != baseGeneration || incoming != base else { return }
        if !isDirty || draft == incoming { draft = incoming }
        base = incoming
        baseGeneration = reader?.generation
    }

    func revert() { draft = base }
}

/// Home & Sleep editor: the Pocket Daily layout drawn by the firmware painter
/// with sample content (a schematic when that renderer is unavailable), the
/// profile controls beside it (below it when `stacked`), and one explicit
/// Send to reader. Editing a control shows the surface it changes.
struct ProfileStudioView: View {
    @ObservedObject var model: PocketModel
    @ObservedObject var editor: ProfileEditorState
    var stacked = false
    @State private var preview: PreviewSurface = .home
    @State private var schematic: CGImage?
    @StateObject private var layout = LayoutPreviewModel()

    enum PreviewSurface: String, CaseIterable { case home = "Home", sleep = "Sleep" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sendBar
            let columns = stacked ? AnyLayout(VStackLayout(alignment: .center, spacing: 20))
                                  : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
            columns {
                canvas
                controls
                    .frame(maxWidth: stacked ? .infinity : 340, alignment: .topLeading)
            }
        }
        .onAppear { editor.sync(with: model.readerProfile) }
        .onChange(of: model.readerProfile) { _, reader in editor.sync(with: reader) }
        .task(id: SchematicKey(profile: editor.draft, surface: preview, hardware: model.hardware)) {
            renderSchematic()
            if let request = layoutRequest { await layout.update(request) }
        }
    }

    /// The reader's own sleep screen is not drawn here; the schematic explains it.
    private var layoutRequest: LayoutPreviewRequest? {
        if preview == .sleep && editor.draft.sleep.mode == .reader { return nil }
        guard editor.draft.validationError == nil else { return nil }
        return LayoutPreviewRequest(profile: editor.draft, surface: preview == .home ? .home : .brief,
                                    hardware: model.hardware)
    }

    private var showsRender: Bool { layoutRequest != nil && layout.image != nil }
    private var canvasImage: CGImage? { showsRender ? layout.image : schematic }

    // MARK: Canvas

    private var canvas: some View {
        VStack(spacing: 10) {
            Picker("Preview", selection: $preview) {
                ForEach(PreviewSurface.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            .accessibilityIdentifier("profile-preview-surface")
            PocketDevicePreview(hardware: model.hardware, status: model.readerStatus,
                                screenImageData: nil, renderedScreen: canvasImage)
                .frame(maxWidth: 340)
                .frame(height: 470)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(showsRender
                    ? "Pocket Daily \(preview.rawValue.lowercased()) with sample content"
                    : "Schematic of the Pocket Daily \(preview.rawValue.lowercased()) layout")
                .accessibilityValue(layoutRequest == nil || layout.renderedRequest == layoutRequest ? "Current" : "Updating")
                .accessibilityIdentifier("profile-canvas")
            Label(canvasCaption, systemImage: showsRender ? "text.below.photo" : "square.dashed")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help(showsRender ? "Drawn by the reader's own layout code with sample content. Your reader shows its own books, weather and cards." : "")
                .accessibilityIdentifier("profile-canvas-caption")
        }
        .frame(width: stacked ? nil : 340)
    }

    private var canvasCaption: String {
        if showsRender { return "Sample content" }
        if layoutRequest != nil, layout.error != nil { return "Layout outline · preview unavailable" }
        return "Layout outline"
    }

    // MARK: Send bar

    private var status: (text: String, symbol: String, color: Color) {
        if model.isDemoMode { return ("Demo · nothing is sent", "info.circle", .secondary) }
        if model.readerStatus == nil { return ("Connect a reader to send", "info.circle", .secondary) }
        if !model.canEditReaderProfile {
            return ("This reader's firmware can't store Home & Sleep yet", "exclamationmark.triangle", .orange)
        }
        if let error = editor.draft.validationError { return (error, "exclamationmark.triangle", .red) }
        switch model.profileSend {
        case .sending: return ("Saving on the reader…", "arrow.triangle.2.circlepath", .secondary)
        case .conflict: return ("Changed on the reader · its version was loaded", "exclamationmark.triangle", .orange)
        case let .failed(message) where editor.isDirty: return ("Not saved · \(message)", "xmark.octagon", .red)
        default: break
        }
        if model.readerProfile == nil { return ("Loading the reader's settings…", "arrow.triangle.2.circlepath", .secondary) }
        if editor.isDirty { return ("Changes not sent", "circle.dashed", .orange) }
        return ("Saved on reader · shows next time Pocket Daily opens", "checkmark.circle.fill", .green)
    }

    private var canSend: Bool {
        model.canEditReaderProfile && model.readerProfile != nil && editor.isDirty &&
            editor.draft.validationError == nil && !model.isWorking
    }

    /// One line when it fits; otherwise the status above the buttons.
    private var sendBar: some View {
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

    @ViewBuilder private var sendControls: some View {
        Button("Revert") { editor.revert() }
            .disabled(!editor.isDirty || model.isWorking)
            .accessibilityIdentifier("profile-revert")
        Button {
            model.sendProfile(editor.draft)
        } label: {
            Label("Send", systemImage: "paperplane.fill")
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canSend)
        .help("Send to reader (⌘↩)")
        .accessibilityIdentifier("profile-send")
    }

    // MARK: Controls

    /// Writes one part of the draft and shows the surface it changes.
    private func edit<Value>(_ key: WritableKeyPath<PocketProfile, Value>, on surface: PreviewSurface) -> Binding<Value> {
        Binding(get: { editor.draft[keyPath: key] },
                set: { editor.draft[keyPath: key] = $0; preview = surface })
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            ControlGroup(title: "Home", note: "Up to \(PocketProfile.maxHomeItems), in page order") {
                OrderedToggleList(selection: edit(\.home.items, on: .home), identifier: "profile-home",
                                  title: { $0.title }, detail: { $0.detail })
                Toggle("Daily word when there are no cards", isOn: edit(\.home.dailyWord, on: .home))
                    .accessibilityIdentifier("profile-daily-word")
            }
            ControlGroup(title: "Weather") {
                Picker("Weather", selection: edit(\.home.weather, on: .home)) {
                    ForEach(PocketProfile.WeatherPanel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("profile-weather")
                Toggle("Next event", isOn: edit(\.home.nextEvent, on: .home))
                    .disabled(editor.draft.home.weather == .off)
                    .accessibilityIdentifier("profile-next-event")
            }
            ControlGroup(title: "Sleep", note: editor.draft.sleep.mode == .brief ? "Top to bottom" : nil) {
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
                    OrderedToggleList(selection: edit(\.sleep.sections, on: .sleep), identifier: "profile-sleep",
                                      title: { $0.title }, detail: { _ in nil })
                }
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

    // MARK: Schematic

    private struct SchematicKey: Equatable {
        let profile: PocketProfile
        let surface: PreviewSurface
        let hardware: PocketHardware
    }

    private func renderSchematic() {
        let size = CGSize(width: model.hardware.screenWidth, height: model.hardware.screenHeight)
        let renderer = ImageRenderer(content: PocketLayoutSchematic(profile: editor.draft, surface: preview)
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

/// Every case of `Item`; enabled ones first in their order, each with a toggle
/// and up/down controls. Disabling the last enabled item is not offered.
struct OrderedToggleList<Item: Hashable & CaseIterable & RawRepresentable>: View where Item.AllCases: RandomAccessCollection, Item.RawValue == String {
    @Binding var selection: [Item]
    let identifier: String
    let title: (Item) -> String
    let detail: (Item) -> String?

    private var rows: [Item] { selection + Item.allCases.filter { !selection.contains($0) } }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows, id: \.self) { item in
                let index = selection.firstIndex(of: item)
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(
                        get: { index != nil },
                        set: { on in
                            if on, index == nil { selection.append(item) }
                            if !on, let index, selection.count > 1 { selection.remove(at: index) }
                        }))
                        .labelsHidden()
                        .toggleStyle(CheckToggleStyle())
                        .disabled(index != nil && selection.count == 1)
                        .accessibilityLabel(title(item))
                    (Text(index.map { "\($0 + 1). " } ?? "").monospacedDigit() + Text(title(item)))
                        .foregroundStyle(index == nil ? .secondary : .primary)
                    Spacer()
                    if let index {
                        Button { selection.swapAt(index, index - 1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                            .accessibilityLabel("Move \(title(item)) up")
                        Button { selection.swapAt(index, index + 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index + 1 >= selection.count)
                            .accessibilityLabel("Move \(title(item)) down")
                    }
                }
                .help(detail(item) ?? "")
                .buttonStyle(.borderless)
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .accessibilityIdentifier("\(identifier)-\(item.rawValue)")
                Divider()
            }
        }
        .background(PocketPalette.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A native checkbox on macOS; a check circle elsewhere, which reads better
/// than a switch inside a reorderable list.
private struct CheckToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
#if os(macOS)
        Toggle(configuration).toggleStyle(.checkbox)
#else
        Button { configuration.isOn.toggle() } label: {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(configuration.isOn ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
#endif
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
