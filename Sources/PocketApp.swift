import SwiftUI

@main
struct PocketApp: App {
    @StateObject private var fleet: ReaderFleet

    init() {
#if DEBUG && os(macOS)
        if ProcessInfo.processInfo.arguments.contains("--developer-fresh-start") {
            do {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                let domains = try DeveloperFreshStart.domains(root: support.appendingPathComponent("Pocket"))
                _ = try DeveloperFreshStart.reset(root: support.appendingPathComponent("Pocket"), domains: domains)
                print("POCKET_FRESH_START completed; local data archived, settings cleared")
            } catch {
                print("POCKET_FRESH_START failed; existing data or backup preserved")
                exit(1)
            }
        }
#endif
        // Before any scene: a background relaunch for a restored Bluetooth
        // connection must recreate the reading-sync central at once.
        let fleet = ReaderFleet()
        _fleet = StateObject(wrappedValue: fleet)
#if DEBUG
        ReaderDevelopmentContext.model = fleet.selected?.model
#endif
    }

    var body: some Scene {
        WindowGroup {
#if DEBUG && os(iOS)
            if ProcessInfo.processInfo.arguments.contains("--ui-test-article-share") {
                ArticleShareTestHost()
            } else {
                mainView
            }
#else
            mainView
#endif
        }
#if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands { PocketSettingsCommands() }
#endif
    }

    private var mainView: some View {
        ReaderFleetView(fleet: fleet)
            // Selection is amber on every platform; iOS switches otherwise
            // stay system green while macOS follows the accent color.
            .tint(PocketPalette.accent)
#if os(macOS)
            .frame(minWidth: 1080, minHeight: 720)
#endif
    }
}

#if os(macOS)
private struct SettingsPresentationKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var settingsPresentation: Binding<Bool>? {
        get { self[SettingsPresentationKey.self] }
        set { self[SettingsPresentationKey.self] = newValue }
    }
}

private struct PocketSettingsCommands: Commands {
    @FocusedBinding(\.settingsPresentation) private var showingSettings: Bool?

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { showingSettings = true }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(showingSettings == nil)
        }
    }
}
#endif

#if DEBUG && os(macOS)
/// Explicit local developer command, before any model can rewrite saved state.
/// Uses the app's own sandbox access; never available in a distribution build.
enum DeveloperFreshStart {
    enum ResetError: Error { case unavailableDefaults, settingsNotCleared }

    static func domains(root: URL) throws -> [String] {
        var names = [Bundle.main.bundleIdentifier ?? "bound.serendipity.pocket.daily"]
        let registry = ReaderRegistryStore(file: root.appendingPathComponent("Readers/readers.json"))
        for reader in try registry.load() ?? [] {
            if !reader.usesLegacyStorage { names.append("Pocket.reader." + reader.id.uuidString) }
        }
        return names
    }

    static func defaults(for domain: String) throws -> UserDefaults {
        if domain == Bundle.main.bundleIdentifier { return .standard }
        guard let defaults = UserDefaults(suiteName: domain) else { throw ResetError.unavailableDefaults }
        return defaults
    }

    @discardableResult
    static func reset(root: URL, domains: [String]) throws -> URL {
        let manager = FileManager.default
        let backup = root.deletingLastPathComponent()
            .appendingPathComponent("PocketFirstInstallBackups/" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: backup, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        // Finish every preference backup before moving books or clearing a key.
        for domain in domains {
            let defaults = try Self.defaults(for: domain)
            let values = defaults.persistentDomain(forName: domain) ?? [:]
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            try data.write(to: backup.appendingPathComponent(domain + ".plist"), options: .atomic)
        }
        if manager.fileExists(atPath: root.path) {
            try manager.moveItem(at: root, to: backup.appendingPathComponent("Pocket", isDirectory: true))
        }
        for domain in domains {
            let defaults = try Self.defaults(for: domain)
            defaults.removePersistentDomain(forName: domain)
            guard defaults.synchronize(), defaults.persistentDomain(forName: domain)?.isEmpty != false else {
                throw ResetError.settingsNotCleared
            }
        }
        return backup
    }
}
#endif
