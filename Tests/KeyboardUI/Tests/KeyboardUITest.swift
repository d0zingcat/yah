import XCTest

class KeyboardUITest: XCTestCase {
    let host = XCUIApplication(bundleIdentifier: "local.yah.qa.harness")
    var field: XCUIElement { host.textViews["target"] }

    override func setUpWithError() throws {
        continueAfterFailure = false
        host.launch()
        field.tap()
        selectYahKeyboard()
    }

    func selectYahKeyboard() {
        // A previous test or manual run may have left another scheme or region selected.
        let modes = host.buttons.matching(NSPredicate(format: "label MATCHES %@", "(全拼|九宫格|小鹤双拼|自然码双拼)(·[繁台港])?"))
        let mode = modes.firstMatch
        if !mode.waitForExistence(timeout: 2) {
            let globe = host.buttons["Next keyboard"]
            if globe.exists {
                globe.press(forDuration: 1)
                let entry = host.cells.containing(NSPredicate(format: "label CONTAINS[c] %@", "Yah")).firstMatch
                if entry.exists { entry.tap() }
            }
        }
        XCTAssertTrue(mode.waitForExistence(timeout: 4), "Add Yah under Settings → General → Keyboard → Keyboards and select it in the host.")
        if !mode.label.hasPrefix("全拼") {
            mode.tap()
            tap("全拼")
        }
        if mode.label != "全拼" {
            mode.tap()
            tap("输出字形")
            tap("简体")
        }
        if host.buttons["中"].exists { tap("中") }
    }

    func tap(_ label: String) {
        let button = host.buttons[label].firstMatch
        if !button.exists { XCTAssertTrue(button.waitForExistence(timeout: 3), label) }
        button.tap()
    }

    func type(_ keys: String) {
        for key in keys { tap(String(key)) }
    }
}
