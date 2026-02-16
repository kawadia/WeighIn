import Foundation

enum Gender: String, CaseIterable, Codable {
    case undisclosed
    case female
    case male
    case nonBinary

    var label: String {
        switch self {
        case .undisclosed: return "Prefer not to say"
        case .female: return "Female"
        case .male: return "Male"
        case .nonBinary: return "Non-binary"
        }
    }
}

struct UserProfile: Codable, Hashable {
    var birthday: Date?
    var gender: Gender
    var heightCentimeters: Double?
    var avatarPath: String?

    static let empty = UserProfile(
        birthday: nil,
        gender: .undisclosed,
        heightCentimeters: nil,
        avatarPath: nil
    )
}
