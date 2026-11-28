import XCTest

final class VoiceUI: KeyboardUITest {
    func testMicrophoneGuidesToFullAccess() {
        let yah = XCUIApplication(bundleIdentifier: "local.yah.ios")
        yah.launch()
        host.launch()
        yah.terminate()
        field.tap()
        selectYahKeyboard()
        let microphone = host.buttons["keyboard-direct-voice"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 4), host.debugDescription)
        XCTAssertEqual(host.buttons.matching(identifier: "keyboard-direct-voice").count, 1)
        microphone.tap()
        XCTAssertTrue(host.staticTexts["请在系统设置中为 Yah 键盘开启「允许完全访问」。"]
            .waitForExistence(timeout: 6), host.debugDescription)
        XCTAssertEqual(host.state, .runningForeground)
        XCTAssertFalse(host.buttons["返回打字"].exists)
        type("nihao")
        tap("你好")
        XCTAssertEqual(field.value as? String, "你好")
    }

    func testDeniedMicrophoneLeavesContinuousDictationOff() {
        let yah = XCUIApplication(bundleIdentifier: "local.yah.ios")
        yah.launch()
        let start = yah.buttons["开启语音待机"]
        XCTAssertTrue(start.waitForExistence(timeout: 4))
        start.tap()
        XCTAssertTrue(yah.staticTexts["请在系统设置中允许 Yah 使用麦克风。"].waitForExistence(timeout: 6))
        XCTAssertTrue(start.isEnabled)
        XCTAssertFalse(yah.buttons["结束连续听写"].exists)
    }

}
