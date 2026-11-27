import Foundation
import Rime

enum RimeOutputForm: String, CaseIterable {
    case simplified = "yah_simplified"
    case traditional = "traditionalization"
    case taiwan = "yah_taiwan"
    case hongKong = "yah_hongkong"

    var title: String {
        switch self {
        case .simplified: return "简体"
        case .traditional: return "通用繁体"
        case .taiwan: return "台湾繁体"
        case .hongKong: return "香港繁体"
        }
    }

    var suffix: String {
        switch self {
        case .simplified: return ""
        case .traditional: return "·繁"
        case .taiwan: return "·台"
        case .hongKong: return "·港"
        }
    }

    static func preferred(in defaults: UserDefaults = .standard) -> Self {
        if let saved = defaults.string(forKey: "outputForm"), let form = Self(rawValue: saved) {
            return form
        }
        let previous: Self = defaults.bool(forKey: "traditional") ? .traditional : .simplified
        if defaults.object(forKey: "traditional") != nil { previous.save(in: defaults) }
        return previous
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: "outputForm")
    }
}

final class YahRimeSession {
    private static let api = rime_get_api()!.pointee
    private var id: RimeSessionId = 0
    private var selectedSchema = "rime_ice"
    private var outputForm = RimeOutputForm.simplified
    private static var directory: URL?
    private static var lease: Int32 = -1
    private static var didSetup = false
    private static let sessions = NSHashTable<YahRimeSession>.weakObjects()

