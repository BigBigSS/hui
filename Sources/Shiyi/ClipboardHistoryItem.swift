import Foundation

struct ClipboardHistoryItem: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text
        case image
        case gif
        case file
    }

    let id: UUID
    let kind: Kind
    let content: String
    let timestamp: Date
    let fileName: String?
    let pasteboardType: String?
    let fileSizeBytes: Int64?

    var isText: Bool {
        kind == .text
    }

    var isVisualContent: Bool {
        kind == .image || kind == .gif
    }

    var isStoredFile: Bool {
        kind == .file
    }

    var displayTitle: String {
        switch kind {
        case .text:
            return content
        case .image:
            return "Image"
        case .gif:
            return "GIF"
        case .file:
            return content
        }
    }

    var searchableText: String {
        [displayTitle, content]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    init(
        id: UUID = UUID(),
        kind: Kind = .text,
        content: String,
        timestamp: Date = Date(),
        fileName: String? = nil,
        pasteboardType: String? = nil,
        fileSizeBytes: Int64? = nil
    ) {
        self.id = id
        self.kind = kind
        self.content = content
        self.timestamp = timestamp
        self.fileName = fileName
        self.pasteboardType = pasteboardType
        self.fileSizeBytes = fileSizeBytes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case content
        case timestamp
        case fileName
        case pasteboardType
        case fileSizeBytes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        pasteboardType = try container.decodeIfPresent(String.self, forKey: .pasteboardType)
        fileSizeBytes = try container.decodeIfPresent(Int64.self, forKey: .fileSizeBytes)
    }
}
