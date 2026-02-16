import XCTest
@testable import WeighIn

final class ModelDefaultsTests: XCTestCase {
    func testChartRangeDayValues() {
        XCTAssertEqual(ChartRange.week.days, 7)
        XCTAssertEqual(ChartRange.month.days, 30)
        XCTAssertEqual(ChartRange.quarter.days, 90)
        XCTAssertEqual(ChartRange.year.days, 365)
        XCTAssertEqual(ChartRange.all.days, Int.max)
    }

    func testAppSettingsAndProfileDefaults() {
        XCTAssertEqual(AppSettings.default.defaultUnit, .lbs)
        XCTAssertTrue(AppSettings.default.reminderEnabled)
        XCTAssertEqual(AppSettings.default.reminderHour, 7)
        XCTAssertEqual(AppSettings.default.reminderMinute, 0)
        XCTAssertFalse(AppSettings.default.hasCompletedOnboarding)

        XCTAssertEqual(UserProfile.empty.gender, .undisclosed)
        XCTAssertNil(UserProfile.empty.birthday)
        XCTAssertNil(UserProfile.empty.heightCentimeters)
        XCTAssertNil(UserProfile.empty.avatarPath)
        XCTAssertEqual(Gender.nonBinary.label, "Non-binary")
    }
}
