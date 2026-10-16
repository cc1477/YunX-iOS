import Foundation
import UIKit
import UniformTypeIdentifiers

struct SharePayload: Codable {
    static let pasteboardType = "com.yunx.pending-share"
    let id: UUID
    let text: String
    let createdAt: Date

    var isValid: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        text.utf8.count <= 65_536 && Date().timeIntervalSince(createdAt) >= -60 &&
        Date().timeIntervalSince(createdAt) < 3600
    }

    static func stage(_ text: String) throws {
        let payload = SharePayload(id: UUID(), text: text, createdAt: Date())
        guard payload.isValid else { throw NSError(domain: "YunXShare", code: 1) }
        let data = try JSONEncoder().encode(payload)
        UIPasteboard.general.setItems([
            [pasteboardType: data, UTType.utf8PlainText.identifier: text]
        ], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(3600)])
    }
}
