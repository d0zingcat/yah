import XCTest

final class RegionUI: KeyboardUITest {
    func testRegionsCommitIntoTargetAndPersist() {
        let mode = host.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "全拼")).firstMatch
        func select(_ name: String) {
            mode.tap()
            let submenu = host.buttons["输出字形"]
            guard submenu.waitForExistence(timeout: 2) else { print("MENU",host.debugDescription); XCTFail("no region menu"); return }
            submenu.tap()
            let choice = host.buttons[name].firstMatch
            guard choice.waitForExistence(timeout: 2) else { print("FORMS",host.debugDescription); XCTFail("no requested region"); return }
            choice.tap()
        }
        var expected = ""
        func type(_ code: String, _ word: String) {
            for key in code { host.buttons[String(key)].firstMatch.tap() }
            let candidate = host.buttons[word].firstMatch
            guard candidate.waitForExistence(timeout: 3) else { print("WORDS",host.debugDescription); XCTFail("missing candidate "+word); return }
            candidate.tap()
            expected += word
            XCTAssertEqual(field.value as? String, expected)
        }
        select("简体")
        type("ruanjian", "软件")
        select("通用繁体")
        type("ruanjian", "軟件")
        select("台湾繁体")
        type("ruanjian", "軟體")
        select("香港繁体")
        type("weisheng", "衞生")
        host.terminate()
        host.launch()
        field.tap()
        XCTAssertTrue(host.buttons["全拼·港"].waitForExistence(timeout: 3))
        expected = ""
        type("weisheng", "衞生")
        select("简体")
        type("weisheng", "卫生")
    }
}
