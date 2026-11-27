import XCTest

final class KeyboardGeometry: KeyboardUITest {
    func testCrossRowDoublePinyinAndNineKeyCorrections() {
        let full = host.buttons["全拼"].firstMatch
        XCTAssertTrue(full.waitForExistence(timeout: 4))
        func tap(_ keys: [String]) { for key in keys { host.buttons[key].firstMatch.tap() } }
        func edge(_ key: String, _ x: CGFloat, _ y: CGFloat) {
            host.buttons[key].firstMatch.coordinate(withNormalizedOffset: .init(dx: x, dy: y)).tap()
        }
        func correction(_ expected: String, result: String) {
            let button = host.buttons["纠错候选，" + expected]
            XCTAssertTrue(button.waitForExistence(timeout: 3),host.debugDescription)
            button.tap()
            XCTAssertEqual(field.value as? String, result)
        }
        tap(["n","i","h","a"])
        edge("k", 0.62, 0.05)
        correction("你好", result: "你好")
        full.tap()
        host.buttons["小鹤双拼"].firstMatch.tap()
        tap(["h","f","k"])
        edge("l", 0.05, 0.5)
        correction("很快", result: "你好很快")
        host.buttons["小鹤双拼"].firstMatch.tap()
        host.buttons["九宫格"].firstMatch.tap()
        tap(["MNO","GHI","GHI","ABC"])
        edge("JKL", 0.97, 0.5)
        correction("你好", result: "你好很快你好")
        host.buttons["九宫格"].firstMatch.tap()
        host.buttons["自然码双拼"].firstMatch.tap()
        tap(["h","f","k","y"])
        host.buttons["很快"].firstMatch.tap()
        XCTAssertEqual(field.value as? String, "你好很快你好很快")
        host.buttons["自然码双拼"].firstMatch.tap()
        host.buttons["全拼"].firstMatch.tap()
    }
}
