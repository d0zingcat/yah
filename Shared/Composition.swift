import Foundation

final class Composition {
    private let session = YahRimeSession()
    private var literal = ""

    var spelling: String { session?.input ?? literal }
    var candidates: [String] {
        let choices = session?.choices ?? []
        return choices.isEmpty && !spelling.isEmpty ? [spelling] : choices
    }

    func append(_ letter: Character) {
        guard let key = letter.asciiValue else { return }
        if let session { session.processKey(Int32(key)) }
        else { literal.append(letter) }
    }

    func canPage(backward: Bool) -> Bool {
        session?.canPageBackward(backward) ?? false
    }

    func page(backward: Bool) {
        session?.pageBackward(backward)
    }

    func backspace() {
        if let session { session.processKey(0xff08) }
        else { _ = literal.popLast() }
    }

    func clear() {
        session?.reset()
        literal = ""
    }

    func select(_ index: Int) -> String? {
        guard candidates.indices.contains(index) else { return nil }
        if let session, !session.choices.isEmpty { return session.choose(index) }
        let text = spelling
        clear()
        return text
    }
}
