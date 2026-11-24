import Foundation
import Rime

final class YahRimeSession {
    private static let api = rime_get_api()!.pointee
    private let id: RimeSessionId

    private static let ready: Bool = {
        let fm = FileManager.default
        guard let data = Bundle.main.url(forResource: "RimeData", withExtension: nil),
              let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return false }
        let user = support.appendingPathComponent("Yah/Rime")
        do { try fm.createDirectory(at: user, withIntermediateDirectories: true) }
        catch { return false }
        data.path.withCString { sharedPath in
            user.path.withCString { userPath in
                "rime.yah".withCString { name in
                    var traits = RimeTraits()
                    traits.data_size = Int32(MemoryLayout<RimeTraits>.size - MemoryLayout<Int32>.size)
                    traits.shared_data_dir = sharedPath
                    traits.user_data_dir = userPath
                    traits.app_name = name
                    api.setup(&traits)
                    api.initialize(&traits)
                }
            }
        }
        // Packaged YAML timestamps can be older than the existing deployment.
        // Check the workspace so librime can rebuild changed dictionaries.
        if api.start_maintenance(true) { api.join_maintenance_thread() }
        return true
    }()

    init?() {
        guard Self.ready else { return nil }
        let session = Self.api.create_session()
        guard session != 0 else { return nil }
        guard Self.api.select_schema(session, "yah") else {
            _ = Self.api.destroy_session(session)
            return nil
        }
        id = session
    }

    deinit { _ = Self.api.destroy_session(id) }
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

    func processKey(_ key: Int32) { _ = Self.api.process_key(id, key, 0) }
    func reset() { Self.api.clear_composition(id) }
    func pageBackward(_ backward: Bool) { _ = Self.api.change_page(id, backward) }
    func canPageBackward(_ backward: Bool) -> Bool {
        withMenu { $0.num_candidates > 0 && (backward ? $0.page_no > 0 : !$0.is_last_page) } ?? false
    }

    func choose(_ index: Int) -> String? {
        guard Self.api.select_candidate_on_current_page(id, index) else { return nil }
        var commit = RimeCommit()
        commit.data_size = Int32(MemoryLayout<RimeCommit>.size - MemoryLayout<Int32>.size)
        guard Self.api.get_commit(id, &commit) else { return nil }
        defer { _ = Self.api.free_commit(&commit) }
        return String(cString: commit.text)
    }
}
