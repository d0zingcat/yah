import Foundation

final class Composition {
    private let session = YahRimeSession()
    private var literal = ""

    private let offersEnglishMix: Bool

    init(offersEnglishMix: Bool = true) { self.offersEnglishMix = offersEnglishMix }

    // Valid only for the current first page. This contains native candidates,
    // not text from the host document.
    private var promotion: (index: Int, choices: [String])?
    private var isCommunityInput = false
    private var schema = "rime_ice"
    private var outputForm = RimeOutputForm.simplified
    private var segmentSession: YahRimeSession?
    private var mixedSearch: (input: String, word: String?, index: Int)?
    private var chineseSegments: [String: String] = [:]

    var spelling: String { session?.input ?? literal }
    var displaySpelling: String { session?.selectedPreedit ?? spelling }
    var hasSelectedSegment: Bool { session?.selectedPreedit != nil }
    var hasNativeCandidates: Bool { session?.choices.isEmpty == false }
    private var doublePinyin: Bool { schema == "yah_xiaohe" || schema == "yah_ziranma" }

    var candidates: [String] {
        let choices = session?.choices ?? []
        let input = spelling
        var output = choices.isEmpty && !input.isEmpty ? [displaySpelling] : choices
        if let promotion, promotion.choices == choices {
            output.insert(output.remove(at: promotion.index), at: 0)
        }
        if let mixed = mixedCandidate(for: input, choices: choices) {
            output.insert(mixed.word, at: min(mixed.index, output.count))
        }
        return output
    }

    func useSchema(_ name: String) -> Bool {
        guard session?.useSchema(name) == true else { return false }
        isCommunityInput = false
        schema = name
        segmentSession = nil
        invalidateMixed()
        return true
    }

    func setOutputForm(_ form: RimeOutputForm) {
        session?.setOutputForm(form)
        segmentSession?.setOutputForm(form)
        if form != outputForm { invalidateMixed() }
        outputForm = form
    }

    private func invalidateMixed() {
        promotion = nil
        mixedSearch = nil
        chineseSegments.removeAll(keepingCapacity: true)
    }

    private func mixedCandidate(for raw: String, choices: [String]) -> (word: String, index: Int)? {
        guard offersEnglishMix, !isCommunityInput, schema == "rime_ice" || doublePinyin, raw.utf8.count >= 5, raw.utf8.count <= 48,
              !canPage(backward: true), session?.selectedPreedit == nil else { return nil }
        if mixedSearch?.input != raw {
            let whole = session?.firstCompleteCandidate
            let canMix = whole.map { word in
                // Preserve complete English and correctly spelled native Chinese candidates.
                !word.utf8.allSatisfy { $0 < 128 } && !(schema == "rime_ice" && EnglishMix.isPinyin(raw, characters: word.count))
            } ?? true
            let hit = canMix ? EnglishMix.shared.suggestion(raw, doublePinyin: doublePinyin, translate: chinese) : nil
            // Preserve a complete native interpretation (e.g. abbreviated pinyin) as the default.
            let index = whole == nil && hit?.isCompletion == false ? 0 : 1
            mixedSearch = (raw, hit?.text, index)
        }
        guard let mixedSearch, let word = mixedSearch.word, !choices.contains(word) else { return nil }
        return (word, mixedSearch.index)
    }

    private func probeSession() -> YahRimeSession? {
        if let segmentSession { return segmentSession }
        guard let probe = YahRimeSession(), probe.useSchema(schema) else { return nil }
        probe.setOutputForm(outputForm)
        segmentSession = probe
        return probe
    }

    // The query contains only transliterated keystrokes. Reset it immediately
    // without selecting or committing anything in the disposable probe state.
    func firstContextMatch(_ code: String) -> String? {
        guard let probe = probeSession(), probe.replaceInput(code) else { return nil }
        defer { probe.reset() }
        return probe.choices.first
    }

    func updateContextualOrder(_ rank: ((String, [String]) -> Int?)?) {
        promotion = nil
        guard let rank, schema == "rime_ice", outputForm == .simplified, !isCommunityInput,
              let session else { return }
        let raw = spelling
        guard (2...12).contains(raw.utf8.count),
              raw.utf8.allSatisfy({ (97...122).contains($0) }),
              EnglishMix.isPinyin(raw, characters: 2),
              !canPage(backward: true), session.selectedPreedit == nil else { return }
        let choices = session.choices
        guard let first = choices.first, first.count == 2,
              first.unicodeScalars.allSatisfy({ $0.properties.isIdeographic }),
              choices.dropFirst().contains(where: { $0.count == 2 }),
              session.firstCompleteCandidate == first,
              let index = rank(raw, Array(choices.prefix(4))), index > 0, choices.indices.contains(index)
        else { return }
        promotion = (index, choices)
    }

