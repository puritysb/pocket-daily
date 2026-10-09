import Combine
import Foundation

/// Retained independently of SwiftUI presentation. Switching readers may remove
/// a view, but must not cancel pairing or drop a debounced draft write.
@MainActor
final class ReaderWorkspace {
    let editor = ProfileEditorState()
    let nearby: NearbySyncController
    var preview: ProfileStudioView.PreviewSurface = .home
    private let model: PocketModel
    private let persistence: ProfileDraftPersistence
    private var observers: Set<AnyCancellable> = []
    private var loadTask: Task<Void, Never>?
    private var loading = true
    private var generation = 0
    private var revision = 0
    private var lastSnapshot: ProfileEditSnapshot?

    init(model: PocketModel) {
        self.model = model
        let link = model.bluetoothLink
        nearby = NearbySyncController(ownershipChanged: { link.nearbySessionActive = $0 })
        persistence = ProfileDraftPersistence(store: model.profileEditStore)
        nearby.acceptsPeripheral = { [weak model] id in model?.acceptsPeripheral(id) ?? false }
        nearby.onAuthenticated = { [weak self] peripheral, status in
            guard let self, !model.isDemoMode else { return }
            do { try model.acceptsBluetoothReader(status.deviceID, peripheral) }
            catch {
                link.setup = .failed(error.localizedDescription)
                model.directDiscoveryFailed(error.localizedDescription)
                nearby.disconnect()
                return
            }
            link.remember(peripheral: peripheral, readerID: status.deviceID, model: status.model,
                          supportsReadingSync: status.capabilities.contains(ReadingSyncBLE.capability))
        }
        link.requestSetupConnection = { [weak self] in self?.nearby.scan() }
        link.endSetupConnection = { [weak self] in self?.nearby.disconnect() }
        nearby.$hotspotLease.sink { [weak model] lease in
            if let model, let lease, model.directConnectionRequested { model.useNearbyLease(lease) }
        }.store(in: &observers)
        nearby.$state.sink { [weak self] state in
            guard let self else { return }
            if let message = state.failureMessage {
                if link.setup == .searching { link.setup = .failed(message) }
                else { model.directDiscoveryFailed(message) }
            }
            if case let .connected(status) = state {
                model.selectHardware(named: status.model)
                if model.directConnectionRequested {
                    model.expectDirectReader(status.deviceID)
                    // @Published emits before the state changes. The command needs
                    // the connected state, and must still own this attempt.
                    Task { [weak self] in
                        guard let self, model.directConnectionRequested,
                              nearby.connectedPeripheralID != nil else { return }
                        do { try nearby.requestHotspot() }
                        catch { model.directDiscoveryFailed(error.localizedDescription) }
                    }
                }
            }
        }.store(in: &observers)
        model.$isDemoMode.removeDuplicates().sink { [weak self] demo in self?.load(demo: demo) }.store(in: &observers)
        editor.objectWillChange.debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }.store(in: &observers)
        model.$isWorking.removeDuplicates().sink { [weak self] working in
            guard !working else { return }
            self?.refreshConnectedReader()
        }.store(in: &observers)
        model.$readerStatus.map { $0?.deviceID }.removeDuplicates().sink { [weak self] _ in
            self?.refreshConnectedReader()
        }.store(in: &observers)
    }

    private func refreshConnectedReader() {
        Task { [weak self] in
            guard let self else { return }
            ReadingSync.shared.exchangeWithReader(model: model, library: .shared)
            model.refreshReaderInventoryIfWanted()
        }
    }

    private func comparable(_ snapshot: ProfileEditSnapshot?) -> ProfileEditSnapshot? {
        var value = snapshot
        value?.savedAt = Date(timeIntervalSince1970: 0)
        return value
    }

    private func load(demo: Bool) {
        generation += 1
        revision += 1
        let generation = generation
        loading = true
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            editor.reset()
            editor.localSaveError = nil
            if !demo {
                do {
                    let snapshot = try await persistence.load()
                    guard !Task.isCancelled, self.generation == generation else { return }
                    editor.restore(snapshot)
                    editor.observeTarget(model.readerStatus?.deviceID)
                    editor.sync(with: model.readerProfile)
                    editor.syncReading(model.preferencesBaseline ?? model.preferences)
                } catch {
                    guard !Task.isCancelled, self.generation == generation else { return }
                    editor.localSaveError = error.localizedDescription
                }
            }
            guard !Task.isCancelled, self.generation == generation else { return }
            lastSnapshot = comparable(editor.snapshot)
            loading = false
        }
    }

    func saveNow() { save() }

    private func save() {
        guard !loading, !model.isDemoMode else { return }
        let snapshot = editor.snapshot
        guard comparable(snapshot) != lastSnapshot else { return }
        lastSnapshot = comparable(snapshot)
        revision += 1
        let revision = revision, generation = generation
        Task { [self] in
            do {
                try await persistence.save(snapshot, revision: revision)
                guard self.generation == generation, self.revision == revision else { return }
                editor.localSaveError = nil
            } catch {
                guard self.generation == generation, self.revision == revision else { return }
                editor.localSaveError = error.localizedDescription
                model.post("Your reader settings could not be saved: " + error.localizedDescription, tone: .failure)
            }
        }
    }
}
