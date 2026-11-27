import XCTest

final class ExpandedCandidates: KeyboardUITest {
    private var entries: XCUIElementQuery {
        host.descendants(matching: .any).matching(identifier: "candidate-grid-word")
    }

    func testFilterCollapseAndCommitTwoCharacters() {
        type("nihao")
        host.buttons["展开候选"].tap()
        host.buttons["2 字"].tap()
        let target = entries.matching(NSPredicate(format: "label == %@", "你好")).firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 5), host.debugDescription)
        let visible = entries.allElementsBoundByIndex.filter(\.isHittable)
        XCTAssertFalse(visible.isEmpty)
        XCTAssertTrue(visible.allSatisfy { $0.label.count == 2 })
        host.buttons["收起候选"].tap()
        XCTAssertTrue(host.buttons["n"].isHittable)
        host.buttons["展开候选"].tap()
        entries.matching(NSPredicate(format: "label == %@", "你好")).firstMatch.tap()
        XCTAssertEqual(field.value as? String, "你好")
        XCTAssertTrue(host.buttons["n"].isHittable)
    }

    func testSelectBeyondFirstRimePage() {
        type("shi")
        host.buttons["展开候选"].tap()
        host.buttons["1 字"].tap()
        XCTAssertTrue(entries.element(boundBy: 7).waitForExistence(timeout: 5))
        let word = entries.element(boundBy: 7)
        let expected = word.label
        XCTAssertEqual(expected.count, 1)
        word.tap()
        XCTAssertEqual(field.value as? String, expected)
    }
}
