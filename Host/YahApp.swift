import UserNotifications
import SwiftUI
import UIKit
import Combine
import AVFAudio
import AppIntents
import ActivityKit

@main
struct YahApp: App {
    @UIApplicationDelegateAdaptor(VoiceNotifications.self) private var notifications
    var body: some Scene {
        WindowGroup {
            YahRootView()
                .tint(YahTheme.accent)
        }
    }
}

@MainActor
private struct YahRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("yahKeyboardOnboardingCompleted") private var onboardingCompleted = false
    @ObservedObject private var voiceLaunch = VoiceLaunch.shared
    @State private var keyboardActivated = false
    @State private var showingSettings = false
    @State private var incomingVoiceURL: URL?

    var body: some View {
        Group {
            if showingSettings {
                VoiceSetupView(
                    incomingURL: incomingVoiceURL,
                    onShowOnboarding: {
                        onboardingCompleted = false
                        incomingVoiceURL = nil
                        showingSettings = false
                    },
                    onClose: {
                        incomingVoiceURL = nil
                        showingSettings = false
                    }
                )
            } else if onboardingCompleted {
                InputDashboardView(keyboardActivated: keyboardActivated) {
                    showingSettings = true
                }
            } else {
                YahKeyboardOnboarding(
                    keyboardActivated: keyboardActivated,
                    onEnterSettings: {
                        onboardingCompleted = true
                        showingSettings = true
                    }
                )
            }
        }
        .onAppear(perform: refreshKeyboardActivation)
        .onOpenURL { url in
            if url.scheme == "local-yah-voice", url.host == "settings" {
                showingSettings = true
            } else if url.scheme == "local-yah-voice", ["start", "standby", "resume"].contains(url.host ?? "") {
                onboardingCompleted = true
                incomingVoiceURL = url
                showingSettings = true
            }
        }
        .onChange(of: voiceLaunch.request) { request in
            guard request != nil else { return }
            onboardingCompleted = true
            showingSettings = true
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { refreshKeyboardActivation() }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            refreshKeyboardActivation()
        }
    }

    private func refreshKeyboardActivation() {
        keyboardActivated = UserDefaults(suiteName: "group.local.yah.voice")?
            .bool(forKey: "yahKeyboardWasActivated") ?? false
    }
}

@MainActor
private struct YahKeyboardOnboarding: View {
    let keyboardActivated: Bool
    let onEnterSettings: () -> Void
    @State private var step = 1
    @State private var selectedScheme = UserDefaults(suiteName: "group.local.yah.voice")?
        .string(forKey: "scheme") ?? "rime_ice"
    @FocusState private var inputFocused: Bool

    private let schemes: [(id: String, title: String)] = [
        ("rime_ice", "全拼"),
        ("yah_t9", "九宫格"),
        ("yah_xiaohe", "小鹤双拼"),
        ("yah_ziranma", "自然码双拼")
    ]

