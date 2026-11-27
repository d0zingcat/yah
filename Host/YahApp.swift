import YahOfflineSpeech
import UserNotifications
import SwiftUI
import UIKit
import AVFAudio
import AppIntents
import Speech

@main
struct YahApp: App {
    @UIApplicationDelegateAdaptor(VoiceNotifications.self) private var notifications
    var body: some Scene {
        WindowGroup {
            VoiceSetupView()
        }
    }
}

private final class VoiceNotifications: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard VoicePrompt.recognizes(response) else { return }
        await MainActor.run { VoiceLaunch.shared.request = UUID() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

@MainActor
private struct VoiceSetupView: View {
    private enum Phase { case idle, requestingPermission, recording, transcribing }
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var voiceLaunch = VoiceLaunch.shared
    @AppStorage("voiceRecognitionMode") private var recognitionMode = "automatic"
    @State private var configuration = VoiceConfiguration.defaults
    @State private var recorder = VoiceRecorder()
    @StateObject private var standby = StandbyControl()
    @State private var enablingStandby = false
    @State private var enableTask: Task<Void, Never>?
    @AppStorage("deliverRecognizedSpeech") private var deliverRecognizedSpeech = false
    @State private var transcript = ""
    @State private var draft = ""
    @AppStorage("offlineDictationPreview") private var offlinePreview = true
    @State private var message = ""
    @State private var phase = Phase.idle
    @State private var transcriptionTask: Task<Void, Never>?
    private struct PendingSpeech: Codable {
        let name: String
        let recording: UUID?
        let expires: Date
        var file: URL { FileManager.default.temporaryDirectory.appendingPathComponent(name) }
        static let key = "pendingOfflineRecording"

        init(file: URL, recording: UUID?) {
            name = file.lastPathComponent
            self.recording = recording
            expires = Date().addingTimeInterval(300)
        }

        func save() {
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
            if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
            if let recording { try? VoiceHandoff.publishRecovery(recording, expires: expires) }
        }

        static func restore() -> Self? {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let job = try? JSONDecoder().decode(Self.self, from: data),
                  job.name == (job.name as NSString).lastPathComponent, job.name.hasSuffix(".wav") else { return nil }
            guard job.expires > Date(), FileManager.default.fileExists(atPath: job.file.path) else {
                job.remove()
                return nil
            }
            return job
        }

        func remove() {
            try? FileManager.default.removeItem(at: file)
            UserDefaults.standard.removeObject(forKey: Self.key)
            if let recording { VoiceHandoff.clearRecovery(recording) }
        }
    }
    @State private var requestedRecovery: UUID?
    @State private var pendingSpeech: PendingSpeech?
    @State private var startTask: Task<Void, Never>?
    @State private var saveSucceeded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let active = standby.session {
                        HStack {
                            Label("连续听写已开启", systemImage: "mic.fill").foregroundStyle(.orange)
                            Spacer()
                            Text(timerInterval: min(Date(), active.expires)...active.expires, countsDown: true)
                                .monospacedDigit().fixedSize()
                        }
                        Text("回到原输入框，点 Yah 键盘上的麦克风开始说话，再点停止即可输入。")
                            .font(.footnote)
                        Button("结束连续听写") { endStandby() }
                    } else {
                        Button {
                            enableStandby()
                        } label: {
                            Label(enablingStandby ? "正在准备麦克风…" : "开启十分钟连续听写", systemImage: "mic")
                        }
                        .disabled(phase != .idle || enablingStandby)
                        Text("先在系统设置 → 通用 → 键盘 → 键盘 → Yah 中开启「允许完全访问」。开启连续听写后，麦克风橙点会亮起，待命声音会被丢弃。只有在键盘上点开始后才会录下本段。十分钟后自动结束。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button {
                        if phase == .recording { recorder.stop() }
                        else if phase == .idle { startRecording() }
                    } label: {
                        Label(
                            phase == .recording ? "结束录音并转写" : "开始语音输入",
                            systemImage: phase == .recording ? "stop.circle.fill" : "mic.circle.fill"
                        )
                    }
                    .disabled(phase == .requestingPermission || phase == .transcribing || enablingStandby || (standby.session != nil && phase == .idle))

                    if phase == .idle && standby.session == nil && !enablingStandby {
                        Button("开始跨应用语音输入") { startRecording(forKeyboard: true) }
                        Text("仅本次录音会在切换应用后继续。回到目标输入框，在 Yah 键盘点停止即可转写。")
                            .font(.footnote)
                    }
                    Button("设置备用语音通知") {
                        Task {
                            do {
                                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: .alert)
                                show(granted ? "已允许备用通知。需要时在键盘方案菜单中点「语音工具」。" : "请在系统设置的 Yah 通知中允许提醒。", succeeded: granted)
                            } catch { show(error.localizedDescription, succeeded: false) }
                        }
                    }
                    if phase == .requestingPermission || phase == .recording {
                        Button("取消录音", role: .cancel, action: cancelRecording)
                    }
                    if phase == .recording, !draft.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("听写草稿").font(.caption).foregroundStyle(.secondary)
                            Text(draft).lineLimit(2)
                        }.accessibilityElement(children: .combine)
                    }
                    if phase == .requestingPermission { ProgressView("正在准备麦克风…") }
                    if phase == .transcribing {
                        ProgressView("正在转写…")
                    }
                    if phase == .idle, let pending = pendingSpeech {
                        Button("继续上次离线转写") { resumeSpeech(pending) }
                        Button("丢弃上次录音", role: .destructive) {
                            pending.remove()
                            pendingSpeech = nil
                        }
                    }
                    if !message.isEmpty {
                        Text(message)
                            .foregroundStyle(saveSucceeded ? .green : .red)
                    }

                    TextEditor(text: $transcript)
                        .frame(minHeight: 120)
                        .overlay(alignment: .topLeading) {
                            if transcript.isEmpty {
                                Text("转写结果会显示在这里")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }

                    Toggle("转写完成后送到键盘", isOn: $deliverRecognizedSpeech)
                        .disabled(phase != .idle)
                    Button("送到 Yah 键盘") {
                        do {
                            try VoiceHandoff.publish(transcript)
                            show("请在五分钟内回到目标输入框，点 Yah 键盘的「插入转写」。", succeeded: true)
                        } catch {
                            show("无法共享转写，请使用下方的「复制文本」。", succeeded: false)
                        }
                    }
                    .disabled(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || phase != .idle)
                    Button("复制文本") {
                        UIPasteboard.general.string = transcript
                        show("已复制。回到输入框，点 Yah 键盘的「语音」再粘贴。", succeeded: true)
                    }
                    .disabled(transcript.isEmpty)
                } header: {
                    Text("语音输入")
                } footer: {
                    Text("也可以对 Siri 说「用 Yah 开始语音输入」，或把快捷指令「开始语音输入」绑定到操作按钮。回到原输入框，点 Yah 键盘的停止键即可转写并输入。")
                }

                Section("语音服务") {
                    Picker("识别方式", selection: $recognitionMode) {
                        Text("自动").tag("automatic")
                        Text("内置离线中文识别").tag("offline")
                        Text("Apple 设备端中文识别").tag("device")
                        Text("ElevenLabs").tag("cloud")
                    }
                    Text("自动模式优先使用已保存的服务。服务失败时，同一段录音会转为本机识别。")
                        .font(.footnote)
                    if recognitionMode == "offline" || recognitionMode == "automatic" {
                        Toggle("显示离线听写草稿", isOn: $offlinePreview)
                    }
                    if recognitionMode == "automatic" || recognitionMode == "cloud" {
                    Picker("服务商", selection: $configuration.provider) {
                        ForEach(VoiceConfiguration.Provider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    SecureField("ElevenLabs API Key", text: $configuration.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("转写接口地址", text: $configuration.endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("模型", text: $configuration.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("语言代码（可选，如 zh / en）", text: $configuration.language)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                }
                .disabled(phase != .idle)

                Section {
                    Button("保存配置") { saveConfiguration() }
                    Button("清除配置", role: .destructive) { clearConfiguration() }
                } footer: {
                    Text("API Key 保存在此设备的 Keychain。转写时，录音和密钥都会发送到已保存的接口地址。")
                }
                .disabled(phase != .idle)

                Section("拼音键盘") {
                    NavigationLink("社区输入方案") { CommunitySchemeSettings() }
                    Text("可在系统设置 → 通用 → 键盘 → 键盘中添加 Yah。使用连续听写时，请在该列表点 Yah，打开「允许完全访问」。")
                }

            }
            .navigationTitle("Yah")
            .onAppear {
                if VoiceHandoff.keyboardTicket() == nil { try? VoiceHandoff.issueKeyboardTicket() }
                VoiceHandoff.clearExpired()
                if phase == .idle { pendingSpeech = PendingSpeech.restore() }
                loadConfiguration()
                consumeVoiceLaunch()
            }
            .task(id: pendingSpeech?.name) {
                guard let pending = pendingSpeech else { return }
                let remaining = max(0, min(300, pending.expires.timeIntervalSinceNow))
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                guard !Task.isCancelled, phase == .idle, pendingSpeech?.name == pending.name else { return }
                pending.remove()
                pendingSpeech = nil
            }
            .onOpenURL { url in
                guard url.scheme == "local-yah-voice" else { return }
                if url.host == "resume" {
                    guard url.pathComponents.count == 3, let id = UUID(uuidString: url.pathComponents[1]),
                          VoiceHandoff.acceptKeyboardLink(url) else {
                        show("请点「继续上次离线转写」。", succeeded: false)
                        return
                    }
                    if phase == .idle { pendingSpeech = PendingSpeech.restore() }
                    guard pendingSpeech?.recording == id else {
                        show("这段待转写的录音已结束或过期。", succeeded: false)
                        return
                    }
                    requestedRecovery = id
                    resumeIfRequested()
                    return
                }
                guard url.host == "start" else { return }
                if VoiceHandoff.acceptKeyboardLink(url) {
                    voiceLaunch.request = UUID()
                    consumeVoiceLaunch()
                } else if phase == .idle {
                    show("首次使用，请点「开始跨应用语音输入」。下次可直接点键盘麦克风。", succeeded: true)
                }
            }
            .onChange(of: voiceLaunch.request) { _ in consumeVoiceLaunch() }
            .onDisappear { if recorder.keyboardSessionID == nil && standby.session == nil { cancelRecording() } }
            .onChange(of: scenePhase) { value in
                if value == .background {
                    if enablingStandby { endStandby() }
                    if recorder.keyboardSessionID == nil && standby.session == nil { cancelRecording() }
                }
                if value == .active { VoiceHandoff.clearExpired(); consumeVoiceLaunch(isActive: true) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
                endStandby()
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
                .receive(on: DispatchQueue.main)) { notification in
                if (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                    == AVAudioSession.InterruptionType.began.rawValue {
                    endStandby()
                    recorder.fail()
                }
            }
        }
    }

    private func enableStandby() {
        guard phase == .idle, !enablingStandby, standby.session == nil else { return }
        enablingStandby = true
        enableTask = Task {
            defer { enablingStandby = false; enableTask = nil }
            do {
                try await recorder.enableStandby()
                try Task.checkCancellation()
                guard let expires = recorder.standbyDeadline, scenePhase != .background,
                      UIApplication.shared.isProtectedDataAvailable else { throw CancellationError() }
                recorder.standbyDidEnd = { standby.finish() }
                try standby.begin(until: expires, onStart: { id in
                    guard phase == .idle else {
                        VoiceHandoff.publishFailure("请等上一段听写结束后再试。", for: id)
                        VoiceHandoff.clearStart(id)
                        return
                    }
                    startRecording(forKeyboard: true, requestedID: id)
                }, onRetry: { id in
                    guard phase == .idle, let job = pendingSpeech ?? PendingSpeech.restore(),
                          job.recording == id else { return }
                    resumeSpeech(job)
                }, onEnd: { endStandby() })
                show("连续听写已开启。现在可以回到原输入框。", succeeded: true)
            } catch {
                recorder.disableStandby()
                standby.finish()
                if !Task.isCancelled { show(error.localizedDescription, succeeded: false) }
            }
        }
    }

    private func endStandby() {
        enableTask?.cancel()
        recorder.disableStandby()
        standby.finish()
    }

    private func consumeVoiceLaunch(isActive: Bool? = nil) {
        guard isActive ?? (scenePhase == .active) else { return }
        let keyboardRequest = VoiceHandoff.takeForegroundStart()
        guard voiceLaunch.request != nil || keyboardRequest != nil else { return }
        voiceLaunch.request = nil
        if phase == .idle && !enablingStandby { startRecording(forKeyboard: true) }
    }

    private func resumeIfRequested() {
        guard phase == .idle, let id = requestedRecovery else { return }
        requestedRecovery = nil
        if let pendingSpeech, pendingSpeech.recording == id { resumeSpeech(pendingSpeech) }
    }

    private func resumeSpeech(_ pending: PendingSpeech) {
        guard phase == .idle else { return }
        guard pending.expires > Date() else {
            pending.remove()
            pendingSpeech = nil
            show("这段待转写的录音已过期。", succeeded: false)
            return
        }
        if let id = pending.recording {
            do {
                try recorder.connectKeyboard(id: id)
                recorder.markTranscribing()
            } catch {
                show("暂时无法连接键盘，请稍后重试。", succeeded: false)
                return
            }
        }
        pendingSpeech = pending
        phase = .transcribing
        finishSpeech(pending.file, using: nil, useAppleSpeech: false, automaticFallback: false)

    }

    private func startRecording(forKeyboard: Bool = false, requestedID: UUID? = nil) {
        func reportFailure(_ text: String) {
            if let requestedID {
                VoiceHandoff.publishFailure(text, for: requestedID)
                VoiceHandoff.clearStart(requestedID)
            }
            show(text, succeeded: false)
        }
        if let pending = pendingSpeech {
            if pending.expires > Date() {
                reportFailure("请先继续转写或丢弃上一段录音。")
                return
            }
            pending.remove()
            pendingSpeech = nil
        }
        do {
            let stored: VoiceConfiguration?
            switch recognitionMode {
            case "device", "offline": stored = nil
            case "cloud": stored = try VoiceConfigurationStore.load()
            default: stored = try? VoiceConfigurationStore.load()
            }
            if recognitionMode == "cloud" && stored?.apiKey.isEmpty != false {
                throw VoiceTranscriptionError.missingAPIKey
            }
            if let stored, stored != configuration {
                reportFailure("请先保存修改后的语音配置。")
                return
            }
            let useAppleSpeech = recognitionMode == "device"
            let automaticFallback = recognitionMode == "automatic" && stored != nil
            draft = ""
            recorder.configurePreview(offline: stored == nil && !useAppleSpeech && offlinePreview) { text, _ in
                if phase == .recording, scenePhase == .active, draft != text { draft = text }
            }
            phase = .requestingPermission
            recorder.didFinish = { result in
                recorder.didFinish = nil
                switch result {
                case .success(let url):
                    phase = .transcribing
                    recorder.markTranscribing()
                    draft = ""
                    let job = PendingSpeech(file: url, recording: recorder.keyboardSessionID)
                    job.save()
                    pendingSpeech = job
                    finishSpeech(url, using: stored, useAppleSpeech: useAppleSpeech, automaticFallback: automaticFallback)
                case .failure(let error):
                    if let id = recorder.keyboardSessionID { VoiceHandoff.publishFailure(error.localizedDescription, for: id) }
                    recorder.disconnectKeyboard()
                    phase = .idle
                    reportFailure(error.localizedDescription)
                }
            }
            startTask = Task {
                do {
                    if useAppleSpeech {
                        guard SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))?.supportsOnDeviceRecognition == true else {
                            throw DeviceSpeechError.unavailable
                        }
                        let authorization = await withCheckedContinuation { continuation in
                            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
                        }
                        guard authorization == .authorized else { throw DeviceSpeechError.denied }
                        try Task.checkCancellation()
                    }
                    if requestedID != nil, recorder.standbyDeadline == nil { throw CancellationError() }
                    try await recorder.start()
                    try Task.checkCancellation()
                    if forKeyboard { try recorder.connectKeyboard(id: requestedID ?? UUID()) }
                    phase = .recording
                    show(forKeyboard ? "正在录音，切回目标输入框后点键盘上的停止。" : "正在录音…", succeeded: true)
                } catch {
                    guard !Task.isCancelled else { return }
                    recorder.didFinish = nil
                    recorder.cancel()
                    recorder.disconnectKeyboard()
                    phase = .idle
                    reportFailure(error.localizedDescription)
                }
            }
        } catch {
            reportFailure(error.localizedDescription)
        }
    }

    private func finishSpeech(_ file: URL, using stored: VoiceConfiguration?, useAppleSpeech: Bool, automaticFallback: Bool) {
        let recording = recorder.keyboardSessionID
        var background = UIBackgroundTaskIdentifier.invalid
        if recording != nil {
            background = UIApplication.shared.beginBackgroundTask(withName: "Yah 转写") {
                transcriptionTask?.cancel()
                if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
            }
        }
        transcriptionTask = Task {
            await transcribe(audioURL: file, using: stored, useAppleSpeech: useAppleSpeech,
                             automaticFallback: automaticFallback, recording: recording)
            if let recording { VoiceHandoff.clearStart(recording) }
            recorder.disconnectKeyboard()
            if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
            phase = .idle
            resumeIfRequested()
        }
    }

    private func cancelRecording() {
        guard phase == .requestingPermission || phase == .recording else { return }
        startTask?.cancel()
        recorder.didFinish = nil
        if let id = recorder.keyboardSessionID {
            VoiceHandoff.publishFailure("本段录音已取消。", for: id)
            VoiceHandoff.clearStart(id)
        }
        recorder.cancel()
        recorder.disconnectKeyboard()
        phase = .idle
        show("录音已取消。", succeeded: false)
    }

    @MainActor
    private func transcribe(audioURL: URL, using stored: VoiceConfiguration?, useAppleSpeech: Bool,
                            automaticFallback: Bool, recording: UUID?) async {
        var keepForRetry = false
        defer {
            if !keepForRetry {
                if let job = pendingSpeech, job.file.lastPathComponent == audioURL.lastPathComponent {
                    job.remove()
                    pendingSpeech = nil
                } else { try? FileManager.default.removeItem(at: audioURL) }
            }
        }
        var usedFallback = false
        var preservingFailedProviderAudio = stored != nil || useAppleSpeech
        do {
            let result: String
            if let stored {
                do {
                    result = try await VoiceTranscriptionProviderFactory.make(for: stored)
                        .transcribe(audioURL: audioURL, configuration: stored)
                } catch {
                    try Task.checkCancellation()
                    guard automaticFallback else { throw error }
                    preservingFailedProviderAudio = false
                    usedFallback = true
                    result = try await OfflineSpeech.shared.transcribe(audioURL)
                }
            } else if useAppleSpeech {
                result = try await DeviceSpeech().transcribe(audioURL)
            } else {
                result = try await OfflineSpeech.shared.transcribe(audioURL)
            }
            try Task.checkCancellation()
            transcript = result
            if recording != nil || deliverRecognizedSpeech {
                do {
                    try VoiceHandoff.publish(transcript, recordingID: recording)
                    show(usedFallback ? "云服务暂时不可用，本段已在设备上完成并送回键盘。" : "转写完成，已送到键盘。", succeeded: true)
                } catch {
                    show("转写已保留。键盘共享不可用，请复制文本。", succeeded: false)
                }
            } else {
                show(usedFallback ? "云服务暂时不可用，本段已在设备上完成。" : "转写完成。", succeeded: true)
            }
        } catch {
            if let pending = pendingSpeech, pending.file == audioURL, pending.expires > Date(),
               Task.isCancelled || preservingFailedProviderAudio {
                keepForRetry = true
                let hint = Task.isCancelled ? "系统已暂停转写。" : "本次服务未完成转写。"
                let message = hint + "五分钟内可用本机模型重试同一段录音。"
                if let recording { VoiceHandoff.publishFailure(message, for: recording) }
                show(message, succeeded: false)
            } else {
                if let recording { VoiceHandoff.publishFailure(error.localizedDescription, for: recording) }
                show(error.localizedDescription, succeeded: false)
            }
        }
    }

    private func loadConfiguration() {
        do {
            if let stored = try VoiceConfigurationStore.load() {
                configuration = stored
            }
        } catch {
            show(error.localizedDescription, succeeded: false)
        }
    }

    private func saveConfiguration() {
        configuration.endpoint = configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.language = configuration.language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuration.hasValidEndpoint else {
            show("请输入有效的 HTTPS 接口地址。", succeeded: false)
            return
        }
        guard !configuration.apiKey.isEmpty else {
            show("请输入 ElevenLabs API Key。", succeeded: false)
            return
        }
        guard !configuration.model.isEmpty else {
            show("请输入转写模型。", succeeded: false)
            return
        }
        do {
            try VoiceConfigurationStore.save(configuration)
            show("配置已保存。", succeeded: true)
        } catch {
            show(error.localizedDescription, succeeded: false)
        }
    }

    private func clearConfiguration() {
        do {
            try VoiceConfigurationStore.remove()
            configuration = .defaults
            show("语音配置已清除。", succeeded: true)
        } catch {
            show(error.localizedDescription, succeeded: false)
        }
    }

    private func show(_ text: String, succeeded: Bool) {
        message = text
        saveSucceeded = succeeded
    }
}

@MainActor
private final class StandbyControl: ObservableObject {
    @Published private(set) var session: VoiceHandoff.Standby?
    private var heartbeat: Timer?
    private var token: Int32?
    private var lastStart: UUID?

    func begin(until expires: Date, onStart: @escaping (UUID) -> Void,
               onRetry: @escaping (UUID) -> Void, onEnd: @escaping () -> Void) throws {
        let value = VoiceHandoff.Standby(id: UUID(), expires: expires)
        var registration: Int32 = 0
        let check = { [weak self] in
            guard let self, self.session?.id == value.id else { return }
            guard Date() < expires else { return }
            if VoiceHandoff.hasRequestedEnd(value) { onEnd(); return }
            if let retry = VoiceHandoff.pendingRetry(in: value) {
                VoiceHandoff.acknowledgeRetry(retry)
                onRetry(retry.recording)
                return
            }
            if let id = VoiceHandoff.pendingStart(in: value), self.lastStart != id {
                self.lastStart = id
                onStart(id)
            }
        }
        guard notify_register_dispatch(value.signal, &registration, .main, { _ in check() }) == NOTIFY_STATUS_OK
        else { throw VoiceRecorderError.recordingUnavailable }
        token = registration
        do { try VoiceHandoff.publishStandby(value) }
        catch { finish(); throw error }
        session = value
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, var tick = self.session, tick.id == value.id else { return }
                // The audio engine owns the absolute deadline and finishes a segment at expiry.
                guard Date() < expires else { return }
                tick.updated = Date()
                do { try VoiceHandoff.publishStandby(tick) }
                catch { onEnd(); return }
                check()
            }
        }
    }

    func finish() {
        heartbeat?.invalidate()
        heartbeat = nil
        if let token { notify_cancel(token) }
        token = nil
        if let session { VoiceHandoff.finishStandby(session) }
        session = nil
        lastStart = nil
    }
}

