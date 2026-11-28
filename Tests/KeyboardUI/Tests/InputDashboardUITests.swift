import XCTest

final class InputDashboardUITests: XCTestCase {
    func testSelectingChartBucketKeepsWindowLabels() {
        let app = XCUIApplication(bundleIdentifier: "local.yah.ios")
        app.launchArguments += ["-yahKeyboardOnboardingCompleted", "YES"]
        app.launch()

        let chartBars = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "语音", "合计")
        )
        XCTAssertEqual(chartBars.count, 7, app.debugDescription)
        let labels = (0..<7).map { chartBars.element(boundBy: $0).label }
        let detailDate = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "年")).firstMatch
        let initialDetailDate = detailDate.label

        chartBars.element(boundBy: 1).tap()

        XCTAssertEqual((0..<7).map { chartBars.element(boundBy: $0).label }, labels, app.debugDescription)
        XCTAssertNotEqual(detailDate.label, initialDetailDate)
    }
}
