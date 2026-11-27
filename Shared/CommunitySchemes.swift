import Foundation

struct CommunitySchemes: Codable {
    struct Scheme: Codable {
        let id: String
        let name: String
        let alphabet: String?
    }

    let revision: UUID
    let schemes: [Scheme]

    static func root() throws -> URL {
        guard let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.local.yah.voice")
        else { throw CocoaError(.fileReadNoPermission) }
        return shared.appendingPathComponent("CommunityRime", isDirectory: true)
    }

    static func installed() -> Self? {
        guard let root = try? root(), let data = try? Data(contentsOf: root.appendingPathComponent("installed.json"))
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func directory() throws -> URL {
        try Self.root().appendingPathComponent(revision.uuidString, isDirectory: true)
    }
}

struct PersonalLexicon {
    struct Entry: Hashable, Identifiable {
        struct Key: Hashable { let phrase: String; let code: String }
        let phrase: String
        let code: String
        let weight: Int32
        var id: Key { Key(phrase: phrase, code: code) }
    }

    enum ImportError: LocalizedError {
        case line(Int), encoding, empty, tooLarge, changed, dictionaryHeader
        var errorDescription: String? {
            switch self {
            case .line(let n): return "第 \(n) 行格式有误。请用制表符分隔词条、字母编码和可选的整数权重。"
            case .dictionaryHeader: return "请选择含有行内词条的独立 Rime 词典。需依赖其他词典或自定义列顺序的文件，请用社区方案文件夹部署。"
            case .encoding: return "请使用 UTF-8 编码的文本文件。"
            case .empty: return "没有找到可导入的词条。"
            case .tooLarge: return "个人词库最多支持 4 MB 的 UTF-8 词条文本。"
            case .changed: return "此词条已在其他窗口更改。请重新打开后编辑。"
            }
        }
    }

    static let textLimit = 4 * 1024 * 1024
    private static let nineKeyHeader = "# Yah generated nine-key codes\n"

    static func file() throws -> URL {
        try CommunitySchemes.root().deletingLastPathComponent().appendingPathComponent("personal-phrases.txt")
    }

    static func parse(_ data: Data, rimeDictionary: Bool = false) throws -> [Entry] {
        guard data.count <= textLimit else { throw ImportError.tooLarge }
        guard var text = String(data: data, encoding: .utf8) else { throw ImportError.encoding }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        var start = lines.startIndex
        if rimeDictionary {
            guard let opening = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
                  let closing = lines[lines.index(after: opening)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "..." })
            else { throw ImportError.dictionaryHeader }
            for line in lines[lines.index(after: opening)..<closing] {
                let property = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                let keyValue = property.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard keyValue.count == 2 else { continue }
                let key = keyValue[0].trimmingCharacters(in: .whitespaces)
                if key == "import_tables" { throw ImportError.dictionaryHeader }
                if key == "columns" {
                    let order = keyValue[1].filter { !$0.isWhitespace }
                    guard order == "[text,code,weight]" || order == "[text,code]" else { throw ImportError.dictionaryHeader }
                }
            }
            start = lines.index(after: closing)
        }
        var result: [Entry] = []
        for index in start..<lines.endIndex {
            let raw = lines[index]
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.components(separatedBy: "\t")
            guard (2...3).contains(fields.count) else { throw ImportError.line(index + 1) }
            let phrase = fields[0].trimmingCharacters(in: .whitespaces)
            let code = fields[1].lowercased().replacingOccurrences(of: "ü", with: "v")
                .filter { $0 != " " && $0 != "'" }
            let weight = fields.count == 3 ? Int32(fields[2].trimmingCharacters(in: .whitespaces)) : 0
            guard !phrase.isEmpty, phrase.rangeOfCharacter(from: .controlCharacters) == nil,
                  !code.isEmpty, code.utf8.allSatisfy({ (97...122).contains($0) }), let weight else {
                throw ImportError.line(index + 1)
            }
            result.append(Entry(phrase: phrase, code: code, weight: weight))
        }
        guard !result.isEmpty else { throw ImportError.empty }
        return result
    }

    static func serialize(_ entries: [Entry]) -> String {
        entries.map { "\($0.phrase)\t\($0.code)\t\($0.weight)\n" }.joined()
    }

    static func merged(_ existing: [Entry], _ updates: [Entry]) -> [Entry] {
        var keyed: [Entry.Key: Entry] = [:]
        for entry in existing { keyed[entry.id] = entry }
        for entry in updates { keyed[entry.id] = entry }
        return keyed.values.sorted {
            if $0.code != $1.code { return $0.code < $1.code }
            if $0.weight != $1.weight { return $0.weight > $1.weight }
            return $0.phrase < $1.phrase
        }
    }

    static func table(_ entries: [Entry]) throws -> Data {
        let text = serialize(entries)
        guard text.utf8.count <= textLimit else { throw ImportError.tooLarge }
        let layout = Array("AAABBBCCCDDDEEEFFFFGGGHHHH".utf8)
        var aliases: [Entry.Key: Entry] = [:]
        for entry in entries {
            let code = String(decoding: entry.code.utf8.map { layout[Int($0) - 97] }, as: UTF8.self)
            let alias = Entry(phrase: entry.phrase, code: code, weight: entry.weight)
            if let old = aliases[alias.id], old.weight >= alias.weight { continue }
            aliases[alias.id] = alias
        }
        return Data((text + nineKeyHeader + serialize(merged([], Array(aliases.values)))).utf8)
    }

    static func load() throws -> [Entry] {
        let url = try file()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let text = try String(contentsOf: url, encoding: .utf8)
        let end = text.range(of: nineKeyHeader)?.lowerBound ?? text.endIndex
        let body = Data(text[..<end].utf8)
        return body.isEmpty ? [] : try parse(body)
    }
}
