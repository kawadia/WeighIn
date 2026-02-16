import Foundation

struct AppSettings: Codable, Hashable {
    var defaultUnit: WeightUnit
    var reminderEnabled: Bool
    var reminderHour: Int
    var reminderMinute: Int
    var hasCompletedOnboarding: Bool

    static let `default` = AppSettings(
        defaultUnit: .lbs,
        reminderEnabled: true,
        reminderHour: 7,
        reminderMinute: 0,
        hasCompletedOnboarding: false
    )
}
