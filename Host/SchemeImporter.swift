import Foundation
import Rime
import SwiftUI
import UniformTypeIdentifiers

private enum SchemeImportError: LocalizedError {
    case missing, invalid(String), unavailable
    var errorDescription: String? {
        switch self {
        case .missing: return "文件夹顶层需要至少一个 .schema.yaml 方案文件。"
        case .invalid(let id): return "无法部署方案「" + id + "」。请检查方案文件、词典和依赖是否齐全。"
        case .unavailable: return "无法读取 Yah 内置的 Rime 数据。"
        }
    }
}

private actor SchemeImporter {
    static let shared = SchemeImporter()

    private var didSetup = false

    func install(from source: URL) throws -> CommunitySchemes {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        let root = try CommunitySchemes.root()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let revision = UUID()
        let stage = root.appendingPathComponent(revision.uuidString)
        let user = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var published = false
        defer {
            try? fm.removeItem(at: user)
            if !published { try? fm.removeItem(at: stage) }
        }
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let keyboard = try fm.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
                .compactMap({ Bundle(url: $0) }).first(where: { $0.bundleIdentifier == "local.yah.ios.keyboard" }),
              let bundled = keyboard.url(forResource: "RimeData", withExtension: nil)
        else { throw SchemeImportError.unavailable }
        let ids = try fm.contentsOfDirectory(atPath: source.path).filter { $0.hasSuffix(".schema.yaml") }
            .map { String($0.dropLast(".schema.yaml".count)) }.sorted()
        guard !ids.isEmpty else { throw SchemeImportError.missing }
        for id in ids {
            guard !id.isEmpty, id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 })
            else { throw SchemeImportError.invalid(id) }
        }
        try fm.copyItem(at: bundled, to: stage)
        try fm.createDirectory(at: user, withIntermediateDirectories: true)
        try copySources(from: source, to: stage)
        let schemes = try deploy(ids: ids, data: stage, user: user)
        let built = user.appendingPathComponent("build")
        for file in try fm.contentsOfDirectory(at: built, includingPropertiesForKeys: nil) {
            let output = stage.appendingPathComponent("build").appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
            try fm.copyItem(at: file, to: output)
        }
        try Data().write(to: stage.appendingPathComponent(".lease"))
        let library = CommunitySchemes(revision: revision, schemes: schemes)
        try JSONEncoder().encode(library).write(to: root.appendingPathComponent("installed.json"), options: .atomic)
        published = true
        for folder in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard folder.lastPathComponent != revision.uuidString, UUID(uuidString: folder.lastPathComponent) != nil else { continue }
            let fd = open(folder.appendingPathComponent(".lease").path, O_RDONLY)
            if fd >= 0 {
                if flock(fd, LOCK_EX | LOCK_NB) == 0 { try? fm.removeItem(at: folder) }
                close(fd)
            }
        }
        return library
    }

    private func copySources(from source: URL, to target: URL) throws {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        for file in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles) {
            let name = file.lastPathComponent
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, name != "build", name != "sync", !name.hasSuffix(".userdb"),
                  name != "user.yaml", name != "installation.yaml" else { continue }
            let output = target.appendingPathComponent(name)
            if values.isDirectory == true {
                try fm.createDirectory(at: output, withIntermediateDirectories: true)
                try copySources(from: file, to: output)
            } else if values.isRegularFile == true && ["yaml","lua","txt","json","ocd2","gram","bin"].contains(file.pathExtension) {
                if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
                try fm.copyItem(at: file, to: output)
            }
        }
    }

    private func deploy(ids: [String], data: URL, user: URL) throws -> [CommunitySchemes.Scheme] {
        let api = rime_get_api()!.pointee
        return try data.path.withCString { shared in
            try user.path.withCString { writable in
                try "rime.yah.import".withCString { name in
                    var traits = RimeTraits()
                    traits.data_size = Int32(MemoryLayout<RimeTraits>.size - MemoryLayout<Int32>.size)
                    traits.shared_data_dir = shared
                    traits.user_data_dir = writable
                    traits.app_name = name
                    if !didSetup { api.setup(&traits); didSetup = true }
                    api.deployer_initialize(&traits)
                    defer { api.finalize() }
                    return try ids.map { id in
                        let path = data.appendingPathComponent(id + ".schema.yaml").path
                        guard api.deploy_schema(path) else { throw SchemeImportError.invalid(id) }
                        let compiled = user.appendingPathComponent("build/" + id + ".schema.yaml")
                        guard FileManager.default.fileExists(atPath: compiled.path) else { throw SchemeImportError.invalid(id) }
                        var config = RimeConfig()
                        guard api.schema_open(id, &config) else { throw SchemeImportError.invalid(id) }
                        defer { api.config_close(&config) }
                        var display = [CChar](repeating: 0, count: 512)
                        let title = api.config_get_string(&config, "schema/name", &display, display.count) ? String(cString: display) : id
                        let alphabet = api.config_get_string(&config, "speller/alphabet", &display, display.count) ? String(cString: display) : nil
                        return .init(id: id, name: title, alphabet: alphabet)
                    }
                }
            }
        }
    }
}