    init(keyboardActivated: Bool, onEnterSettings: @escaping () -> Void) {
        self.keyboardActivated = keyboardActivated
        self.onEnterSettings = onEnterSettings
        _step = State(initialValue: keyboardActivated ? 3 : 1)
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    if step == 3 {
                        completion
                    } else if step == 1 {
                        enableKeyboard
                    } else {
                        switchKeyboard
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 22)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: keyboardActivated) { active in
            if active {
                inputFocused = false
                if step == 2 { step = 3 }
            }
        }
    }

    private var enableKeyboard: some View {
        VStack(spacing: 20) {
            Text("第一步 · 启用 Yah 输入法")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 14) {
                Label("打开「设置」→「Yah」→「键盘」", systemImage: "1.circle.fill")
                Label("开启「Yah」与「允许完全访问」", systemImage: "2.circle.fill")
                Text("如果没有看到「键盘」选项，请退出并重新打开系统设置。允许完全访问用于键盘内语音识别及方案同步。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))

            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            } label: {
                Label("去设置中开启  ›", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("我已启用，下一步") { step = 2 }
                .buttonStyle(.bordered)
            Button("稍后进入 Yah 设置", action: onEnterSettings)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var switchKeyboard: some View {
        VStack(spacing: 20) {
            Text("第二步 · 切换到 Yah 输入法")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("点按下方输入框调出键盘，再长按 🌐 地球键并选择 Yah。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                Text("长按 🌐 切换到 Yah 输入法")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(YahTheme.accent)
                TextField("点此调出键盘", text: .constant(""))
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .accessibilityLabel("键盘切换演示输入框")
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .onAppear { inputFocused = true }

            if keyboardActivated {
                Button {
                    step = 3
                    inputFocused = false
                } label: {
                    Label("继续", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            } else {
                ProgressView("等待切换到 Yah 输入法…")
                    .tint(YahTheme.accent)
            }
            Button("返回第一步") { step = 1 }
                .buttonStyle(.bordered)
            Button("稍后进入 Yah 设置", action: onEnterSettings)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var completion: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("已开启 Yah 输入法")
                .font(.title2.bold())
            Text("选择常用输入方案，之后也可在键盘工具栏中随时更改。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(schemes, id: \.id) { scheme in
                    Button {
                        selectedScheme = scheme.id
                        let defaults = UserDefaults(suiteName: "group.local.yah.voice")
                        defaults?.set(scheme.id, forKey: "scheme")
                        let revision = (defaults?.integer(forKey: "schemeSelectionRevision") ?? 0) + 1
                        defaults?.set(revision, forKey: "schemeSelectionRevision")
                    } label: {
                        HStack {
                            Text(scheme.title)
                            Spacer()
                            if selectedScheme == scheme.id {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            Button("进入 Yah 主设置页", action: onEnterSettings)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("重新查看启用步骤") { step = 1 }
                .font(.footnote)
                .foregroundStyle(.secondary)
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
    @AppStorage("voiceStandbyMinutes") private var standbyMinutes = 0
    @State private var configuration = VoiceConfiguration.defaults
    @State private var recorder = VoiceRecorder()
    @StateObject private var standby = StandbyControl()
    @State private var enablingStandby = false
    @State private var enableTask: Task<Void, Never>?
    @AppStorage("deliverRecognizedSpeech") private var deliverRecognizedSpeech = false
    @State private var transcript = ""
    @State private var draft = ""
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
    @State private var handoffOverlay: StandbyHandoffOverlay.State?
    @State private var requestedRecovery: UUID?
    @State private var pendingSpeech: PendingSpeech?
    @State private var startTask: Task<Void, Never>?
    @State private var saveSucceeded = false
    private let onShowOnboarding: () -> Void
    private let onClose: () -> Void
    private let incomingURL: URL?

    init(incomingURL: URL? = nil, onShowOnboarding: @escaping () -> Void = {}, onClose: @escaping () -> Void = {}) {
        self.incomingURL = incomingURL
        self.onShowOnboarding = onShowOnboarding
        self.onClose = onClose
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("语音待机时间", selection: $standbyMinutes) {
                        Text("仅单次（录完即停）").tag(0)
                        Text("3 分钟（免跳转）").tag(3)
                        Text("10 分钟（免跳转）").tag(10)
                    }
                    if let active = standby.session {
                        HStack {
                            Label("连续听写已开启", systemImage: "mic.fill").foregroundStyle(YahTheme.accent)
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
                            Label(enablingStandby ? "正在准备麦克风…" : "开启语音待机", systemImage: "mic")
                        }
                        .disabled(phase != .idle || enablingStandby)
                        Text("先在系统设置 → 通用 → 键盘 → 键盘 → Yah 中开启「允许完全访问」。待机时麦克风橙点会亮起，待命声音会被丢弃。只有在键盘上点开始后才会录下本段；待机结束后橙点熄灭。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if phase == .requestingPermission { ProgressView("正在准备麦克风…") }
                    if phase == .transcribing { ProgressView("正在转写…") }
                    if phase == .idle, let pending = pendingSpeech {
                        Button("重试上次转写") { resumeSpeech(pending) }
                        Button("丢弃上次录音", role: .destructive) {
                            pending.remove()
                            pendingSpeech = nil
                        }
                    }
                    if !message.isEmpty {
                        Text(message)
                            .foregroundStyle(saveSucceeded ? .green : .red)
                    }
                }

                Section("语音服务") {
                    Picker("服务商", selection: $configuration.provider) {
                        ForEach(VoiceConfiguration.Provider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
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
                    Button("查看键盘启用引导", action: onShowOnboarding)
                    NavigationLink("社区输入方案") { CommunitySchemeSettings() }
                    Text("可在系统设置 → 通用 → 键盘 → 键盘中添加 Yah。使用连续听写时，请在该列表点 Yah，打开「允许完全访问」。")
                }

            }
            .navigationTitle("Yah")
            .task {
                // Dismiss standby activities left by earlier versions.
                if #available(iOS 16.2, *) {
                    for activity in Activity<VoiceStandbyAttributes>.activities {
                        await activity.end(nil, dismissalPolicy: .immediate)
                    }
                }
            }
            .onAppear {
                if VoiceHandoff.keyboardTicket() == nil { try? VoiceHandoff.issueKeyboardTicket() }
                VoiceHandoff.clearExpired()
                if phase == .idle { pendingSpeech = PendingSpeech.restore() }
                loadConfiguration()
                consumeStandbyLaunch(isActive: scenePhase == .active)
                consumeVoiceLaunch()
                if let incomingURL { handleVoiceURL(incomingURL) }
            }
            .task(id: pendingSpeech?.name) {
                guard let pending = pendingSpeech else { return }
                let remaining = max(0, min(300, pending.expires.timeIntervalSinceNow))
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                guard !Task.isCancelled, phase == .idle, pendingSpeech?.name == pending.name else { return }
                pending.remove()
                pendingSpeech = nil
            }
            .onChange(of: incomingURL) { url in
                if let url { handleVoiceURL(url) }
            }
            .onChange(of: voiceLaunch.standbyLaunch) { _ in consumeStandbyLaunch() }
            .onChange(of: voiceLaunch.request) { _ in consumeVoiceLaunch() }
            .onChange(of: standbyMinutes) { minutes in
                if minutes == 0 {
                    if phase != .recording && phase != .requestingPermission { endStandby() }
                } else if standby.session != nil {
                    refreshStandbyDeadline()
                }
            }
            .onDisappear { if recorder.keyboardSessionID == nil && standby.session == nil { cancelRecording() } }
            .onChange(of: scenePhase) { value in
                if value == .background {
                    handoffOverlay = nil
                    if enablingStandby { endStandby() }
                    if recorder.keyboardSessionID == nil && standby.session == nil { cancelRecording() }
                }
                if value == .active {
                    VoiceHandoff.clearExpired()
                    consumeStandbyLaunch(isActive: true)
                    consumeVoiceLaunch(isActive: true)
                }
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
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("完成", action: onClose)
            }
        }
        .accessibilityHidden(handoffOverlay != nil)
        .overlay {
            if let handoffOverlay {
                StandbyHandoffOverlay(
                    state: handoffOverlay,
                    standbyMinutes: standbyMinutes,
                    onStayInApp: {
                        self.handoffOverlay = nil
                        VoiceHandoff.clearArmedStart(sessionID: standby.session?.id)
                    },
                    onEndStandby: { endStandby() }
                )
            }
        }
    }

    private func handleVoiceURL(_ url: URL) {
        guard url.scheme == "local-yah-voice" else { return }
        if url.host == "resume" {
            guard url.pathComponents.count == 3, let id = UUID(uuidString: url.pathComponents[1]),
                  VoiceHandoff.acceptKeyboardLink(url) else {
                show("请点「重试上次转写」。", succeeded: false)
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
        if url.host == "standby" {
            let launchID: UUID
            if url.pathComponents.count == 3, let parsed = UUID(uuidString: url.pathComponents[1]) {
                launchID = parsed
            } else {
                launchID = UUID()
            }
            if VoiceHandoff.acceptKeyboardLink(url) {
                _ = VoiceHandoff.takeStandbyLaunch()
                voiceLaunch.standbyLaunch = launchID
                consumeStandbyLaunch()
            } else if url.pathComponents.count == 3,
                      let parsed = UUID(uuidString: url.pathComponents[1]),
                      VoiceHandoff.takeStandbyLaunch() == parsed {
                if VoiceHandoff.keyboardTicket() == nil { try? VoiceHandoff.issueKeyboardTicket() }
                voiceLaunch.standbyLaunch = parsed
                consumeStandbyLaunch()
            } else if phase == .idle {
                if VoiceHandoff.keyboardTicket() == nil { try? VoiceHandoff.issueKeyboardTicket() }
                show("首次使用，请点「开启语音待机」。下次点键盘麦克风将自动开启待机。", succeeded: true)
            }
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

    private func enableStandby(forKeyboardLaunch launchID: UUID? = nil) {
        if let active = standby.session {
            if let launchID, phase == .idle {
                refreshStandbyDeadline()
                guard let current = standby.session, current.id == active.id else { return }
                armStandbyReturn(launchID: launchID, sessionID: current.id, expires: current.expires)
            }
            return
        }
        guard phase == .idle, !enablingStandby else { return }
        enablingStandby = true
        if let launchID { handoffOverlay = .arming(launchID) }
        enableTask = Task {
            defer { enablingStandby = false; enableTask = nil }
            do {
                try await recorder.enableStandby(duration: TimeInterval(max(standbyMinutes, 10) * 60))
                try Task.checkCancellation()
                guard let expires = recorder.standbyDeadline, scenePhase != .background,
                      UIApplication.shared.isProtectedDataAvailable else { throw CancellationError() }
                recorder.standbyDidEnd = {
                    handoffOverlay = nil
                    VoiceHandoff.clearArmedStart()
                    standby.finish()
                }
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
                if let launchID, let active = standby.session {
                    armStandbyReturn(launchID: launchID, sessionID: active.id, expires: active.expires)
                } else {
                    show("连续听写已开启。现在可以回到原输入框。", succeeded: true)
                }
            } catch {
                handoffOverlay = nil
                VoiceHandoff.clearArmedStart()
                recorder.disableStandby()
                standby.finish()
                if !Task.isCancelled { show(error.localizedDescription, succeeded: false) }
            }
        }
    }

    private func armStandbyReturn(launchID: UUID, sessionID: UUID, expires: Date) {
        try? VoiceHandoff.publishArmedStart(launchID: launchID, sessionID: sessionID)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        handoffOverlay = .ready(launchID: launchID, expires: expires)
        show("语音待机已开启。返回原输入框后将自动开始识别。", succeeded: true)
    }

    private func endStandby() {
        enableTask?.cancel()
        handoffOverlay = nil
        VoiceHandoff.clearArmedStart()
        recorder.disableStandby()
        standby.finish()
    }

    private func refreshStandbyDeadline() {
        guard standbyMinutes > 0 else { return }
        if let next = recorder.extendStandby(duration: TimeInterval(standbyMinutes * 60)) {
            do {
                try standby.extend(until: next)
            } catch {
                endStandby()
                show("无法更新语音待机，请重试。", succeeded: false)
            }
        }
    }

    private func finishStandbyAfterRecording() {
        if standbyMinutes > 0 { refreshStandbyDeadline() }
        else { endStandby() }
    }

    private func consumeStandbyLaunch(isActive: Bool? = nil) {
        guard scenePhase != .background else { return }
        let launchID: UUID?
        if let direct = voiceLaunch.standbyLaunch {
            launchID = direct
        } else if isActive ?? (scenePhase == .active) {
            launchID = VoiceHandoff.takeStandbyLaunch()
        } else {
            launchID = nil
        }
        guard let launchID else { return }
        voiceLaunch.standbyLaunch = nil
        enableStandby(forKeyboardLaunch: launchID)
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
        finishSpeech(pending.file)

    }

    private func startRecording(forKeyboard: Bool = false, requestedID: UUID? = nil) {
        func reportFailure(_ text: String) {
            if let requestedID {
                VoiceHandoff.publishFailure(text, for: requestedID)
                VoiceHandoff.clearStart(requestedID)
            }
            if standby.session != nil { endStandby() }
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
            guard let stored = try VoiceConfigurationStore.load(),
                  !stored.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VoiceTranscriptionError.missingAPIKey
            }
            if stored != configuration {
                reportFailure("请先保存修改后的语音配置。")
                return
            }
            draft = ""
            recorder.configurePreview { text, _ in
                if phase == .recording, scenePhase == .active, draft != text { draft = text }
            }
            phase = .requestingPermission
            recorder.didCancelFromKeyboard = {
                cancelRecordingFromKeyboard()
            }
            recorder.didFinish = { result in
                recorder.didFinish = nil
                recorder.didCancelFromKeyboard = nil
                switch result {
                case .success(let url):
                    phase = .transcribing
                    recorder.markTranscribing()
                    draft = ""
                    let job = PendingSpeech(file: url, recording: recorder.keyboardSessionID)
                    job.save()
                    pendingSpeech = job
                    finishSpeech(url)
                case .failure(let error):
                    if let id = recorder.keyboardSessionID { VoiceHandoff.publishFailure(error.localizedDescription, for: id) }
                    recorder.disconnectKeyboard()
                    phase = .idle
                    finishStandbyAfterRecording()
                    reportFailure(error.localizedDescription)
                }
            }
            startTask = Task {
                do {
                    if requestedID != nil, recorder.standbyDeadline == nil { throw CancellationError() }
                    try await recorder.start()
                    try Task.checkCancellation()
                    if forKeyboard { try recorder.connectKeyboard(id: requestedID ?? UUID()) }
                    if requestedID != nil {
                        handoffOverlay = nil
                        refreshStandbyDeadline()
                    }
                    phase = .recording
                    show(forKeyboard ? "正在录音，切回目标输入框后点键盘上的停止。" : "正在录音…", succeeded: true)
                } catch {
                    guard !Task.isCancelled else { return }
                    recorder.didFinish = nil
                    recorder.didCancelFromKeyboard = nil
                    recorder.cancel()
                    recorder.disconnectKeyboard()
                    phase = .idle
                    endStandby()
                    reportFailure(error.localizedDescription)
                }
            }
        } catch {
            reportFailure(error.localizedDescription)
        }
    }

    private func finishSpeech(_ file: URL) {
        let recording = recorder.keyboardSessionID
        var background = UIBackgroundTaskIdentifier.invalid
        if recording != nil {
            background = UIApplication.shared.beginBackgroundTask(withName: "Yah 转写") {
                transcriptionTask?.cancel()
                if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
            }
        }
        finishStandbyAfterRecording()
        transcriptionTask = Task {
            await transcribe(audioURL: file, recording: recording)
            if let recording { VoiceHandoff.clearStart(recording) }
            recorder.didCancelFromKeyboard = nil
            recorder.disconnectKeyboard()
            if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
            phase = .idle
            resumeIfRequested()
        }
    }

    private func cancelRecordingFromKeyboard() {
        guard phase == .requestingPermission || phase == .recording else { return }
        startTask?.cancel()
        recorder.didFinish = nil
        recorder.didCancelFromKeyboard = nil
        if let id = recorder.keyboardSessionID { VoiceHandoff.clearStart(id) }
        recorder.cancel()
        recorder.disconnectKeyboard()
        draft = ""
        phase = .idle
        finishStandbyAfterRecording()
    }

    private func cancelRecording() {
        guard phase == .requestingPermission || phase == .recording else { return }
        startTask?.cancel()
        recorder.didFinish = nil
        recorder.didCancelFromKeyboard = nil
        if let id = recorder.keyboardSessionID {
            VoiceHandoff.publishFailure("本段录音已取消。", for: id)
            VoiceHandoff.clearStart(id)
        }
        recorder.cancel()
        recorder.disconnectKeyboard()
        phase = .idle
        endStandby()
        show("录音已取消。", succeeded: false)
    }

    @MainActor
    private func transcribe(audioURL: URL, recording: UUID?) async {
        var keepForRetry = false
        defer {
            if !keepForRetry {
                if let job = pendingSpeech, job.file.lastPathComponent == audioURL.lastPathComponent {
                    job.remove()
                    pendingSpeech = nil
                } else { try? FileManager.default.removeItem(at: audioURL) }
            }
        }
        do {
            guard let stored = try VoiceConfigurationStore.load() else {
                throw VoiceTranscriptionError.missingAPIKey
            }
            let provider = VoiceTranscriptionProviderFactory.make(for: stored)
            var attempt = 0
            let result: String
            while true {
                do {
                    result = try await provider.transcribe(audioURL: audioURL, configuration: stored)
                    break
                } catch {
                    attempt += 1
                    guard attempt <= 2, VoiceTranscriptionError.isTransient(error), !Task.isCancelled else { throw error }
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
                }
            }
            try Task.checkCancellation()
            transcript = result
            if recording != nil || deliverRecognizedSpeech {
                do {
                    try VoiceHandoff.publish(transcript, recordingID: recording)
                    show("转写完成，已送到键盘。", succeeded: true)
                } catch {
                    show("转写已保留。键盘共享不可用，请复制文本。", succeeded: false)
                }
            } else {
                show("转写完成。", succeeded: true)
            }
        } catch {
            if let pending = pendingSpeech, pending.file == audioURL, pending.expires > Date() {
                keepForRetry = true
                let hint = Task.isCancelled ? "系统已暂停转写。" : "本次服务未完成转写（\(VoiceTranscriptionError.reason(for: error))）。"
                let message = hint + "五分钟内可重试同一段录音。"
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
    private var expires: Date?
    private var heartbeat: Timer?
    private var token: Int32?
    private var lastStart: UUID?

    func begin(until expires: Date, onStart: @escaping (UUID) -> Void,
               onRetry: @escaping (UUID) -> Void, onEnd: @escaping () -> Void) throws {
        self.expires = expires
        let value = VoiceHandoff.Standby(id: UUID(), expires: expires)
        var registration: Int32 = 0
        let check = { [weak self] in
            guard let self, self.session?.id == value.id else { return }
            guard let currentExpiry = self.expires, Date() < currentExpiry else { return }
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
        do { try VoiceHandoff.publishStandby(value, notify: true) }
        catch { finish(); throw error }
        session = value
        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, var tick = self.session, tick.id == value.id else { return }
                // The audio engine owns the absolute deadline and finishes a segment at expiry.
                guard let currentExpiry = self.expires, Date() < currentExpiry else { return }
                tick.expires = currentExpiry
                tick.updated = Date()
                do { try VoiceHandoff.publishStandby(tick) }
                catch { onEnd(); return }
                check()
            }
        }
    }

    func extend(until newExpiry: Date) throws {
        guard var current = session else { return }
        expires = newExpiry
        current.expires = newExpiry
        current.updated = Date()
        session = current
        try VoiceHandoff.publishStandby(current, notify: true)
    }

    func finish() {
        heartbeat?.invalidate()
        heartbeat = nil
        if let token { notify_cancel(token) }
        token = nil
        if let session { VoiceHandoff.finishStandby(session) }
        session = nil
        expires = nil
        lastStart = nil
    }
}

private struct StandbyHandoffOverlay: View {
    let state: State
    let standbyMinutes: Int
    let onStayInApp: () -> Void
    let onEndStandby: () -> Void
    @State private var nudge = false

    enum State: Equatable {
        case arming(UUID)
        case ready(launchID: UUID, expires: Date)
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .opacity(0.97)
                .ignoresSafeArea()
            VStack(spacing: 24) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.left")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(YahTheme.accent)
                        .offset(x: nudge ? -3 : 2, y: nudge ? -3 : 2)
                    Text("点左上角返回原输入框")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.horizontal, 20)
                .accessibilityIdentifier("standby-return-guide")

                Spacer()

                switch state {
                case .arming:
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("正在开启语音待机…")
                            .font(.title3.weight(.semibold))
                    }
                case .ready(_, let expires):
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(YahTheme.accentBackground)
                                .frame(width: 96, height: 96)
                            Image(systemName: "mic.fill")
                                .font(.system(size: 38, weight: .semibold))
                                .foregroundStyle(YahTheme.accent)
                        }
                        Text(standbyMinutes == 0 ? "单次语音已准备" : "\(standbyMinutes) 分钟语音待机已开启")
                            .font(.title2.weight(.bold))
                            .accessibilityIdentifier("standby-ready-title")
                        Text("返回输入区域后将自动开始语音识别并上屏")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        HStack(spacing: 6) {
                            Image(systemName: "timer")
                                .foregroundStyle(YahTheme.accent)
                            Text("待机剩余")
                            Text(timerInterval: min(Date(), expires)...expires, countsDown: true)
                                .monospacedDigit()
                            if standbyMinutes > 0 { Text("· 期间点键盘麦克风免跳转") }
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))

                        Text("也可以在屏幕底部向右滑动快速切回")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 4)
                    }
                }

                Spacer()

                HStack(spacing: 16) {
                    Button("留在 Yah 设置", action: onStayInApp)
                        .buttonStyle(.bordered)
                    Button("结束待机", role: .destructive, action: onEndStandby)
                        .buttonStyle(.bordered)
                }
                .padding(.bottom, 28)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                nudge = true
            }
        }
    }
}

@MainActor
private final class VoiceLaunch: ObservableObject {
    static let shared = VoiceLaunch()
    @Published var request: UUID?
    @Published var standbyLaunch: UUID?
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
