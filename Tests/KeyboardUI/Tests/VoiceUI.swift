import XCTest

final class VoiceUI: KeyboardUITest {
    func testMicrophoneOpensYahFromAnotherApp() {
        let yah = XCUIApplication(bundleIdentifier: "local.yah.ios")
        yah.launch()
        host.launch()
        yah.terminate()
        field.tap()
        selectYahKeyboard()
        let microphone = host.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "开始语音输入")).firstMatch
        XCTAssertTrue(microphone.waitForExistence(timeout: 4), host.debugDescription)
        microphone.tap()
        XCTAssertTrue(yah.wait(for: .runningForeground, timeout: 6))
        XCTAssertTrue(yah.staticTexts["请在系统设置中允许 Yah 使用麦克风。"].waitForExistence(timeout: 8))
        XCTAssertFalse(yah.buttons["结束录音并转写"].exists)
    }

    func testDeniedMicrophoneLeavesContinuousDictationOff() {
        let yah = XCUIApplication(bundleIdentifier: "local.yah.ios")
        yah.launch()
        let start = yah.buttons["开启十分钟连续听写"]
        XCTAssertTrue(start.waitForExistence(timeout: 4))
        start.tap()
        XCTAssertTrue(yah.staticTexts["请在系统设置中允许 Yah 使用麦克风。"].waitForExistence(timeout: 6))
        XCTAssertTrue(start.isEnabled)
        XCTAssertFalse(yah.buttons["结束连续听写"].exists)
    }

    func testFallbackShowsInstructionsAndReturnsToTyping() {
        tap("全拼")
        tap("语音工具")
        let hint = host.staticTexts.matching(NSPredicate(
            format: "label == %@ OR label == %@",
            "轻点 Yah 通知开始录音", "请打开 Yah，点「开始跨应用语音输入」，再返回这里。"
        )).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 6))
        tap("返回打字")
        type("nihao")
        tap("你好")
        XCTAssertEqual(field.value as? String, "你好")
    }
}
