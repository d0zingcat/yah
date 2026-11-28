import XCTest

final class VoiceUI: KeyboardUITest {
    func testMicrophoneGuidesToFullAccess() {
        let yah = XCUIApplication(bundleIdentifier: "local.yah.ios")
        yah.launch()
        openVoiceSettings(yah)
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
        openVoiceSettings(yah)
        let start = yah.buttons["开启语音待机"]
        XCTAssertTrue(start.waitForExistence(timeout: 4))
        start.tap()
        XCTAssertTrue(yah.staticTexts["请在系统设置中允许 Yah 使用麦克风。"].waitForExistence(timeout: 6))
        XCTAssertTrue(start.isEnabled)
        XCTAssertFalse(yah.buttons["结束连续听写"].exists)
    }

    private func openVoiceSettings(_ app: XCUIApplication) {
        let start = app.buttons["开启语音待机"]
        if start.waitForExistence(timeout: 1) { return }

        let skipOnboarding = app.buttons["稍后进入 Yah 设置"]
        if skipOnboarding.waitForExistence(timeout: 2) {
            skipOnboarding.tap()
        } else {
            let finishOnboarding = app.buttons["进入 Yah 主设置页"]
            if finishOnboarding.exists {
                finishOnboarding.tap()
            } else {
                app.buttons["打开语音和输入方案设置"].tap()
            }
        }
        XCTAssertTrue(start.waitForExistence(timeout: 4), app.debugDescription)
    }
}
