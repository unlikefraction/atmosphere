import Foundation

struct ChatAttachment: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case screenshot
    }

    let id: UUID
    let kind: Kind
    let fileURL: URL

    init(
        id: UUID = UUID(),
        kind: Kind = .screenshot,
        fileURL: URL
    ) {
        self.id = id
        self.kind = kind
        self.fileURL = fileURL
    }
}
