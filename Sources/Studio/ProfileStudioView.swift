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

/// Home & Sleep editor: a schematic of the reader's Pocket Daily layout on the
/// canvas, the profile controls beside it, and one explicit Send to reader.
struct ProfileStudioView: View {
    @ObservedObject var model: PocketModel
    @ObservedObject var editor: ProfileEditorState
    @State private var preview: PreviewSurface = .home
    @State private var schematic: CGImage?

    enum PreviewSurface: String, CaseIterable { case home = "Home", sleep = "Sleep" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            sendBar
            HStack(alignment: .top, spacing: 26) {
                VStack(spacing: 12) {
                    Picker("Preview", selection: $preview) {
                        ForEach(PreviewSurface.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("profile-preview-surface")
                    PocketDevicePreview(hardware: model.hardware, status: model.readerStatus,
                                        screenImageData: nil, renderedScreen: schematic)
                        .frame(maxWidth: 360)
                        .frame(height: 500)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Schematic of the Pocket Daily \(preview.rawValue.lowercased()) layout")
                        .accessibilityIdentifier("profile-canvas")
                    Label("Layout schematic. The reader draws the real content and fonts.", systemImage: "square.dashed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 380)
                controls
                    .frame(maxWidth: 360, alignment: .topLeading)
            }
        }
        .onAppear { editor.sync(with: model.readerProfile) }
        .onChange(of: model.readerProfile) { _, reader in editor.sync(with: reader) }
        .task(id: SchematicKey(profile: editor.draft, surface: preview, hardware: model.hardware)) { renderSchematic() }
    }

    // MARK: Send bar

    private var status: (text: String, symbol: String, color: Color) {
        if model.isDemoMode { return ("Demo · nothing is sent to a reader", "info.circle", .secondary) }
        if model.readerStatus == nil { return ("Connect a reader to send", "info.circle", .secondary) }
        if !model.canEditReaderProfile {
            return ("This reader's firmware cannot store Home & Sleep settings yet", "exclamationmark.triangle", .orange)
        }
        if let error = editor.draft.validationError { return (error, "exclamationmark.triangle", .red) }
        switch model.profileSend {
        case .sending: return ("Saving on the reader…", "arrow.triangle.2.circlepath", .secondary)
        case .conflict: return ("The reader changed these settings; its latest version was loaded", "exclamationmark.triangle", .orange)
        case let .failed(message) where editor.isDirty: return ("Not saved · \(message)", "xmark.octagon", .red)
        default: break
        }
        if model.readerProfile == nil { return ("Loading the reader's settings…", "arrow.triangle.2.circlepath", .secondary) }
        if editor.isDirty { return ("Changes not sent", "circle.dashed", .orange) }
        return ("Saved on reader · applies when Pocket Daily opens", "checkmark.circle.fill", .green)
    }

    private var canSend: Bool {
        model.canEditReaderProfile && model.readerProfile != nil && editor.isDirty &&
            editor.draft.validationError == nil && !model.isWorking
    }

    private var sendBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Home & Sleep").font(.title2.weight(.semibold))
                Label(status.text, systemImage: status.symbol)
                    .font(.callout)
                    .foregroundStyle(status.color)
                    .accessibilityIdentifier("profile-status")
            }
            Spacer()
            Button("Revert") { editor.revert() }
                .disabled(!editor.isDirty || model.isWorking)
                .accessibilityIdentifier("profile-revert")
            Button {
                model.sendProfile(editor.draft)
            } label: {
                Label("Send to reader", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend)
            .accessibilityIdentifier("profile-send")
        }
        .padding(16)
        .background(PocketPalette.panel, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Home items").font(.headline)
                Text("Order sets how the side buttons page through Home. Up to \(PocketProfile.maxHomeItems) appear.")
                    .font(.caption).foregroundStyle(.secondary)
                OrderedToggleList(selection: $editor.draft.home.items, identifier: "profile-home",
                                  title: { $0.title }, detail: { $0.detail })
                Toggle("Show the daily word when there are no app cards", isOn: $editor.draft.home.dailyWord)
                    .font(.callout)
                    .accessibilityIdentifier("profile-daily-word")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Weather panel").font(.headline)
                Picker("Weather panel", selection: $editor.draft.home.weather) {
                    ForEach(PocketProfile.WeatherPanel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("profile-weather")
                Toggle("Show the next event line", isOn: $editor.draft.home.nextEvent)
                    .font(.callout)
                    .disabled(editor.draft.home.weather == .off)
                    .accessibilityIdentifier("profile-next-event")
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Sleep screen").font(.headline)
                Picker("Sleep screen", selection: $editor.draft.sleep.mode) {
                    ForEach(PocketProfile.SleepMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("profile-sleep-mode")
                if editor.draft.sleep.mode == .reader {
                    Text("Uses the Sleep Screen chosen in the reader's own settings instead of the Daily Brief.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Daily Brief sections, top to bottom. Study shows only when no book is open.")
                        .font(.caption).foregroundStyle(.secondary)
                    OrderedToggleList(selection: $editor.draft.sleep.sections, identifier: "profile-sleep",
                                      title: { $0.title }, detail: { _ in nil })
                }
            }
            Button("Use the original layout") { editor.draft = .defaults }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(editor.draft == .defaults)
        }
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
#if os(macOS)
                        .toggleStyle(.checkbox)
#endif
                        .disabled(index != nil && selection.count == 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(index.map { "\($0 + 1). " } ?? "").font(.callout.monospacedDigit()) +
                            Text(title(item)).font(.callout)
                        if let text = detail(item) { Text(text).font(.caption2).foregroundStyle(.secondary) }
                    }
                    .foregroundStyle(index == nil ? .secondary : .primary)
                    Spacer()
                    if let index {
                        Button { selection.swapAt(index, index - 1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                        Button { selection.swapAt(index, index + 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index + 1 >= selection.count)
                    }
                }
                .buttonStyle(.borderless)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .accessibilityIdentifier("\(identifier)-\(item.rawValue)")
                Divider()
            }
        }
        .background(PocketPalette.panel, in: RoundedRectangle(cornerRadius: 10))
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
