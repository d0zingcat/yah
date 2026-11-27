import XCTest

final class Typing: KeyboardUITest {
    func testTwoMistapsAndUndo() {
        host.buttons["n"].tap()
        host.buttons["u"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        host.buttons["h"].tap()
        host.buttons["a"].tap()
        host.buttons["p"].coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        let correction = host.buttons["纠错候选，你好"]
        XCTAssertTrue(correction.waitForExistence(timeout: 3))
        host.buttons["退格"].tap()
        host.buttons["p"].tap()
        XCTAssertFalse(correction.exists)
        host.buttons["退格"].tap()
        host.buttons["p"].coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        correction.tap()
        XCTAssertEqual(field.value as? String, "你好")
    }

    func testUnicodeWithoutLosingComposition() {
        host.buttons["Shift"].tap()
        host.buttons["U"].tap()
        host.buttons["123"].tap()
        host.buttons["6"].tap()
        host.buttons["2"].tap()
        host.buttons["ABC"].tap()
        host.buttons["f"].tap()
        host.buttons["c"].tap()
        let result = host.buttons["拼"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        result.tap()
        XCTAssertEqual(field.value as? String, "拼")
    }

    func testFlickProducesSingleDigit() {
        let key = host.buttons["e"]
        let start = key.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -55)), withVelocity: .fast, thenHoldForDuration: 0)
        XCTAssertEqual(field.value as? String, "3")
        XCTAssertFalse(host.buttons["分词"].exists)
    }
}
