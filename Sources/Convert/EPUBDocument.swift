import Foundation

/// Plain text only: callers extracting HTML must supply paragraphs, never markup.
struct EPUBDocument: Sendable {
    struct Chapter: Sendable {
        var title: String
        var paragraphs: [String]
        var sourceURL: URL? = nil
    }

    var title: String
    var language: String = "und"
    var author: String? = nil
    var chapters: [Chapter]
    /// Keep these when regenerating the same publication; output is deterministic for fixed input.
    var identifier: UUID = UUID()
    var modified: Date = Date()
    var articleMetadata: Data? = nil
}

enum EPUBExportError: LocalizedError, Equatable {
    case emptyContent
    case invalidText
    case invalidMetadata
    case invalidSourceURL
    case inputTooLarge
    case tooManySections
    case navigationTooLarge
    case unsplittableCharacter
    case invalidDestination
    case archiveLimit
    case cleanupFailed

    var errorDescription: String? {
        switch self {
        case .emptyContent: "Add a title and at least one non-empty paragraph to every chapter."
        case .invalidText: "This text contains unsupported control characters. Remove them and try again."
        case .invalidMetadata: "Use short titles, a valid language tag, and a valid publication date."
        case .invalidSourceURL: "Use an HTTP or HTTPS source link without a username or password."
        case .inputTooLarge: "This document is too large. Split it into smaller books and try again."
        case .tooManySections: "This book needs too many sections. Split it into smaller books."
        case .navigationTooLarge: "The table of contents is too large. Shorten chapter titles or split the book."
        case .unsplittableCharacter: "One text character is too large to fit a section. Simplify that text and try again."
        case .invalidDestination: "Choose a local folder for the generated book."
        case .archiveLimit: "The generated book exceeds the archive limit. Split it into smaller books."
        case .cleanupFailed: "Export failed and its temporary folder could not be removed. Check the output folder."
        }
    }
}
