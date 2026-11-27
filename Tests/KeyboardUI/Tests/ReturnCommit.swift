import XCTest

final class ReturnCommit: KeyboardUITest {
    func testLiteralReturnInPinyinModesAndEmptyReturn() {
        var expected = ""
        for mode in ["全拼", "小鹤双拼", "自然码双拼"] {
            if mode != "全拼" {
                tap(mode == "小鹤双拼" ? "全拼" : "小鹤双拼")
                tap(mode)
            }
            for input in ["nihao", "hello", "paseo"] {
                type(input)
                tap("回车")
                expected += input
                XCTAssertEqual(field.value as? String, expected)
                XCTAssertFalse(host.buttons["展开候选"].exists)
            }
        }
        tap("回车")
        XCTAssertEqual(field.value as? String, expected + "\n")
    }

    func testSpaceStillCommitsFirstCandidate() {
        type("nihao")
        tap("空格")
        XCTAssertEqual(field.value as? String, "你好")
        XCTAssertFalse(host.buttons["展开候选"].exists)
    }

    func testReturnFinishesPartialSelection() {
        type("nihaoshijie")
        tap("展开候选")
        let word = host.descendants(matching: .any).matching(identifier: "candidate-grid-word")
            .matching(NSPredicate(format: "label == %@", "你好")).firstMatch
        XCTAssertTrue(word.waitForExistence(timeout: 4))
        word.tap()
        XCTAssertTrue(host.staticTexts["你好shi jie"].exists)
        tap("回车")
        XCTAssertEqual(field.value as? String, "你好世界")
        XCTAssertFalse(host.buttons["展开候选"].exists)
    }

    func testReturnConfirmsNineKeyAndUnicodeCode() {
        tap("全拼")
        tap("九宫格")
        for key in ["MNO", "GHI", "GHI", "ABC", "MNO"] { tap(key) }
        tap("回车")
        XCTAssertEqual(field.value as? String, "你好")
        XCTAssertTrue(host.buttons["九宫格"].exists)
        tap("九宫格")
        tap("全拼")
        for key in ["Shift", "U", "123", "4", "ABC", "e", "123", "2", "ABC", "d"] { tap(key) }
        tap("回车")
        XCTAssertEqual(field.value as? String, "你好中")
        XCTAssertFalse(host.buttons["展开候选"].exists)
    }

    func testReturnConfirmsNumberCode() {
        for key in ["Shift", "R", "123", "1", "2"] { tap(key) }
        tap("回车")
        XCTAssertEqual(field.value as? String, "一十二")
        XCTAssertFalse(host.buttons["展开候选"].exists)
    }

    func testIncompleteUnicodeCodeRemainsEditable() {
        for key in ["Shift", "U", "123", "4", "回车"] { tap(key) }
        XCTAssertEqual(field.value as? String ?? "", "")
        tap("ABC")
        tap("e")
        tap("回车")
        XCTAssertEqual(field.value as? String, "N")
    }

    func testReturnClearsEdgeCorrections() {
        tap("n")
        host.buttons["u"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        type("hao")
        XCTAssertTrue(host.buttons["纠错候选，你好"].exists)
        tap("回车")
        XCTAssertEqual(field.value as? String, "nuhao")
        type("nuhao")
        XCTAssertFalse(host.buttons["纠错候选，你好"].exists)
    }
}