@MainActor
private final class VoiceLaunch: ObservableObject {
    static let shared = VoiceLaunch()
    @Published var request: UUID?
}

struct StartYahVoice: AppIntent {
    static var title: LocalizedStringResource = "开始语音输入"
    static var description = IntentDescription("打开 Yah 并开始录音，结束后转写为文字。")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        VoiceLaunch.shared.request = UUID()
        return .result()
    }
}

struct YahVoiceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartYahVoice(), phrases: [
            "Start voice input with \(.applicationName)"
        ], shortTitle: "开始语音输入", systemImageName: "mic.fill")
    }
}

private enum DeviceSpeechError: LocalizedError {
    case unavailable, denied, empty
    var errorDescription: String? {
        switch self {
        case .unavailable: return "设备端普通话识别暂不可用。可在语音服务中配置 ElevenLabs。"
        case .denied: return "请在系统设置中允许 Yah 使用语音识别。"
        case .empty: return "没有识别到文字，请再说一次。"
        }
    }
}

@MainActor
private final class DeviceSpeech {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var task: SFSpeechRecognitionTask?
    private var pending: CheckedContinuation<String, Error>?

    func transcribe(_ url: URL) async throws -> String {
        guard let recognizer, recognizer.supportsOnDeviceRecognition else { throw DeviceSpeechError.unavailable }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                task = recognizer.recognitionTask(with: request) { result, error in
                    Task { @MainActor in
                        if let error { self.finish(.failure(error)) }
                        else if let result, result.isFinal {
                            let text = result.bestTranscription.formattedString
                            self.finish(text.isEmpty ? .failure(DeviceSpeechError.empty) : .success(text))
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.task?.cancel()
                self.finish(.failure(CancellationError()))
            }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        let continuation = pending
        pending = nil
        task = nil
        continuation?.resume(with: result)
    }
}