    // All callers are keyboard / input-method controllers on the main thread.
    static func configure(community: URL? = nil) -> Bool {
        let fm = FileManager.default
        guard let data = community ?? Bundle.main.url(forResource: "RimeData", withExtension: nil),
              let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return false }
        if directory == data {
            #if os(iOS)
            if community == nil { _ = refreshPersonalLexicon() }
            #endif
            return true
        }
        let user = support.appendingPathComponent(community == nil ? "Yah/RimeIce" : "Yah/CommunityUser")
        do { try fm.createDirectory(at: user, withIntermediateDirectories: true) }
        catch { return false }
        var nextLease: Int32 = -1
        if community != nil {
            nextLease = open(data.appendingPathComponent(".lease").path, O_RDONLY)
            guard nextLease >= 0 else { return false }
            guard flock(nextLease, LOCK_SH | LOCK_NB) == 0 else { close(nextLease); return false }
        }
        #if os(iOS)
        if community == nil { _ = try? syncPersonalTable(data: data, user: user) }
        #endif
        restart(data: data, user: user, nextLease: nextLease)
        return true
    }

    private static func restart(data: URL, user: URL, nextLease: Int32) {
        let active = sessions.allObjects
        for session in active where session.id != 0 {
            _ = api.destroy_session(session.id)
            session.id = 0
        }
        if directory != nil { api.finalize() }
        if lease >= 0 { close(lease) }
        lease = nextLease
        data.path.withCString { sharedPath in
            user.path.withCString { userPath in
                "rime.yah".withCString { name in
                    var traits = RimeTraits()
                    traits.data_size = Int32(MemoryLayout<RimeTraits>.size - MemoryLayout<Int32>.size)
                    traits.shared_data_dir = sharedPath
                    traits.user_data_dir = userPath
                    traits.app_name = name
                    if !didSetup { api.setup(&traits); didSetup = true }
                    api.initialize(&traits)
                }
            }
        }
        directory = data
        for session in active {
            session.id = api.create_session()
            guard session.id != 0 else { continue }
            if !api.select_schema(session.id, session.selectedSchema) {
                _ = session.useSchema("rime_ice")
            }
            session.setOutputForm(session.outputForm)
        }
    }

    #if os(iOS)
    private static var loadedPersonalRevision: String?

    // Only the containing app publishes the source file. The keyboard installs a private
    // copy for the built-in stabledb translator, which looks for custom_phrase.txt.
    private static func syncPersonalTable(data: URL, user: URL) throws -> Bool {
        let fm = FileManager.default
        let source = try PersonalLexicon.file()
        guard fm.fileExists(atPath: source.path) else { return false }
        let metadata = try fm.attributesOfItem(atPath: source.path)
        guard let inode = metadata[.systemFileNumber] as? NSNumber,
              let stamp = metadata[.modificationDate] as? Date else { return false }
        let version = "\(inode)-\(stamp.timeIntervalSince1970)"
        let marker = user.appendingPathComponent(".yah-personal-revision")
        if (try? String(contentsOf: marker, encoding: .utf8)) == version {
            let changed = loadedPersonalRevision != version
            loadedPersonalRevision = version
            return changed
        }
        let target = user.appendingPathComponent("custom_phrase.txt")
        let original = user.appendingPathComponent(".yah-original-phrases")
        let header = Data("# Yah managed phrase table\n".utf8)
        if fm.fileExists(atPath: target.path), !fm.fileExists(atPath: original.path) {
            let prior = try Data(contentsOf: target)
            if !prior.starts(with: header) { try prior.write(to: original, options: .atomic) }
        }
        let base = fm.fileExists(atPath: original.path) ? original : data.appendingPathComponent("custom_phrase.txt")
        var table = header
        table.append(try Data(contentsOf: base))
        table.append(0x0a)
        table.append(try Data(contentsOf: source))
        try table.write(to: target, options: .atomic)
        try version.write(to: marker, atomically: true, encoding: .utf8)
        loadedPersonalRevision = version
        return true
    }

    @discardableResult static func refreshPersonalLexicon() -> Bool {
        guard let data = directory, lease < 0,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return false }
        let user = support.appendingPathComponent("Yah/RimeIce")
        guard (try? syncPersonalTable(data: data, user: user)) == true else { return false }
        restart(data: data, user: user, nextLease: -1)
        return true
    }
    #endif

    init?() {
        guard Self.directory != nil || Self.configure() else { return nil }
        id = Self.api.create_session()
        guard id != 0 else { return nil }
        guard Self.api.select_schema(id, "rime_ice") else { return nil }
        Self.sessions.add(self)
    }

    func replaceInput(_ text: String) -> Bool {
        id != 0 && Self.api.set_input(id, text)
    }

    // Rime uses UTF-8 byte offsets. A nonzero start means the active
    // segment follows text the user already chose in this composition.
    var selectedPreedit: String? {
        var context = RimeContext()
        context.data_size = Int32(MemoryLayout<RimeContext>.size - MemoryLayout<Int32>.size)
        guard Self.api.get_context(id, &context) else { return nil }
        defer { _ = Self.api.free_context(&context) }
        guard context.composition.sel_start > 0, let preedit = context.composition.preedit else { return nil }
        return String(cString: preedit)
    }

    var firstCompleteCandidate: String? {
        var context = RimeContext()
        context.data_size = Int32(MemoryLayout<RimeContext>.size - MemoryLayout<Int32>.size)
        guard Self.api.get_context(id, &context) else { return nil }
        defer { _ = Self.api.free_context(&context) }
        guard context.menu.num_candidates > 0,
              context.composition.sel_start == 0,
              context.composition.sel_end == context.composition.length,
              let first = context.menu.candidates[0].text,
              let preview = context.commit_text_preview, strcmp(first, preview) == 0 else { return nil }
        return String(cString: first)
    }

    func useSchema(_ name: String) -> Bool {
        guard id != 0, Self.api.select_schema(id, name) else { return false }
        selectedSchema = name
        setOutputForm(outputForm)
        return true
    }

    func setOutputForm(_ form: RimeOutputForm) {
        outputForm = form
        guard id != 0 else { return }
        // Imported schemas supply their own OpenCC data and retain the historical switch.
        if Self.lease >= 0 {
            Self.api.set_option(id, "traditionalization", form != .simplified)
            return
        }
        for option in RimeOutputForm.allCases {
            let enabled = option == form
            if Self.api.get_option(id, option.rawValue) != enabled {
                Self.api.set_option(id, option.rawValue, enabled)
            }
        }
    }

    deinit { if id != 0 { _ = Self.api.destroy_session(id) } }
    var input: String { Self.api.get_input(id).map { String(cString: $0) } ?? "" }

    private func withMenu<T>(_ read: (RimeMenu) -> T) -> T? {
        var context = RimeContext()
        context.data_size = Int32(MemoryLayout<RimeContext>.size - MemoryLayout<Int32>.size)
        guard Self.api.get_context(id, &context) else { return nil }
        defer { _ = Self.api.free_context(&context) }
        return read(context.menu)
    }

    var choices: [String] {
        withMenu { menu in
            (0..<Int(menu.num_candidates)).map { String(cString: menu.candidates[$0].text) }
        } ?? []
    }

    @discardableResult
    func processKey(_ key: Int32) -> Bool { Self.api.process_key(id, key, 0) }
    func reset() { Self.api.clear_composition(id) }
    func pageBackward(_ backward: Bool) { _ = Self.api.change_page(id, backward) }
    func canPageBackward(_ backward: Bool) -> Bool {
        withMenu { $0.num_candidates > 0 && (backward ? $0.page_no > 0 : !$0.is_last_page) } ?? false
    }

    func candidateTexts(startingAt start: Int, limit: Int) -> [String] {
        guard id != 0, let offset = Int32(exactly: start), offset >= 0, limit > 0 else { return [] }
        var iterator = RimeCandidateListIterator()
        guard Self.api.candidate_list_from_index(id, &iterator, offset) else { return [] }
        defer { Self.api.candidate_list_end(&iterator) }
        var result: [String] = []
        while result.count < limit, Self.api.candidate_list_next(&iterator) {
            result.append(String(cString: iterator.candidate.text))
        }
        return result
    }

    func chooseAbsolute(_ index: Int) -> String? {
        guard index >= 0, id != 0, Self.api.select_candidate(id, index) else { return nil }
        return takeCommit()
    }

    func choose(_ index: Int) -> String? {
        guard Self.api.select_candidate_on_current_page(id, index) else { return nil }
        return takeCommit()
    }

    func takeCommit() -> String? {
        var commit = RimeCommit()
        commit.data_size = Int32(MemoryLayout<RimeCommit>.size - MemoryLayout<Int32>.size)
        guard Self.api.get_commit(id, &commit) else { return nil }
        defer { _ = Self.api.free_commit(&commit) }
        return String(cString: commit.text)
    }
}
