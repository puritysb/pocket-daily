import CryptoKit
import Foundation

/// Immutable, locally validated deployment input. This is not a device receipt.
struct ContentRevision {
    struct Asset {
        let path: String
        let kind: ContentManifest.Kind
        let data: Data
        let sha256: Data
    }
    let files: [Asset]
    let manifest: Data
    let revision: String
    let requiredCapabilities: UInt16
    enum ValidationError: Error { case count, duplicateID, missingImage(String), unusedImage, imagePath }

    init(cards: [ContentCard], images: [String: Data] = [:]) throws {
        guard cards.count <= 3, cards.count + images.count <= 16 else { throw ValidationError.count }
        guard Set(cards.map(\.id)).count == cards.count else { throw ValidationError.duplicateID }
        let references = Set(cards.map(\.imagePath).filter { !$0.isEmpty })
        for path in references where images[path] == nil { throw ValidationError.missingImage(path) }
        guard Set(images.keys) == references else { throw ValidationError.unusedImage }
        var assets: [Asset] = []
        for (index, card) in cards.enumerated() {
            let data = try card.encoded()
            // Numeric prefix preserves editor order under canonical manifest sort.
            let path = String(format: "card-%02d-", index) + card.id + ".card"
            assets.append(.init(path: path, kind: .card, data: data, sha256: Data(SHA256.hash(data: data))))
        }
        for path in images.keys.sorted() {
            guard ContentManifest.validPath(path, kind: .monoImage), let data = images[path] else {
                throw ValidationError.imagePath
            }
            _ = try ContentImage.decode(data)
            assets.append(.init(path: path, kind: .monoImage, data: data, sha256: Data(SHA256.hash(data: data))))
        }
        let hasLayout = cards.contains { $0.layout != .textFirst }
        let manifest = try ContentManifest.encode(assets.map {
            .init(path: $0.path, kind: $0.kind, bytes: UInt32($0.data.count), sha256: $0.sha256)
        }, cardLayout: hasLayout)
        self.requiredCapabilities = 1 | (images.isEmpty ? 0 : 2) | (hasLayout ? 4 : 0)
        self.files = assets.sorted { $0.path < $1.path }
        self.manifest = manifest
        self.revision = ContentManifest.revision(of: manifest)
    }

    /// A local difference plan only. Transport must still establish which files
    /// the identified reader actually has before skipping uploads or applying.
    func changedFiles(from previous: ContentRevision?) -> [Asset] {
        guard let previous else { return files }
        let old = Dictionary(uniqueKeysWithValues: previous.files.map { ($0.path, $0) })
        return files.filter { old[$0.path]?.sha256 != $0.sha256 || old[$0.path]?.kind != $0.kind }
    }
}
