import Foundation

struct NoteEntry: Identifiable, Codable, Hashable {
    let id: String
    let timestamp: Date
    let text: String

    init(id: String = UUID().uuidString, timestamp: Date, text: String) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
    }
}