struct CommunitySchemeSettings: View {
    @State private var installed = CommunitySchemes.installed()
    @State private var picking = false
    @State private var working = false
    @State private var message = ""

    var body: some View {
        Form {
            Section { NavigationLink("个人词库") { PersonalLexiconSettings() } }
            Section("已导入") {
                if let installed {
                    ForEach(installed.schemes, id: \.id) { scheme in
                        LabeledContent(scheme.name, value: scheme.id)
                    }
                } else { Text("尚未导入社区方案") }
            }
            Section {
                Button(working ? "正在部署…" : "导入 Rime 方案文件夹") { picking = true }
                    .disabled(working)
                if working { ProgressView() }
                if !message.isEmpty { Text(message) }
            } footer: {
                Text("选择包含 .schema.yaml 和所需词典的文件夹。Yah 在本机编译，成功后替换上次导入的一组方案。回到键盘，点候选栏左侧的方案名即可切换。")
            }
        }
        .navigationTitle("社区方案")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            switch result {
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
            case .success(let url):
                working = true
                message = ""
                Task {
                    defer { working = false }
                    do {
                        installed = try await SchemeImporter.shared.install(from: url)
                        message = "部署完成。"
                    } catch { message = error.localizedDescription }
                }
            }
        }
    }
}

private actor PersonalLexiconStore {
    static let shared = PersonalLexiconStore()
    func load() throws -> [PersonalLexicon.Entry] { try PersonalLexicon.load() }

    func change(removing old: PersonalLexicon.Entry? = nil, adding updates: [PersonalLexicon.Entry] = []) throws -> [PersonalLexicon.Entry] {
        var current = try load()
        if let old {
            guard let index = current.firstIndex(of: old) else { throw PersonalLexicon.ImportError.changed }
            current.remove(at: index)
        }
        let result = PersonalLexicon.merged(current, updates)
        try PersonalLexicon.table(result).write(to: PersonalLexicon.file(), options: [.atomic, .completeFileProtection])
        return result
    }

    func importFile(_ url: URL) throws -> [PersonalLexicon.Entry] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.seekToEnd() <= PersonalLexicon.textLimit else { throw PersonalLexicon.ImportError.tooLarge }
        try handle.seek(toOffset: 0)
        let data = try handle.read(upToCount: PersonalLexicon.textLimit + 1) ?? Data()
        let dictionary = url.lastPathComponent.lowercased().hasSuffix(".dict.yaml")
        return try change(adding: PersonalLexicon.parse(data, rimeDictionary: dictionary))
    }
}

private struct PhraseTableDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let data: Data
    init(entries: [PersonalLexicon.Entry]) { data = Data(PersonalLexicon.serialize(entries).utf8) }
    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = contents
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

