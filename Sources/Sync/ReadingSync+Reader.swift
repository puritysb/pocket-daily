import Foundation

extension ReadingSync {
    /// Runs one exchange with the connected reader for the current library.
    func exchangeWithReader(model: PocketModel, library: LibraryModel, force: Bool = false) {
        guard readerExchangeEnabled else { return }
        model.exchangeReadingPositions(force: force) { [weak self, weak library] list, reader in
            self?.exchange(with: list, readerName: reader, library: library?.books ?? []) ?? []
        } finish: { [weak self] reader, sent, error in
            self?.exchangeFinished(readerName: reader, sent: sent, error: error)
        }
    }

    /// Connects `nudgeReader` to the model: a connected reader exchanges again
    /// at once; otherwise the last reader is tried quietly at its last address.
    func attachReader(model: PocketModel, library: LibraryModel) {
        readerNudges[ObjectIdentifier(model)] = { [weak self, weak model, weak library] interval in
            guard let self, let model, let library else { return false }
            if model.readerStatus != nil {
                exchangeWithReader(model: model, library: library, force: true)
                return true
            }
            model.quietReadingExchange(minimumInterval: interval) { [weak self, weak library] list, reader in
                self?.exchange(with: list, readerName: reader, library: library?.books ?? []) ?? []
            } finish: { [weak self] reader, sent, error in
                self?.exchangeFinished(readerName: reader, sent: sent, error: error)
            }
            return true
        }
        readerNudge = { [weak self] interval in
            guard let self else { return }
            for (key, nudge) in readerNudges where !nudge(interval) { readerNudges.removeValue(forKey: key) }
        }
    }
}
