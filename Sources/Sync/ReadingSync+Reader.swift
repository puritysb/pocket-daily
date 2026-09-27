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
}
