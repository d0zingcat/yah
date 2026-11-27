import UIKit

@main
final class ContextCheck: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var ranker: ContextualRanking?
    private let composition = Composition(offersEnglishMix: false)

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options:
                     [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIViewController()
        self.window = window
        window.makeKeyAndVisible()
        ranker = ContextualRanking { [weak self] in self?.run() }
        return true
    }

    private struct Failure: Error, CustomStringConvertible { let description: String }
    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    private func type(_ raw: String) {
        composition.clear()
        for letter in raw { composition.append(letter) }
    }

    private func rank(_ prefix: String) {
        composition.updateContextualOrder { [self] raw, choices in
            ranker?.preferredIndex(raw: raw, choices: choices, prefix: ContextualRanking.trailingHan(in: prefix),
                                   lookup: composition.firstContextMatch)
        }
    }

    private func run() {
        var results = [String]()
        do {
            guard let cases = Bundle.main.url(forResource: "cases", withExtension: "tsv") else {
                throw Failure(description: "Missing test cases")
            }
            try require(composition.useSchema("rime_ice"), "Could not start rime_ice")
            var count = 0, before = 0, after = 0, promoted = 0
            for row in try String(contentsOf: cases, encoding: .utf8).split(separator: "\n") {
                let cells = row.components(separatedBy: "\t")
                try require(cells.count == 4, "Expected set, spelling, prefix, target")
                type(cells[1])
                let original = composition.candidates
                rank(cells[2])
                let displayed = composition.candidates
                count += 1
                if original.first == cells[3] { before += 1 }
                if displayed.first == cells[3] { after += 1 }
                if displayed.first != original.first {
                    promoted += 1
                    let grid = composition.expandedChoices(startingAt: 0, limit: 12)
                    try require(Array(grid.prefix(displayed.count)) == displayed, "Grid order for " + cells[1])
                    for offset in displayed.indices {
                        try require(composition.expandedChoices(startingAt: offset, limit: 1).first == displayed[offset],
                                    "Grid slice for " + cells[1])
                    }
                }
                composition.updateContextualOrder(nil)
                try require(composition.candidates == original, "Opt-out for " + cells[1])
            }
            results.append("\(count) examples: \(before) native first choices, \(after) contextual, \(promoted) reordered")
            type("shuxue")
            let native = composition.candidates
            rank("老师表示学生需要")
            try require(composition.candidates.first == "数学", "Education")
            rank("医生表示病人需要！")
            try require(composition.candidates == native, "Punctuation boundary")
            rank("医生表示病人需要")
            try require(composition.candidates.first == "输血", "Medicine")
            composition.page(backward: false)
            let next = composition.candidates
            rank("医生表示病人需要")
            try require(composition.candidates == next, "Second page")
            composition.page(backward: true)
            rank("医生表示病人需要")
            try require(composition.select(1) == "数学", "Second visible candidate")
            type("shuxue")
            rank("医生表示病人需要")
            try require(composition.selectExpanded(at: 0) == "输血", "First grid candidate")
            results.append("PASS")
        } catch { results.append("FAIL " + String(describing: error)) }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? results.joined(separator: "\n").write(to: documents.appendingPathComponent("result.txt"),
                                                  atomically: true, encoding: .utf8)
    }
}
