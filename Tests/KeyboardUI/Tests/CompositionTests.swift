import XCTest

final class MixedTyping: KeyboardUITest {
    func testMixedSentences() {
        for (raw,text) in [("wojiadewifimima","我家的Wi-Fi密码"),("woyongchatg","我用ChatGPT")] {
            type(raw)
            let candidate = host.buttons[text].firstMatch
            XCTAssertTrue(candidate.waitForExistence(timeout: 5))
            candidate.tap()
        }
        XCTAssertEqual(field.value as? String, "我家的Wi-Fi密码我用ChatGPT")
    }
}

final class SegmentEditing: KeyboardUITest {
    private func selectWord(_ text: String) {
        tap("展开候选")
        let word = host.descendants(matching: .any).matching(identifier: "candidate-grid-word")
            .matching(NSPredicate(format: "label == %@", text)).firstMatch
        XCTAssertTrue(word.waitForExistence(timeout: 4), text)
        word.tap()
    }

    func testUndoPartialSegmentAndContinueEditing() {
        type("nihaoshijie")
        selectWord("你好")
        XCTAssertTrue(host.staticTexts["你好shi jie"].exists)
        XCTAssertEqual(field.value as? String ?? "", "")
        tap("退格")
        XCTAssertTrue(host.staticTexts["nihaoshijie"].exists)
        XCTAssertTrue(host.buttons["你好世界"].exists)
        XCTAssertEqual(field.value as? String ?? "", "")
        tap("退格")
        XCTAssertTrue(host.staticTexts["nihaoshiji"].exists)
        selectWord("你好时机")
        XCTAssertEqual(field.value as? String, "你好时机")

        type("nihaoshijie")
        selectWord("你好")
        selectWord("时节")
        XCTAssertEqual(field.value as? String, "你好时机你好时节")
    }

    func testUnicodeThenMixedTyping() {
        for key in ["Shift","U","123","4","ABC","e","123","2","ABC","d","中"] { tap(key) }
        XCTAssertEqual(field.value as? String, "中")
        type("woyongchatg")
        tap("我用ChatGPT")
        XCTAssertEqual(field.value as? String, "中我用ChatGPT")
    }
}
