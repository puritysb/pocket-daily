import CryptoKit
import Foundation

/// Brings the reader's active card set back into the editor (sibling
/// docs/content-read-v1.md). Every byte is verified here: the manifest against
/// the revision ID (its SHA-256) and each file against the manifest, so a
/// partial, stale or altered read never becomes a draft. Nothing on the reader
/// changes.
enum ReaderContentPull {
    enum Failure: LocalizedError, Equatable {
        case integrity(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case let .integrity(file): "The reader's cards could not be verified (\(file)). Nothing was changed; try loading again."
            case let .unsupported(file): "The reader holds content this app cannot edit (\(file)). Nothing was changed."
            }
        }
    }

    /// Largest manifest the format allows (16 entries).
    static let maximumManifestBytes = 20 + 104 * 16

    /// `read(name, offset)` returns the next chunk of one file of `revision`.
    static func draft(revision: String,
                      read: (_ name: String, _ offset: Int) async throws -> Data) async throws -> ContentDraft {
        let manifestBytes = try await readManifest(read)
        guard ContentManifest.revision(of: manifestBytes) == revision else { throw Failure.integrity("manifest.pdcm") }
        let manifest: ContentManifest.Decoded
        do { manifest = try ContentManifest.decode(manifestBytes) } catch { throw Failure.unsupported("manifest.pdcm") }

        var cards: [ContentCard] = []
        var images: [String: Data] = [:]
        // Manifest order is filename order, which keeps the app's card order.
        for file in manifest.files {
            let data = try await readFile(file.path, bytes: Int(file.bytes), read: read)
            guard Data(SHA256.hash(data: data)) == file.sha256 else { throw Failure.integrity(file.path) }
            switch file.kind {
            case .card:
                do { cards.append(try ContentCard.decode(data)) } catch { throw Failure.unsupported(file.path) }
            case .monoImage:
                do { _ = try ContentImage.decode(data) } catch { throw Failure.unsupported(file.path) }
                images[file.path] = data
            }
        }
        let draft = ContentDraft(cards: cards, images: images)
        do { try ContentDraftFile.validate(draft) } catch { throw Failure.unsupported("card set") }
        return draft
    }

    private static func readManifest(_ read: (String, Int) async throws -> Data) async throws -> Data {
        var data = Data()
        var declared = maximumManifestBytes
        while data.count < declared {
            try Task.checkCancellation()
            let chunk = try await read("manifest.pdcm", data.count)
            guard !chunk.isEmpty, data.count + chunk.count <= maximumManifestBytes else {
                throw Failure.integrity("manifest.pdcm")
            }
            data.append(chunk)
            if data.count >= 16 {
                let bytes = [UInt8](data.prefix(16))
                declared = Int(bytes[12]) | Int(bytes[13]) << 8 | Int(bytes[14]) << 16 | Int(bytes[15]) << 24
                guard declared >= 20, declared <= maximumManifestBytes, data.count <= declared else {
                    throw Failure.integrity("manifest.pdcm")
                }
            }
        }
        return data
    }

    private static func readFile(_ name: String, bytes: Int,
                                 read: (String, Int) async throws -> Data) async throws -> Data {
        var data = Data()
        data.reserveCapacity(bytes)
        while data.count < bytes {
            try Task.checkCancellation()
            let chunk = try await read(name, data.count)
            guard !chunk.isEmpty, data.count + chunk.count <= bytes else { throw Failure.integrity(name) }
            data.append(chunk)
        }
        return data
    }
}