    private func chinese(_ code: String) -> String? {
        if code.isEmpty { return "" }
        if let cached = chineseSegments[code] { return cached.isEmpty ? nil : cached }
        guard let probe = probeSession(), probe.replaceInput(code) else { return nil }
        let translated = probe.firstCompleteCandidate.flatMap { text -> String? in
            guard text.unicodeScalars.allSatisfy({ $0.properties.isIdeographic }) else { return nil }
            let spelled = doublePinyin ? code.utf8.count == text.count * 2 : EnglishMix.isPinyin(code, characters: text.count)
            return spelled ? text : nil
        }
        if chineseSegments.count >= 64 { chineseSegments.removeAll(keepingCapacity: true) }
        chineseSegments[code] = translated ?? ""
        return translated
    }

    func appendCommunity(_ letter: Character) -> String? {
        promotion = nil
        isCommunityInput = true
        guard let key = letter.asciiValue, let session else { return String(letter) }
        let handled = session.processKey(Int32(key))
        let commit = session.takeCommit() ?? ""
        let result = handled ? commit : commit + String(letter)
        return result.isEmpty ? nil : result
    }

    func append(_ letter: Character) {
        promotion = nil
        guard let key = letter.asciiValue else { return }
        if spelling.isEmpty { isCommunityInput = false }
        if let session { session.processKey(Int32(key)) }
        else { literal.append(letter) }
    }

    func canPage(backward: Bool) -> Bool {
        session?.canPageBackward(backward) ?? false
    }

    func page(backward: Bool) {
        promotion = nil
        session?.pageBackward(backward)
    }

    func backspace() {
        promotion = nil
        if let session { session.processKey(0xff08) }
        else { _ = literal.popLast() }
    }

    func clear() {
        isCommunityInput = false
        invalidateMixed()
        session?.reset()
        literal = ""
    }

    func nativeChoices(startingAt start: Int, limit: Int) -> [String] {
        session?.candidateTexts(startingAt: start, limit: limit) ?? []
    }

    private func engineIndex(for displayed: Int) -> Int {
        guard let promotion, displayed >= 0, displayed <= promotion.index else { return displayed }
        return displayed == 0 ? promotion.index : displayed - 1
    }

    func expandedChoices(startingAt start: Int, limit: Int) -> [String] {
        let native = nativeChoices(startingAt: start, limit: limit)
        guard let promotion, start >= 0, start <= promotion.index else { return native }
        return native.enumerated().map { offset, text in
            let displayed = start + offset
            return displayed <= promotion.index ? promotion.choices[engineIndex(for: displayed)] : text
        }
    }

    func selectExpanded(at index: Int) -> String? {
        selectNative(at: engineIndex(for: index))
    }

    func selectNative(at index: Int) -> String? {
        invalidateMixed()
        return session?.chooseAbsolute(index)
    }

    func select(_ index: Int) -> String? {
        guard candidates.indices.contains(index) else { return nil }
        let choices = session?.choices ?? []
        var native = index
        if let mixed = mixedCandidate(for: spelling, choices: choices) {
            let inserted = min(mixed.index, max(choices.count, 1))
            if index == inserted {
                clear()
                return mixed.word
            }
            if index > inserted { native -= 1 }
        }
        native = engineIndex(for: native)
        invalidateMixed()
        if let session, !choices.isEmpty {
            return session.choose(native)
        }
        let text = displaySpelling
        clear()
        return text
    }
}

// Look up English spellings from the bundled Melt English dictionaries. The Chinese
// spans still come from the user's active Rime schema (including traditionalization).
private struct EnglishMix {
    static let shared = EnglishMix()
    private var words: [String: String] = [:]
    private var technical: [String] = []

