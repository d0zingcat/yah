import Foundation
import NaturalLanguage

/// Looks up a bounded, read-only model. Rows contain a stable key, the exact
/// UTF-8 term (12 bytes), and 64 signed components. The file has no user data.
private struct ContextVectors {
    private let image: Data
    private let count: Int
    private static let rowSize = 84

    init?(url: URL?) {
        guard let url, let image = try? Data(contentsOf: url, options: .alwaysMapped),
              image.count >= 16, image.prefix(8) == Data("YAHVEC01".utf8) else { return nil }
        let (rows, dimensions) = image.withUnsafeBytes { bytes in
            (UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt32.self)),
             UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 12, as: UInt32.self)))
        }
        guard rows == 48_000, dimensions == 64,
              image.count == 16 + Int(rows) * Self.rowSize else { return nil }
        self.image = image
        count = Int(rows)
    }

    func vector(for word: String) -> [Double]? {
        let text = Array(word.utf8)
        guard !text.isEmpty, text.count <= 12 else { return nil }
        var hash: UInt64 = 14695981039346656037
        for byte in text { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return image.withUnsafeBytes { bytes in
            func key(at row: Int) -> UInt64 {
                UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 16 + row * Self.rowSize,
                                                         as: UInt64.self))
            }
            var low = 0, high = count
            while low < high {
                let middle = low + (high - low) / 2
                if key(at: middle) < hash { low = middle + 1 } else { high = middle }
            }
            guard low < count, key(at: low) == hash else { return nil }
            let start = 16 + low * Self.rowSize + 8
            guard bytes[start..<(start + text.count)].elementsEqual(text),
                  text.count == 12 || bytes[start + text.count] == 0 else { return nil }
            let components = bytes[(start + 12)..<(start + 76)].map { Double(Int8(bitPattern: $0)) }
            let length = sqrt(components.reduce(0) { $0 + $1 * $1 })
            return length > 0 ? components.map { $0 / length } : nil
        }
    }
}

/// Owned by one keyboard controller. The only persisted setting is the opt-in.
/// The short context and its derived values expire with the current composition.
final class ContextualRanking {
    private let tokenizer = NLTokenizer(unit: .word)
    private var model: ContextVectors?
    private var previous: (raw: String, prefix: String, choices: [String], index: Int?)?

    init(onReady: @escaping () -> Void) {
        tokenizer.setLanguage(.simplifiedChinese)
        let url = Bundle.main.url(forResource: "vectors", withExtension: "dat", subdirectory: "ContextModel")
        // A cold file mapping can stall a key event; continue using Rime while it opens.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let vectors = ContextVectors(url: url)
            if vectors != nil {
                // ICU opens its Mandarin data on first use. Do that on this same
                // background queue before allowing keys to enter the ranking path.
                _ = Self.reading("拼音")
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let vectors else { return }
                model = vectors
                onReady()
            }
        }
    }

    var isReady: Bool { model != nil }

    func clear() { previous = nil }

    static func trailingHan(in text: String?) -> String {
        guard let text else { return "" }
        let suffix = text.suffix(12).reversed().prefix { character in
            character.unicodeScalars.allSatisfy { $0.properties.isIdeographic }
        }
        return String(suffix.reversed())
    }

    private static func reading(_ text: String) -> String? {
        text.applyingTransform(.mandarinToLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false)?
            .lowercased().replacingOccurrences(of: " ", with: "'")
    }

    func preferredIndex(raw: String, choices: [String], prefix: String,
                        lookup: (String) -> String?) -> Int? {
        guard let model, prefix.count >= 3 else { clear(); return nil }
        if let previous, previous.raw == raw, previous.prefix == prefix, previous.choices == choices {
            return previous.index
        }
        let result = rank(raw: raw, choices: choices, prefix: prefix, model: model, lookup: lookup)
        previous = (raw, prefix, choices, result)
        return result
    }

    private func rank(raw: String, choices: [String], prefix: String, model: ContextVectors,
                      lookup: (String) -> String?) -> Int? {
        // At least two distinct suffixes must independently make the same native
        // word their first completion, preserving the literal characters at the cursor.
        var votes = [Int: Int]()
        for length in 2...min(4, prefix.count) {
            let suffix = String(prefix.suffix(length))
            guard let spelled = Self.reading(suffix), let phrase = lookup(spelled + "'" + raw),
                  phrase.hasPrefix(suffix) else { continue }
            let tail = String(phrase.dropFirst(length))
            guard tail.count == 2, let index = choices.firstIndex(of: tail), index > 0 else { continue }
            votes[index, default: 0] += 1
        }
        guard votes.values.contains(where: { $0 >= 2 }),
              let defaultVector = model.vector(for: choices[0]) else { return nil }

        tokenizer.string = prefix
        let words = tokenizer.tokens(for: prefix.startIndex..<prefix.endIndex).compactMap { range -> [Double]? in
            let word = String(prefix[range])
            return word.count >= 2 ? model.vector(for: word) : nil
        }
        tokenizer.string = nil
        guard !words.isEmpty else { return nil }
        func similarities(_ vector: [Double]) -> [Double] {
            words.map { word in zip(word, vector).reduce(0) { $0 + $1.0 * $1.1 } }
        }
        let baseline = similarities(defaultVector)
        let scores = choices.dropFirst().map { choice in
            model.vector(for: choice).map(similarities) ?? []
        }
        let maxima = [baseline.max() ?? -1] + scores.map { $0.max() ?? -1 }
        guard let strongest = maxima.max(), let index = maxima.firstIndex(of: strongest), index > 0,
              (votes[index] ?? 0) >= 2 else { return nil }
        let comparisons = zip(scores[index - 1], baseline).map { (score: $0, margin: $0 - $1) }
        let support = comparisons.filter { $0.score >= 0.30 }.map(\.margin).max() ?? -1
        let opposition = -(comparisons.map(\.margin).min() ?? 0)
        return support >= 0.15 && support >= opposition + 0.08 ? index : nil
    }
}
