import Foundation

/// Fixed-size PDCT reading card. Default layout stays byte-exact v1; alternate
/// layouts require v2 and capability4. No executable/provider commands.
/// Byte limits match firmware PocketDaily::Card; never truncate UTF-8 silently.
struct ContentCard: Equatable, Codable, Sendable {
    var id: String
    var title: String
    var question: String
    var context: String = ""
    var imagePath: String = ""
    var layout: Layout = .textFirst

    enum Layout: UInt8, Codable, CaseIterable, Sendable {
        case textFirst = 0, imageFirst = 1, sideBySide = 2
        var title: String {
            switch self {
            case .textFirst: "Text first"
            case .imageFirst: "Image first"
            case .sideBySide: "Side by side"
            }
        }
    }

    init(id: String, title: String, question: String, context: String = "", imagePath: String = "", layout: Layout = .textFirst) {
        self.id = id
        self.title = title
        self.question = question
        self.context = context
        self.imagePath = imagePath
        self.layout = layout
    }

    private enum CodingKeys: String, CodingKey { case id, title, question, context, imagePath, layout }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        question = try values.decode(String.self, forKey: .question)
        context = try values.decode(String.self, forKey: .context)
        imagePath = try values.decode(String.self, forKey: .imagePath)
        layout = try values.decodeIfPresent(Layout.self, forKey: .layout) ?? .textFirst
    }

    enum ValidationError: Error, Equatable {
        case identifier, text(field: String, maximumBytes: Int), imagePath
    }

    func encoded() throws -> Data {
        let identifier = Array(id.utf8)
        guard !identifier.isEmpty, identifier.count <= 32,
              identifier.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw ValidationError.identifier
        }
        try validateText(title, field: "title", maximum: 24, required: true, multiline: false)
        try validateText(question, field: "question", maximum: 160, required: true, multiline: true)
        try validateText(context, field: "context", maximum: 191, required: false, multiline: true)
        guard imagePath.isEmpty || ContentManifest.validPath(imagePath, kind: .monoImage) else {
            throw ValidationError.imagePath
        }
        var data = Data(repeating: 0, count: 512)
        data.replaceSubrange(0..<4, with: "PDCT".utf8)
        data[4] = layout == .textFirst ? 1 : 2
        data[491] = layout.rawValue
        data[6] = 16
        data[9] = 2 // 512, little-endian
        for (offset, value) in [(16, id), (49, title), (74, question), (235, context), (427, imagePath)] {
            data.replaceSubrange(offset..<(offset + value.utf8.count), with: value.utf8)
        }
        let crc = ContentManifest.crc32(data.prefix(508))
        for i in 0..<4 { data[508 + i] = UInt8(truncatingIfNeeded: crc >> (8 * i)) }
        return data
    }

    private func validateText(_ value: String, field: String, maximum: Int, required: Bool, multiline: Bool) throws {
        guard (!required || !value.isEmpty), value.utf8.count <= maximum,
              value.unicodeScalars.allSatisfy({ scalar in
                  let code = scalar.value
                  return (code >= 0x20 && !(0x7F...0x9F).contains(code)) || (multiline && code == 10)
              }) else {
            throw ValidationError.text(field: field, maximumBytes: maximum)
        }
    }
}
