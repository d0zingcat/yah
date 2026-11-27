// Generate only local test inputs. System localization assets are never packaged with Yah.
import CryptoKit
import Foundation
import NaturalLanguage

let files = FileManager.default
let applications = URL(fileURLWithPath: "/System/Applications")
let han = try NSRegularExpression(pattern: "[一-鿿]{5,}")
var texts = Set<String>()
for app in try files.contentsOfDirectory(at: applications, includingPropertiesForKeys: nil)
where app.pathExtension == "app" {
    let resources = app.appendingPathComponent("Contents/Resources")
    let tables = (try? files.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? []
    for table in tables where table.pathExtension == "loctable" {
        guard let data = try? Data(contentsOf: table),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let chinese = plist["zh_CN"] as? [String: Any] else { continue }
        for case let string as String in chinese.values {
            let value = string as NSString
            for match in han.matches(in: string, range: NSRange(location: 0, length: value.length)) {
                texts.insert(value.substring(with: match.range))
            }
        }
    }
}
let ordered = texts.map { (text: $0, hash: Array(SHA256.hash(data: Data($0.utf8)))) }
    .sorted { $0.hash.lexicographicallyPrecedes($1.hash) }.map(\.text)
let tokenize = NLTokenizer(unit: .word)
tokenize.setLanguage(.simplifiedChinese)
func inputs(_ sentences: ArraySlice<String>, limit: Int) -> [String] {
    var seen = Set<String>()
    var result = [String]()
    for text in sentences {
        tokenize.string = text
        for range in tokenize.tokens(for: text.startIndex..<text.endIndex) {
            let word = String(text[range])
            let prefix = String(text[..<range.lowerBound].suffix(6))
            guard word.count == 2, prefix.count >= 2, seen.insert(prefix + "|" + word).inserted,
                  let latin = word.applyingTransform(.mandarinToLatin, reverse: false)?
                      .applyingTransform(.stripDiacritics, reverse: false) else { continue }
            let code = latin.lowercased().replacingOccurrences(of: " ", with: "")
            guard !code.isEmpty, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { continue }
            result.append([code, prefix, word].joined(separator: "\t"))
            if result.count == limit { return result }
        }
    }
    return result
}
let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("cases.tsv")
let fixedRows = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n")
var used = Set(fixedRows.map { $0.components(separatedBy: "\t").dropFirst().joined(separator: "\t") })
used.formUnion(inputs(ordered.prefix(4000), limit: 6500))
used.formUnion(inputs(ordered.dropFirst(4000).prefix(4000), limit: 5000))
let held = inputs(ordered.dropFirst(8000).prefix(4000), limit: 7500)
    .lazy.filter { !used.contains($0) }.prefix(5000)
for row in held { print("blind\t" + row) }