    init() {
        guard let data = Bundle.main.url(forResource: "RimeData", withExtension: nil) else { return }
        for name in ["en.dict.yaml", "en_ext.dict.yaml"] {
            let url = data.appendingPathComponent("en_dicts").appendingPathComponent(name)
            guard let content = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            for row in content.split(separator: 10) where row.first != 35 {
                guard let tab = row.firstIndex(of: 9) else { continue }
                let token = row[..<tab]
                guard (3...20).contains(token.count), token.allSatisfy({
                    (65...90).contains($0) || (97...122).contains($0) || $0 == 45
                }) else { continue }
                let alias = row.dropFirst(token.count + 1).prefix(while: { $0 != 9 && $0 != 13 })
                let word = String(decoding: token, as: UTF8.self)
                let normalized = Self.key(word)
                guard normalized.utf8.count >= 3 else { continue }
                if !alias.elementsEqual(token), Self.key(String(decoding: alias, as: UTF8.self)) != normalized { continue }
                words[normalized] = word
            }
        }
        technical = words.keys.filter { key in
            guard let word = words[key] else { return false }
            return word.dropFirst().contains(where: { $0.isUppercase }) || word.contains("-")
        }.sorted()
    }

    private static func key(_ text: String) -> String {
        let lower = text.lowercased()
        return lower.utf8.contains(45) ? lower.filter { $0 != "-" } : lower
    }

    // Only one English insertion is offered per composition. Typing more letters
    // refines the existing suggestion without pushing native candidates off the page.
    func suggestion(_ raw: String, doublePinyin: Bool, translate: (String) -> String?) -> (text: String, isCompletion: Bool)? {
        let letters = Array(raw.utf8)
        guard !words.isEmpty, letters.allSatisfy({ (97...122).contains($0) }) else { return nil }
        for length in stride(from: min(20, letters.count - 1), through: 3, by: -1) {
            for start in 0...(letters.count - length) {
                let end = start + length
                if doublePinyin && (start % 2 != 0 || (letters.count - end) % 2 != 0) { continue }
                let english = String(decoding: letters[start..<end], as: UTF8.self)
                let exact = words[english]
                let word: String
                if let exact { word = exact }
                else if end == letters.count, length >= 4, let completion = completion(english) { word = completion }
                else { continue }
                // Common syllables and their concatenations are poor evidence of an English switch.
                guard !Self.isPinyin(english) else { continue }
                let prefix = String(decoding: letters[..<start], as: UTF8.self)
                let suffix = String(decoding: letters[end...], as: UTF8.self)
                if !doublePinyin && (!Self.isPinyin(prefix) || !Self.isPinyin(suffix)) { continue }
                guard let before = translate(prefix), let after = translate(suffix) else { continue }
                return (before + word + after, exact == nil)
            }
        }
        return nil
    }

    private func completion(_ prefix: String) -> String? {
        var low = 0, high = technical.count
        while low < high {
            let middle = (low + high) / 2
            if technical[middle] < prefix { low = middle + 1 } else { high = middle }
        }
        guard low < technical.count, technical[low].hasPrefix(prefix) else { return nil }
        return words[technical[low]]
    }

    // Readings from the bundled 8105 character table. Testing syllable count as
    // well as spelling excludes suggestive-but-incomplete Rime abbreviations.
    private static let syllables = Set("""
a ai an ang ao ba bai ban bang bao bei ben beng bi bian biang biao bie bin bing bo bu ca cai can cang cao ce cei cen ceng cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du duan dui dun duo e ei en eng er fa fan fang fei fen feng fiao fo fou fu ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lun luo lv lve ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nuo nv nve o ou pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun ran rang rao re ren reng ri rong rou ru rua ruan rui run ruo sa sai san sang sao se sen seng sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo ta tai tan tang tao te tei teng ti tian tiao tie ting tong tou tu tuan tui tun tuo wa wai wan wang wei wen weng wo wu xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo
""".split(separator: " ").map(String.init))

    static func isPinyin(_ input: String, characters: Int? = nil) -> Bool {
        let bytes = Array(input.utf8)
        guard bytes.count < 63 else { return false }
        // Bit n denotes a full segmentation into n syllables ending at this position.
        var counts = [UInt64](repeating: 0, count: bytes.count + 1)
        counts[0] = 1
        for start in bytes.indices where counts[start] != 0 {
            for end in (start + 1)...min(start + 6, bytes.count) {
                let part = String(decoding: bytes[start..<end], as: UTF8.self)
                if syllables.contains(part) { counts[end] |= counts[start] << 1 }
            }
        }
        if let characters { return counts[bytes.count] & (1 << characters) != 0 }
        return counts[bytes.count] != 0
    }
}