private struct PersonalLexiconSettings: View {
    @State private var entries: [PersonalLexicon.Entry] = []
    @State private var search = ""
    @State private var picking = false
    @State private var exporting = false
    @State private var editor = false
    @State private var editing: PersonalLexicon.Entry?
    @State private var phrase = ""
    @State private var code = ""
    @State private var weight = ""
    @State private var message = ""
    @State private var busy = false

    var body: some View {
        let matches = entries.lazy.filter { search.isEmpty || $0.phrase.localizedCaseInsensitiveContains(search) || $0.code.localizedCaseInsensitiveContains(search) }
        Form {
            Section {
                Button("添加词条") { open(nil) }
                Button("导入文本词库") { picking = true }
                Button("导出文本词库") { exporting = true }.disabled(entries.isEmpty)
                if busy { ProgressView() }
                if !message.isEmpty { Text(message) }
            } footer: {
                Text("支持 UTF-8 的 Rime 自定义短语和独立 .dict.yaml 词典。每行依次为词条、字母编码、可选整数权重，用制表符分隔。同一词条与编码重复导入时更新权重。")
            }
            Section {
                ForEach(Array(matches.prefix(100))) { item in
                    Button { open(item) } label: {
                        VStack(alignment: .leading) {
                            Text(item.phrase).foregroundStyle(.primary)
                            Text("\(item.code) · 权重 \(item.weight)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) { run { try await PersonalLexiconStore.shared.change(removing: item) } }
                    }
                }
                if matches.dropFirst(100).first != nil { Text("请搜索以查看其他词条。").foregroundStyle(.secondary) }
            } header: { Text("个人词库（\(entries.count)）") }
              footer: { Text("内置全拼、小鹤双拼和自然码双拼按输入的实际编码匹配，九宫格自动映射相同字母的数字键。切回 Yah 键盘后生效。") }
        }
        .disabled(busy)
        .navigationTitle("个人词库")
        .searchable(text: $search, prompt: "搜索词条或编码")
        .task { do { entries = try await PersonalLexiconStore.shared.load() } catch { message = error.localizedDescription } }
        .sheet(isPresented: $editor) {
            NavigationStack {
                Form {
                    TextField("词条", text: $phrase)
                    TextField("字母编码", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("权重", text: $weight).keyboardType(.numbersAndPunctuation)
                    if !message.isEmpty { Text(message) }
                }
                .navigationTitle(editing == nil ? "添加词条" : "编辑词条")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { editor = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { saveEntry() }.disabled(busy || phrase.isEmpty || code.isEmpty)
                    }
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.plainText, .tabSeparatedText, .data]) { result in
            switch result {
            case .success(let url):
                run { try await PersonalLexiconStore.shared.importFile(url) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
            }
        }
        .fileExporter(isPresented: $exporting, document: exporting ? PhraseTableDocument(entries: entries) : nil, contentType: .plainText, defaultFilename: "custom_phrase") { result in
            if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
        }
    }

    private func open(_ entry: PersonalLexicon.Entry?) {
        editing = entry
        phrase = entry?.phrase ?? ""
        code = entry?.code ?? ""
        weight = String(entry?.weight ?? 0)
        message = ""
        editor = true
    }

    private func saveEntry() {
        do {
            let typed = "\(phrase)\t\(code)\t\(weight.isEmpty ? "0" : weight)"
            let updates = try PersonalLexicon.parse(Data(typed.utf8))
            let old = editing
            run {
                let result = try await PersonalLexiconStore.shared.change(removing: old, adding: updates)
                editor = false
                return result
            }
        } catch { message = error.localizedDescription }
    }

    private func run(_ perform: @escaping @MainActor () async throws -> [PersonalLexicon.Entry]) {
        busy = true
        message = ""
        Task { @MainActor in
            defer { busy = false }
            do { entries = try await perform() }
            catch { message = error.localizedDescription }
        }
    }
}
