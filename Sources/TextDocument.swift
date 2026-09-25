import Foundation

/// Writes text the user typed or pasted as a .txt file the reader can open.
/// The file lives in the app's caches until it is prepared (copied) for sending.
enum TextDocument {
    enum Failure: LocalizedError, Equatable {
        case empty, tooLarge
        var errorDescription: String? {
            switch self {
            case .empty: "Enter some text to send."
            case .tooLarge: "This text is larger than 4 MB. Split it into smaller parts."
            }
        }
    }

    static let maximumBytes = 4 * 1024 * 1024

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pocket/Text", isDirectory: true)
    }

    /// A reader-safe file name: letters, digits, spaces, dashes and underscores;
    /// a dated name when the title has none of those.
    static func filename(for title: String, now: Date = Date()) -> String {
        let allowed = title.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == " " || scalar == "-" || scalar == "_"
                ? Character(scalar) : " "
        }
        let words = String(allowed).split(separator: " ").joined(separator: " ")
        let stem = String(words.prefix(60)).trimmingCharacters(in: .whitespaces)
        if !stem.isEmpty { return stem + ".txt" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "Note " + formatter.string(from: now) + ".txt"
    }

    static func write(title: String, text: String, directory: URL = directory) throws -> URL {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw Failure.empty }
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = heading.isEmpty ? body + "\n" : heading + "\n\n" + body + "\n"
        let data = Data(content.utf8)
        guard data.count <= maximumBytes else { throw Failure.tooLarge }
        // One fresh folder per document keeps names readable and never collides.
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(filename(for: heading))
        try data.write(to: url, options: .atomic)
        return url
    }
}
