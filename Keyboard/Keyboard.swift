import SwiftUI
import UIKit

private struct KeyboardVoiceLink: View {
    let onRequest: () -> URL?
    let onRejected: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            guard let url = onRequest() else { return }
            openURL(url) { accepted in
                if !accepted { onRejected() }
            }
        } label: {
            Label("语音输入", systemImage: "mic.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color(uiColor: .secondarySystemFill), in: Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("语音输入")
        .accessibilityIdentifier("keyboard-direct-voice")
    }
}

@objc(KeyboardController)
final class KeyboardController: UIInputViewController {
    private var composition = Composition()
    private static let contextPreference = "contextualCandidateRanking"
    private var contextualRanking: ContextualRanking?
    private lazy var correctionSession = YahRimeSession()
    private struct EdgeTouch {
        let prefix: String
        let neighbour: Character
    }
    private var edgeTouches: [EdgeTouch] = []
    private var letterKeys: [LetterButton] = []
    private var correctionScheme: Scheme?
    private var correctionCache: [String: String] = [:]
    private var correctionForm: RimeOutputForm?

    private let phrases = PhraseBook()
    private var appearance = KeyboardAppearance.saved
    private var keyboardHeight: NSLayoutConstraint?
    private var feedback: UIImpactFeedbackGenerator?
    private let suggestions = UIStackView()
    private var cursorAnchor: CGFloat = 0
    private let spelling = UILabel()

    private let stopVoice = UIButton(type: .system)
    private let recordingPreview = KeyboardRecordingPreview()
    private let voicePanel = KeyboardVoicePanel()
    private var revealedPreview: (recording: UUID, document: UUID)?
    private var voiceTimer: Timer?
    private var voiceStateToken: Int32?
    private var waitingForVoice: (recording: UUID, document: UUID)?
    private var startingVoice: (recording: UUID, document: UUID, expires: Date)?
    private var retryingVoice: (recording: UUID, document: UUID?, until: Date)?
    private var stoppingVoice: (recording: UUID, until: Date)?
    private var endingStandby: (id: UUID, document: UUID?, until: Date)?
    private var voiceMessage: (text: String, document: UUID?, until: Date)?
    private var singleSource: (document: UUID, since: Date)?
    private var standbyLaunch: (id: UUID, expires: Date)?
    private var autoStartedVoice: (recording: UUID, startedAt: Date)?
    private var lastDeliveryLookup: (document: UUID, latest: UUID?)?
    private var resultWaitBegan: Date?
    private let voiceStatus = UILabel()
    private let voiceRetry = UIButton(type: .system)
    private let voiceStatusRow = UIStackView()
    private weak var mainToolbar: UIView?
    private let insertVoice = UIButton(type: .system)
    private var voiceLaunchCheck: Task<Void, Never>?
    private lazy var voiceLink = UIHostingController(rootView: KeyboardVoiceLink(
        onRequest: { [weak self] in self?.requestVoiceURL() },
        onRejected: { [weak self] in self?.showLaunchFallback() }
    ))

    private var isKeyboardVisible = false

    deinit {
        if let token = voiceStateToken { notify_cancel(token) }
    }

    private func startStandbyDictation(in standby: VoiceHandoff.Standby, document source: UUID, refreshUI: Bool = true) -> Bool {
        guard endingStandby?.id != standby.id else { return false }
        let now = Date()
        do {
            // The shared command writer returns the same ID while one request is alive.
            let recording: UUID
            if let pending = VoiceHandoff.pendingStart(in: standby) {
                guard VoiceDelivery.origin(for: pending) == source else {
                    reportVoice("已有录音启动请求，请稍候。", in: source)
                    return false
                }
                recording = pending
            } else { recording = try VoiceHandoff.requestStart(in: standby) }
            guard VoiceDelivery.bind(recording, to: source) == source else {
                reportVoice("另一输入框正在请求录音。", in: source)
                return false
            }
            voiceLaunchCheck?.cancel()
            startingVoice = (recording, source, now.addingTimeInterval(VoiceHandoff.startRequestLifetime))
            waitingForVoice = (recording, source)
            resultWaitBegan = nil
            if refreshUI { updateVoiceHandoff() }
            return true
        } catch {
            reportVoice("未能请求录音，请再点麦克风。", in: source)
            return false
        }
    }

    private func reportVoice(_ message: String, in document: UUID?) {
        voiceMessage = (message, document, Date().addingTimeInterval(16))
        if document == nil || document == currentDocumentID {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
        updateVoiceHandoff()
    }

    private func requestVoiceURL() -> URL? {
        guard hasFullAccess else {
            reportVoice("请在系统设置中为 Yah 键盘开启「允许完全访问」。", in: currentDocumentID)
            return nil
        }
        guard let document = currentDocumentID, viewIfLoaded?.window != nil else {
            reportVoice("请先点按输入框，再开始语音输入。", in: nil)
            return nil
        }
        guard textDocumentProxy.isSecureTextEntry != true else {
            reportVoice("密码输入框不支持语音输入。", in: document)
            return nil
        }
        let now = Date()
        guard VoiceHandoff.activeRecording() == nil else { updateVoiceHandoff(); return nil }
        if let startingVoice, startingVoice.expires > now { return nil }
        if let retryingVoice, retryingVoice.until > now { return nil }
        closeCandidates()
        voiceMessage = nil
        let standby = VoiceHandoff.standby()
        if let recording = VoiceHandoff.recovery()?.recording {
            if let standby {
                do {
                    try VoiceHandoff.requestRetry(in: standby, recording: recording)
                    if waitingForVoice?.recording == recording { waitingForVoice = nil; resultWaitBegan = nil }
                    retryingVoice = (recording, document, now.addingTimeInterval(VoiceHandoff.startRequestLifetime))
                    updateVoiceHandoff()
                } catch { reportVoice("未能请求本机重试，请再点一次。", in: document) }
                return nil
            }
            scheduleVoiceLaunchCheck()
            return URL(string: "local-yah-voice://resume/")!
                .appendingPathComponent(recording.uuidString)
                .appendingPathComponent(VoiceHandoff.keyboardTicket()?.uuidString ?? "setup")
        }
        if let standby {
            _ = startStandbyDictation(in: standby, document: document)
            return nil
        }
        let launchID = UUID()
        do {
            try VoiceHandoff.rememberStandbyLaunch(id: launchID)
        } catch {
            reportVoice("无法准备语音待机，请重试。", in: document)
            return nil
        }
        VoiceDelivery.saveArmedOrigin(launchID: launchID, document: document)
        standbyLaunch = (launchID, now.addingTimeInterval(30))
        singleSource = (document, now)
        scheduleVoiceLaunchCheck()
        return URL(string: "local-yah-voice://standby/")!
            .appendingPathComponent(launchID.uuidString)
            .appendingPathComponent(VoiceHandoff.keyboardTicket()?.uuidString ?? "setup")
    }

    private func scheduleVoiceLaunchCheck() {
        voiceLaunchCheck?.cancel()
        voiceLaunchCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.showLaunchFallback()
        }
    }

    private func showLaunchFallback() {
        guard viewIfLoaded?.window != nil, VoiceHandoff.activeRecording() == nil,
              VoiceHandoff.standby() == nil, startingVoice == nil else { return }
        voiceLaunchCheck?.cancel()
        if let launch = standbyLaunch {
            VoiceHandoff.cancelStandbyLaunch(launch.id)
            VoiceDelivery.clearArmedOrigin(launch.id)
            standbyLaunch = nil
            singleSource = nil
        }
        reportVoice("无法打开 Yah，请先打开 Yah 开启语音待机。", in: currentDocumentID)
    }

    private func openVoice() {
        guard let url = requestVoiceURL() else { return }
        guard let context = extensionContext else { showLaunchFallback(); return }
        context.open(url) { [weak self] accepted in
            if !accepted { DispatchQueue.main.async { self?.showLaunchFallback() } }
        }
    }

    private func endStandby() {
        guard hasFullAccess, let standby = VoiceHandoff.standby(), endingStandby?.id != standby.id else { return }
        do {
            try VoiceHandoff.requestStandbyEnd(standby)
            endingStandby = (standby.id, currentDocumentID, Date().addingTimeInterval(VoiceHandoff.startRequestLifetime))
            updateVoiceHandoff()
        } catch { reportVoice("未能结束连续听写，请重试。", in: currentDocumentID) }
    }

    private let settingsButton = UIButton(type: .system)
    private let settingsPanel = KeyboardSettingsPanel()
    private let expandCandidates = UIButton(type: .system)
    private lazy var candidatePanel = CandidatePanel(fetch: { [weak self] start, limit in
        self?.composition.expandedChoices(startingAt: start, limit: limit) ?? []
    }, pick: { [weak self] index in
        guard let self else { return }
        closeCandidates()
        if let text = composition.selectExpanded(at: index) { textDocumentProxy.insertText(text) }
        refresh()
    })

    private let rows = UIStackView()

    private static let background = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.13, alpha: 1) : .systemGray5 }
    private static let keyColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.29, alpha: 1) : .white }
    private static let controlColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.29, alpha: 1) : .systemGray3 }
    private static let accentKey = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.96, alpha: 1) : .label }
    private static let accentInk = UIColor { $0.userInterfaceStyle == .dark ? .black : .white }

    private func closeCandidates() {
        guard !candidatePanel.isHidden else { return }
        candidatePanel.dismiss()
        rows.isHidden = !voicePanel.isHidden || !settingsPanel.isHidden
        updateCandidateToggle()
    }

    private func closeSettings() {
        guard !settingsPanel.isHidden else { return }
        settingsPanel.isHidden = true
        settingsPanel.resetToRoot()
        rows.isHidden = !voicePanel.isHidden || !candidatePanel.isHidden
        updateSettingsToggle()
    }

    private func updateSettingsToggle() {
        settingsButton.isHidden = !composition.spelling.isEmpty
        let open = !settingsPanel.isHidden
        settingsButton.accessibilityLabel = open ? "收起设置" : "键盘设置"
        let symbol = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        settingsButton.setImage(UIImage(systemName: open ? "chevron.down" : "square.grid.2x2", withConfiguration: symbol), for: .normal)
        settingsButton.tintColor = open ? .systemBlue : .label
    }

    private func updateCandidateToggle() {
        expandCandidates.isHidden = composition.spelling.isEmpty
        let closed = candidatePanel.isHidden
        expandCandidates.accessibilityLabel = closed ? "展开候选" : "收起候选"
        let symbol = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        expandCandidates.setImage(UIImage(systemName: closed ? "chevron.down" : "chevron.up", withConfiguration: symbol), for: .normal)
        expandCandidates.tintColor = .secondaryLabel
    }

    private enum Scheme: String, CaseIterable {
        case full = "rime_ice", nine = "yah_t9", xiaohe = "yah_xiaohe", ziranma = "yah_ziranma"
        var title: String {
            switch self {
            case .full: return "全拼"
            case .nine: return "九宫格"
            case .xiaohe: return "小鹤双拼"
            case .ziranma: return "自然码双拼"
            }
        }
    }
    private var communityLibrary: CommunitySchemes?
    private var communityID: String?
    private var scheme = Scheme.full
    private var schemeTitle: String {
        communityLibrary?.schemes.first(where: { $0.id == communityID })?.name ?? scheme.title
    }
    private var outputForm = RimeOutputForm.preferred()
    private var effectiveOutputForm: RimeOutputForm {
        communityID == nil || outputForm == .simplified ? outputForm : .traditional
    }
    private var nineKeys: Bool { communityID == nil && scheme == .nine && !english && !symbols }
    private let groups = ["ABC", "DEF", "GHI", "JKL", "MNO", "PQRS", "TUV", "WXYZ"]
    private var english = false
    private var symbols = false
    private var shifted = false
    private var field: UIKeyboardType?
    private var document: UUID?
    private var enterKey: UIButton?

    override func viewDidLoad() {
        super.viewDidLoad()
        VoiceDelivery.prune()
        if UserDefaults.standard.bool(forKey: Self.contextPreference) { enableContextualRanking() }
        let sharedScheme = UserDefaults(suiteName: "group.local.yah.voice")?.string(forKey: "scheme")
        if let saved = sharedScheme ?? UserDefaults.standard.string(forKey: "scheme"),
           let choice = Scheme(rawValue: saved),
           composition.useSchema(saved) { scheme = choice }
        composition.setOutputForm(outputForm)
        view.backgroundColor = Self.background
        let stack = UIStackView()
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        let preferredHeight = view.heightAnchor.constraint(equalToConstant: preferredKeyboardHeight)
        keyboardHeight = preferredHeight
        candidatePanel.wordFont = keyFont(.candidate)
        preferredHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([preferredHeight,
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: guide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -2)])

        spelling.font = .preferredFont(forTextStyle: .caption1)
        spelling.adjustsFontForContentSizeCategory = true
        spelling.textColor = .secondaryLabel
        spelling.lineBreakMode = .byTruncatingHead
        let header = UIStackView(arrangedSubviews: [spelling])
        header.axis = .vertical
        header.isLayoutMarginsRelativeArrangement = true
        header.layoutMargins = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 2)
        header.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let scroll = UIScrollView()
        // The toolbar is a single opaque keyboard row. System scroll-edge glass can obscure
        // the candidate glyphs on iOS 26 even when the content fits on one line.
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = Self.background
        scroll.clipsToBounds = true
        scroll.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if #available(iOS 26.0, *) {
            scroll.topEdgeEffect.isHidden = true
            scroll.bottomEdgeEffect.isHidden = true
            scroll.leftEdgeEffect.isHidden = true
            scroll.rightEdgeEffect.isHidden = true
        }
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceHorizontal = false
        header.addArrangedSubview(scroll)
        scroll.addSubview(suggestions)
        suggestions.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            suggestions.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            suggestions.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            suggestions.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            suggestions.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            suggestions.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)])
        addChild(voiceLink)
        voiceLink.view.backgroundColor = .clear
        voiceLink.view.setContentHuggingPriority(.required, for: .horizontal)
        voiceLink.view.setContentCompressionResistancePriority(.required, for: .horizontal)
        voiceLink.sizingOptions = .intrinsicContentSize
        insertVoice.setTitle("插入转写", for: .normal)
        insertVoice.accessibilityLabel = "插入转写"
        insertVoice.setContentHuggingPriority(.required, for: .horizontal)
        insertVoice.setContentCompressionResistancePriority(.required, for: .horizontal)
        insertVoice.addAction(UIAction { [weak self] _ in
            if let item = VoiceHandoff.pending() { self?.insertPendingVoice(item) }
        }, for: .touchUpInside)
        stopVoice.tintColor = .systemRed
        stopVoice.setImage(UIImage(systemName: "stop.fill"), for: .normal)
        stopVoice.titleLabel?.font = .preferredFont(forTextStyle: .callout)
        stopVoice.titleLabel?.adjustsFontForContentSizeCategory = true
        stopVoice.titleLabel?.adjustsFontSizeToFitWidth = true
        stopVoice.isHidden = true
        stopVoice.setContentHuggingPriority(.required, for: .horizontal)
        stopVoice.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stopWidth = stopVoice.widthAnchor.constraint(greaterThanOrEqualToConstant: 64)
        stopWidth.priority = UILayoutPriority(999)
        stopWidth.isActive = true
        recordingPreview.isHidden = true
        recordingPreview.addAction(UIAction { [weak self] _ in
            guard let self, let session = VoiceHandoff.activeRecording(), !session.transcribing,
                  VoiceDelivery.origin(for: session.id) == nil, let document = currentDocumentID else { return }
            revealedPreview = (session.id, document)
            updateVoiceHandoff()
        }, for: .touchUpInside)
        stopVoice.addAction(UIAction { [weak self] _ in self?.stopActiveVoice() }, for: .touchUpInside)
        settingsButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        settingsButton.setContentHuggingPriority(.required, for: .horizontal)
        settingsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        settingsButton.accessibilityIdentifier = "keyboard-settings-toggle"
        settingsButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if settingsPanel.isHidden {
                closeCandidates()
                rows.isHidden = true
                settingsPanel.isHidden = false
                settingsPanel.resetToRoot()
                refreshSettingsPanel()
                updateSettingsToggle()
            } else {
                closeSettings()
            }
        }, for: .touchUpInside)
        expandCandidates.widthAnchor.constraint(equalToConstant: 34).isActive = true
        expandCandidates.setContentHuggingPriority(.required, for: .horizontal)
        expandCandidates.setContentCompressionResistancePriority(.required, for: .horizontal)
        expandCandidates.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if candidatePanel.isHidden {
                closeSettings()
                rows.isHidden = true
                candidatePanel.show()
                updateCandidateToggle()
            } else { closeCandidates() }
        }, for: .touchUpInside)
        let toolbar = UIStackView(arrangedSubviews: [settingsButton, header, expandCandidates, recordingPreview, stopVoice, insertVoice, voiceLink.view])
        toolbar.spacing = 4
        toolbar.isLayoutMarginsRelativeArrangement = true
        toolbar.layoutMargins = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        voiceLink.didMove(toParent: self)
        mainToolbar = toolbar
        let previewWidth = recordingPreview.widthAnchor.constraint(equalTo: toolbar.widthAnchor, multiplier: 0.40)
        previewWidth.priority = .defaultHigh
        previewWidth.isActive = true
        toolbar.heightAnchor.constraint(equalToConstant: 46).isActive = true
        stack.addArrangedSubview(toolbar)
        voiceStatus.font = .preferredFont(forTextStyle: .caption1)
        voiceStatus.textAlignment = .center
        voiceStatus.textColor = .label
        voiceStatus.numberOfLines = 2
        voiceStatus.isHidden = true
        voiceStatus.accessibilityIdentifier = "voice-request-status"
        var retryConfig = UIButton.Configuration.tinted()
        retryConfig.title = "重试"
        retryConfig.cornerStyle = .capsule
        retryConfig.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14)
        voiceRetry.configuration = retryConfig
        voiceRetry.accessibilityLabel = "重试同一段录音"
        voiceRetry.accessibilityIdentifier = "voice-retry"
        voiceRetry.isHidden = true
        voiceRetry.setContentHuggingPriority(.required, for: .horizontal)
        voiceRetry.setContentCompressionResistancePriority(.required, for: .horizontal)
        voiceRetry.addAction(UIAction { [weak self] _ in self?.openVoice() }, for: .touchUpInside)
        voiceStatusRow.axis = .horizontal
        voiceStatusRow.spacing = 8
        voiceStatusRow.alignment = .center
        voiceStatusRow.isHidden = true
        voiceStatusRow.addArrangedSubview(voiceStatus)
        voiceStatusRow.addArrangedSubview(voiceRetry)
        stack.addArrangedSubview(voiceStatusRow)

        voicePanel.isHidden = true
        voicePanel.onCancel = { [weak self] in self?.cancelActiveVoice() }
        voicePanel.onStop = { [weak self] in self?.stopActiveVoice() }
        voicePanel.onEndStandby = { [weak self] in self?.endStandby() }
        voicePanel.onPanelTap = { [weak self] in self?.stopActiveVoice() }
        voicePanel.onPrimaryAction = { [weak self] in self?.stopActiveVoice() }
        stack.addArrangedSubview(voicePanel)

        settingsPanel.isHidden = true
        settingsPanel.onClose = { [weak self] in self?.closeSettings() }
        stack.addArrangedSubview(settingsPanel)

        rows.axis = .vertical
        rows.distribution = .fillEqually
        stack.addArrangedSubview(rows)
        stack.addArrangedSubview(candidatePanel)
        updateField()
    }

    override func paste(itemProviders: [NSItemProvider]) {
        guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
        guard let destination = currentDocumentID else { return }
        _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
            guard let text = object as? String, !text.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self, self.viewIfLoaded?.window != nil,
                      self.currentDocumentID == destination else { return }
                self.finishComposition()
                self.textDocumentProxy.insertText(text)
                self.refresh()
            }
        }
    }

    private func stopActiveVoice() {
        guard let session = VoiceHandoff.activeRecording(), !session.transcribing else {
            updateVoiceHandoff()
            return
        }
        if stoppingVoice?.recording == session.id, let until = stoppingVoice?.until, until > Date() { return }
        if notify_post(session.stopSignal) == NOTIFY_STATUS_OK {
            stoppingVoice = (session.id, Date().addingTimeInterval(2))
            if let document = currentDocumentID {
                let origin = VoiceDelivery.rebind(session.id, to: document) ?? document
                waitingForVoice = (session.id, origin)
                resultWaitBegan = nil
            } else if let origin = VoiceDelivery.origin(for: session.id) {
                waitingForVoice = (session.id, origin)
                resultWaitBegan = nil
            }
        } else { reportVoice("未能请求停止录音，请重试。", in: currentDocumentID) }
        updateVoiceHandoff()
    }

    private func cancelActiveVoice() {
        if let session = VoiceHandoff.activeRecording(), !session.transcribing {
            VoiceDelivery.markCancelled(session.id)
            _ = notify_post(session.cancelSignal)
        } else if let starting = startingVoice {
            VoiceDelivery.markCancelled(starting.recording)
            VoiceHandoff.clearStart(starting.recording)
        }
        startingVoice = nil
        waitingForVoice = nil
        resultWaitBegan = nil
        stoppingVoice = nil
        updateVoiceHandoff()
    }

    private func maybeAutoStartArmedVoice(in standby: VoiceHandoff.Standby) {
        guard hasFullAccess, isKeyboardVisible, viewIfLoaded?.window != nil,
              let document = currentDocumentID,
              let armed = VoiceHandoff.pendingArmedStart(for: standby) else { return }
        if let local = VoiceDelivery.armedOrigin(for: armed.launchID) {
            let matchesDocument = local.document == document || local.document == nil
            let recentReturn = Date().timeIntervalSince(armed.readyAt) < 30
            guard matchesDocument || recentReturn else { return }
        } else {
            guard Date().timeIntervalSince(armed.readyAt) < 30 else { return }
        }
        guard VoiceHandoff.consumeArmedStart(armed.launchID, in: standby) != nil else { return }
        VoiceDelivery.clearArmedOrigin(armed.launchID)
        if standbyLaunch?.id == armed.launchID { standbyLaunch = nil }
        singleSource = nil
        if startStandbyDictation(in: standby, document: document, refreshUI: false),
           let starting = startingVoice {
            autoStartedVoice = (starting.recording, Date())
        }
    }

    private func updateVoiceHandoff() {
        let now = Date()
        let document = currentDocumentID
        if let launch = standbyLaunch, launch.expires <= now {
            VoiceDelivery.clearArmedOrigin(launch.id)
            standbyLaunch = nil
        }
        let session = VoiceHandoff.activeRecording()
        let pending = VoiceHandoff.pending()
        let standby = hasFullAccess ? VoiceHandoff.standby() : nil

        let cancelledSession = session.map { VoiceDelivery.wasCancelled($0.id) } ?? false
        if let session, cancelledSession, !session.transcribing {
            _ = notify_post(session.cancelSignal)
        }
        let visibleSession = cancelledSession ? nil : session

        if let auto = autoStartedVoice {
            let stillActive = visibleSession?.id == auto.recording
                || startingVoice?.recording == auto.recording
                || waitingForVoice?.recording == auto.recording
            if !stillActive || now.timeIntervalSince(auto.startedAt) > 10 {
                autoStartedVoice = nil
            } else if let document {
                let needsRebind = (startingVoice?.recording == auto.recording && startingVoice?.document != document)
                    || (visibleSession?.id == auto.recording && VoiceDelivery.origin(for: auto.recording) != document)
                    || (waitingForVoice?.recording == auto.recording && waitingForVoice?.document != document)
                if needsRebind {
                    _ = VoiceDelivery.rebind(auto.recording, to: document)
                    if let starting = startingVoice, starting.recording == auto.recording {
                        startingVoice = (auto.recording, document, starting.expires)
                    }
                    if let waiting = waitingForVoice, waiting.recording == auto.recording {
                        waitingForVoice = (auto.recording, document)
                    }
                }
            }
        }

        if let retry = retryingVoice {
            if (visibleSession?.id == retry.recording && visibleSession?.transcribing == true) || pending?.recordingID == retry.recording {
                retryingVoice = nil
            } else if retry.until <= now {
                retryingVoice = nil
                voiceMessage = (VoiceHandoff.failure(for: retry.recording) ?? "Yah 未确认本机重试，请再点一次。",
                                retry.document, now.addingTimeInterval(16))
            }
        }
        if visibleSession == nil, retryingVoice == nil, startingVoice == nil, waitingForVoice == nil,
           let standby, let request = VoiceHandoff.pendingStart(in: standby), let document,
           !VoiceDelivery.wasCancelled(request),
           VoiceDelivery.origin(for: request) == document, VoiceHandoff.failure(for: request) == nil,
           pending?.recordingID != request {
            startingVoice = (request, document, now.addingTimeInterval(VoiceHandoff.startRequestLifetime))
            waitingForVoice = (request, document)
        }
        if let session = visibleSession {
            standbyLaunch = nil
            if let source = singleSource {
                if now.timeIntervalSince(source.since) < 120, session.started >= source.since.addingTimeInterval(-1) {
                    _ = VoiceDelivery.bind(session.id, to: source.document)
                }
                singleSource = nil
            }
            if startingVoice?.recording == session.id { startingVoice = nil }
            if let origin = VoiceDelivery.origin(for: session.id) { waitingForVoice = (session.id, origin) }
            resultWaitBegan = nil
            voiceLaunchCheck?.cancel()
        } else if let starting = startingVoice {
            if pending?.recordingID == starting.recording { startingVoice = nil }
            else if let failure = VoiceHandoff.failure(for: starting.recording) {
                startingVoice = nil
                waitingForVoice = nil
                voiceMessage = (failure, starting.document, now.addingTimeInterval(16))
            } else if starting.expires <= now || standby.flatMap({ VoiceHandoff.pendingStart(in: $0) }) != starting.recording {
                startingVoice = nil
                waitingForVoice = nil
                voiceMessage = ("Yah 未确认启动，请再点麦克风重试。", starting.document, now.addingTimeInterval(16))
            }
        } else if let waiting = waitingForVoice, pending?.recordingID != waiting.recording {
            if let failure = VoiceHandoff.failure(for: waiting.recording) {
                voiceMessage = (failure, waiting.document, now.addingTimeInterval(16))
                waitingForVoice = nil
                resultWaitBegan = nil
            } else {
                if resultWaitBegan == nil { resultWaitBegan = now }
                if let began = resultWaitBegan, now.timeIntervalSince(began) > 45 {
                    voiceMessage = ("转写尚未送达，可打开 Yah 查看。", waiting.document, now.addingTimeInterval(16))
                    waitingForVoice = nil
                    resultWaitBegan = nil
                }
            }
        }
        if let ending = endingStandby {
            if standby?.id != ending.id {
                endingStandby = nil
                voiceMessage = ("连续听写已结束。", ending.document, now.addingTimeInterval(3))
            } else if ending.until <= now {
                endingStandby = nil
                voiceMessage = ("Yah 未确认结束，请在方案菜单重试。", ending.document, now.addingTimeInterval(16))
            }
        }
        if let stopping = stoppingVoice, stopping.recording != visibleSession?.id || stopping.until <= now {
            stoppingVoice = nil
        }
        if let message = voiceMessage, message.until <= now { voiceMessage = nil }

        let initialRecovery = visibleSession == nil ? VoiceHandoff.recovery()?.recording : nil
        if visibleSession == nil, session == nil, startingVoice == nil, retryingVoice == nil,
           endingStandby == nil, initialRecovery == nil, let standby {
            maybeAutoStartArmedVoice(in: standby)
        }

        var status: String?
        if let ending = endingStandby, ending.document == document { status = "正在请求结束连续听写…" }
        else if let retry = retryingVoice, retry.document == document { status = "正在请求本机重试…" }
        else if let starting = startingVoice, starting.document == document { status = "正在请求 Yah 开始录音…" }
        else if let message = voiceMessage, message.document == nil || message.document == document { status = message.text }
        else if visibleSession == nil, resultWaitBegan != nil, waitingForVoice?.document == document { status = "正在等待转写结果…" }

        let ownsStarting = startingVoice?.document == document
        let ownsSession = visibleSession.map { VoiceDelivery.origin(for: $0.id) == document } ?? false
        let ownsWaiting = visibleSession == nil && resultWaitBegan != nil && waitingForVoice?.document == document
        let showVoicePanel = document != nil && (ownsStarting || ownsSession || ownsWaiting)

        voiceStatus.text = status
        voiceStatus.isHidden = status == nil || showVoicePanel
        voiceStatusRow.isHidden = voiceStatus.isHidden
        voiceRetry.isHidden = voiceStatusRow.isHidden || retryingVoice != nil || startingVoice != nil
            || visibleSession != nil || VoiceHandoff.recovery() == nil

        if revealedPreview?.recording != visibleSession?.id || revealedPreview?.document != document { revealedPreview = nil }

        if showVoicePanel {
            closeCandidates()
            closeSettings()
            mainToolbar?.isHidden = true
            rows.isHidden = true
            voicePanel.isHidden = false
            stopVoice.isHidden = true
            recordingPreview.clear()
            if let s = visibleSession {
                let stopping = stoppingVoice?.recording == s.id
                let capturing = !s.transcribing && !stopping
                let snapshot = capturing ? s.currentPreview : nil
                voicePanel.renderDirect(
                    title: capturing ? "再次轻触结束" : "正在识别…",
                    message: capturing ? (snapshot?.text ?? "") : "",
                    levels: snapshot?.levels ?? [],
                    mode: capturing ? .listening : .finishing,
                    actionTitle: capturing ? "完成" : nil
                )
            } else if startingVoice != nil {
                voicePanel.renderDirect(
                    title: "正在准备麦克风…",
                    message: "",
                    levels: [],
                    mode: .starting,
                    actionTitle: nil
                )
            } else {
                voicePanel.renderDirect(
                    title: "正在识别并上屏…",
                    message: "",
                    levels: [],
                    mode: .finishing,
                    actionTitle: nil
                )
            }
        } else {
            voicePanel.isHidden = true
            mainToolbar?.isHidden = false
            rows.isHidden = !candidatePanel.isHidden || !settingsPanel.isHidden
            stopVoice.isHidden = visibleSession == nil
            if let s = visibleSession {
                let stopping = stoppingVoice?.recording == s.id
                let capturing = !s.transcribing && !stopping
                stopVoice.setTitle(s.transcribing ? " 转写中" : stopping ? " 停止中" : " 停止", for: .normal)
                stopVoice.isEnabled = capturing
                stopVoice.accessibilityLabel = s.transcribing ? "正在转写" : stopping ? "正在停止" : "停止录音并输入"
                if capturing {
                    let snapshot = s.currentPreview
                    let origin = waitingForVoice?.recording == s.id ? waitingForVoice?.document : nil
                    let visible = document != nil && (origin == document || (origin == nil && revealedPreview?.recording == s.id))
                    let canReveal = origin == nil && document != nil && !visible && snapshot?.text.isEmpty == false
                    recordingPreview.show(text: visible ? snapshot?.text : nil, levels: snapshot?.levels ?? [],
                                          seconds: max(0, Int(now.timeIntervalSince(s.started))), canReveal: canReveal)
                } else { recordingPreview.clear() }
            } else { recordingPreview.clear() }
        }

        // A newer result from another field can replace the shared latest pointer.
        // Scan the extension's opaque origin IDs only on a field or result change.
        if let document, viewIfLoaded?.window != nil,
           lastDeliveryLookup?.document != document || lastDeliveryLookup?.latest != pending?.id {
            lastDeliveryLookup = (document, pending?.id)
            for recording in VoiceDelivery.recordings(in: document) where recording != visibleSession?.id {
                guard let saved = VoiceHandoff.pending(for: recording), !VoiceDelivery.wasInserted(saved.id) else { continue }
                insertPendingVoice(saved)
            }
        }
        guard let item = pending, visibleSession?.id != item.recordingID || visibleSession == nil,
              !VoiceDelivery.wasInserted(item.id) else { insertVoice.isHidden = true; return }
        let origin = item.recordingID.flatMap(VoiceDelivery.origin)
        if let origin, origin == document, viewIfLoaded?.window != nil {
            insertPendingVoice(item)
            return
        }
        insertVoice.isHidden = origin != nil || document == nil
    }

    private func insertPendingVoice(_ item: VoiceHandoff, explicitlyHere: Bool = false) {
        guard viewIfLoaded?.window != nil, let document = currentDocumentID, item.expires > Date() else { return }
        if !explicitlyHere, let recording = item.recordingID, VoiceDelivery.bind(recording, to: document) != document { return }
        guard VoiceDelivery.claim(item.id) else { insertVoice.isHidden = true; return }
        if waitingForVoice?.recording == item.recordingID { waitingForVoice = nil; resultWaitBegan = nil }
        finishComposition()
        textDocumentProxy.insertText(item.text)
        insertVoice.isHidden = true
        playKeyFeedback()
        refresh()
        updateVoiceHandoff()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        lastDeliveryLookup = nil
        if let token = voiceStateToken { notify_cancel(token); voiceStateToken = nil }
        var stateToken: Int32 = 0
        if notify_register_dispatch(VoiceHandoff.stateNotification, &stateToken, .main, { [weak self] _ in
            self?.updateVoiceHandoff()
        }) == NOTIFY_STATUS_OK {
            voiceStateToken = stateToken
        }
        voiceTimer?.invalidate()
        voiceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateVoiceHandoff() }
        }
        let sharedDefaults = UserDefaults(suiteName: "group.local.yah.voice")
        let sharedRevision = sharedDefaults?.integer(forKey: "schemeSelectionRevision") ?? 0
        if let shared = sharedDefaults?.string(forKey: "scheme"),
           sharedRevision != UserDefaults.standard.integer(forKey: "keyboardSharedSchemeRevision"),
           let sharedChoice = Scheme(rawValue: shared),
           YahRimeSession.configure(), composition.useSchema(shared) {
            scheme = sharedChoice
            communityID = nil
            UserDefaults.standard.removeObject(forKey: "communitySchema")
            UserDefaults.standard.set(sharedRevision, forKey: "keyboardSharedSchemeRevision")
            composition.setOutputForm(outputForm)
        }
        restoreCommunityScheme()
        let previousSpelling = composition.spelling
        if YahRimeSession.refreshPersonalLexicon() {
            correctionCache.removeAll()
            edgeTouches.removeAll()
            composition.clear()
            // Reloading stabledb recreates the Rime sessions. Restore pending keystrokes
            // when the keyboard is returning to the same input field.
            if let document, document == currentDocumentID {
                for letter in previousSpelling { composition.append(letter) }
            }
        }
        updateVoiceHandoff()
        updateField()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isKeyboardVisible = true
        UserDefaults(suiteName: "group.local.yah.voice")?.set(true, forKey: "yahKeyboardWasActivated")
        updateVoiceHandoff()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isKeyboardVisible = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isKeyboardVisible = false
        recordingPreview.clear()
        revealedPreview = nil
        contextualRanking?.clear()
        composition.updateContextualOrder(nil)
        closeCandidates()
        closeSettings()
        voiceLaunchCheck?.cancel()
        voiceLaunchCheck = nil
        voiceTimer?.invalidate()
        voiceTimer = nil
        if let token = voiceStateToken { notify_cancel(token); voiceStateToken = nil }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        updateField()
    }

    // UIKit can return nil while attaching a host, although the SDK imports this getter as UUID.
    private var currentDocumentID: UUID? {
        let getter = #selector(getter: UITextDocumentProxy.documentIdentifier)
        return (textDocumentProxy as AnyObject).perform(getter)?.takeUnretainedValue() as? UUID
    }

    private func updateField() {
        let kind = textDocumentProxy.keyboardType ?? .default
        let id = currentDocumentID
        if field != kind || document != id {
            updateVoiceHandoff()
            composition.clear()
            field = kind
            document = id
            english = [.emailAddress, .URL, .asciiCapable].contains(kind)
            symbols = [.numberPad, .decimalPad, .numbersAndPunctuation, .phonePad].contains(kind)
            shifted = false
            rebuild()
        }
        refresh()
    }

    private func restoreCommunityScheme() {
        let latest = CommunitySchemes.installed()
        let saved = UserDefaults.standard.string(forKey: "communitySchema")
        if latest?.revision == communityLibrary?.revision && saved == communityID { return }
        communityLibrary = latest
        if let saved, latest?.schemes.contains(where: { $0.id == saved }) == true,
           activateCommunity(saved) { rebuild(); return }
        if communityID != nil || saved != nil {
            _ = YahRimeSession.configure()
            _ = composition.useSchema(scheme.rawValue)
            communityID = nil
            composition.setOutputForm(outputForm)
            UserDefaults.standard.removeObject(forKey: "communitySchema")
            rebuild()
        }
    }

    private func activateCommunity(_ id: String) -> Bool {
        guard let library = communityLibrary, let data = try? library.directory(),
              YahRimeSession.configure(community: data), composition.useSchema(id) else { return false }
        correctionCache.removeAll()
        edgeTouches.removeAll()
        communityID = id
        english = false
        symbols = false
        shifted = false
        composition.setOutputForm(outputForm)
        UserDefaults.standard.set(id, forKey: "communitySchema")
        return true
    }

    private enum KeyLayout { case compact, tablet, wide }

    private var renderedKeyLayout: KeyLayout?
    private var keyLayout: KeyLayout {
        let width = view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right
        let pad = traitCollection.userInterfaceIdiom == .pad
        if width >= 900 || (!pad && traitCollection.verticalSizeClass == .compact && width >= 700) {
            return .wide
        }
        return pad && width >= 600 ? .tablet : .compact
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if renderedKeyLayout != keyLayout {
            rebuild()
            refresh()
        }
    }

    private func navigationKeys() -> UIStackView {
        let keys = UIStackView()
        keys.distribution = .fillEqually
        for (title, description, offset) in [("←", "光标左移", -1), ("Tab", "制表符", 0), ("→", "光标右移", 1)] {
            let cap = button(title, style: .control) { keyboard in
                keyboard.finishComposition()
                if offset == 0 { keyboard.textDocumentProxy.insertText("\t") }
                else { keyboard.textDocumentProxy.adjustTextPosition(byCharacterOffset: offset) }
            }
            cap.accessibilityLabel = description
            keys.addArrangedSubview(cap)
        }
        return keys
    }

    private func wideNineRow(_ index: Int, letters: UIStackView) -> UIStackView {
        let digits = ["123", "456", "789", ".0="][index]
        let symbols = ["+-", "×÷", "，。", "（）"][index]
        let numbers = UIStackView()
        let operators = UIStackView()
        for (group, text) in [(numbers, digits), (operators, symbols)] {
            group.distribution = .fillEqually
            for value in text {
                let cap = button(String(value), style: group === numbers ? .letter : .control) { keyboard in
                    keyboard.finishComposition()
                    keyboard.textDocumentProxy.insertText(String(value))
                }
                cap.accessibilityLabel = (value.isNumber ? "数字 " : "符号 ") + String(value)
                group.addArrangedSubview(cap)
            }
        }
        let row = UIStackView(arrangedSubviews: [numbers, operators, letters])
        row.spacing = 8
        numbers.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.30).isActive = true
        operators.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: 0.20).isActive = true
        return row
    }

    private func rebuild() {
        let layout = keyLayout
        renderedKeyLayout = layout
        let wideNine = nineKeys && layout == .wide
        letterKeys.removeAll(keepingCapacity: true)
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var lines = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        if symbols {
            lines = ["1234567890", english || isEnteringCode ? "@#$%&*-+/" : "，。？！、：；「」", english || isEnteringCode ? ".,?!:;'()" : "@#%&*-+/="]
        } else if traitCollection.userInterfaceIdiom == .pad && layout == .wide {
            lines.insert("1234567890", at: 0)
        }
        if let communityID, !symbols, !english,
           let alphabet = communityLibrary?.schemes.first(where: { $0.id == communityID })?.alphabet {
            var visible = Set(lines.joined())
            // Expose additional codes, including uppercase letters and punctuation, in schema order.
            let extra = alphabet.filter { $0.isASCII && !$0.isWhitespace && visible.insert($0).inserted }
            var start = extra.startIndex
            var extraRows: [String] = []
            while start < extra.endIndex {
                let end = extra.index(start, offsetBy: 10, limitedBy: extra.endIndex) ?? extra.endIndex
                extraRows.append(String(extra[start..<end]))
                start = end
            }
            lines.insert(contentsOf: extraRows, at: 0)
        }
        if nineKeys { lines = ["123", "456", "789"] }
        for (index, line) in lines.enumerated() {
            let row = UIStackView()
            let keysRow = UIStackView()
            keysRow.distribution = .fillEqually
            keysRow.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
            let last = index == lines.count - 1
            var leading: UIView?
            var trailing: UIView?
            if last && !symbols && !nineKeys {
                let shift = button("⇧", style: .control) {
                    $0.shifted.toggle()
                    $0.rebuild()
                }
                shift.configuration?.title = nil
                shift.configuration?.image = UIImage(systemName: shifted ? "shift.fill" : "shift")
                shift.accessibilityLabel = "Shift"
                shift.accessibilityTraits = shifted ? [.button, .selected] : .button
                leading = shift
            } else if line == "asdfghjkl" && !symbols && !nineKeys && layout == .compact {
                leading = UIView()
            }
            for key in line {
                if nineKeys, let digit = key.wholeNumberValue {
                    if digit == 1 {
                        keysRow.addArrangedSubview(button("分词", style: .control) {
                            if !$0.composition.spelling.isEmpty { $0.composition.append("'") }
                        })
                    } else {
                        let code = Character(UnicodeScalar(65 + digit - 2)!)
                        keysRow.addArrangedSubview(letterButton(title: groups[digit - 2], code: code))
                    }
                    continue
                }
                if communityID == nil && !english && !shifted && !symbols && key.isLetter {
                    let cap = letterButton(title: String(key), code: key)
                    addFlickSymbol(to: cap, letter: key)
                    keysRow.addArrangedSubview(cap)
                    continue
                }
                let value = shifted ? String(key).uppercased() : String(key)
                let cap = button(value, style: .letter) { keyboard in
                    let typed = Character(value)
                    if keyboard.acceptsCodeCharacter(typed) ||
                        (!keyboard.english && !keyboard.symbols && (keyboard.communityID != nil || keyboard.shifted)) {
                        if let commit = keyboard.composition.appendCommunity(typed) { keyboard.textDocumentProxy.insertText(commit) }
                    } else if !keyboard.english && !keyboard.symbols && key.isLetter {
                        keyboard.composition.append(key)
                    } else {
                        keyboard.finishComposition()
                        keyboard.textDocumentProxy.insertText(value)
                    }
                    if keyboard.shifted { keyboard.shifted = false; keyboard.rebuild() }
                }
                if !symbols { addFlickSymbol(to: cap, letter: key) }
                keysRow.addArrangedSubview(cap)
            }
            if last && !nineKeys {
                let delete = button("⌫", style: .control) { keyboard in
                    if keyboard.composition.spelling.isEmpty { keyboard.textDocumentProxy.deleteBackward() }
                    else { keyboard.composition.backspace() }
                }
                delete.configuration?.title = nil
                delete.configuration?.image = UIImage(systemName: "delete.left")
                delete.accessibilityLabel = "退格"
                trailing = delete
            }
            if let leading, !(leading is UIButton) { trailing = UIView() }
            if let leading { row.addArrangedSubview(leading) }
            row.addArrangedSubview(keysRow)
            if let trailing { row.addArrangedSubview(trailing) }
            for edge in [leading, trailing] {
                guard let edge else { continue }
                edge.widthAnchor.constraint(equalTo: row.widthAnchor, multiplier: edge is UIButton ? 0.14 : 0.05).isActive = true
            }
            rows.addArrangedSubview(wideNine ? wideNineRow(index, letters: row) : row)
        }
        if wideNine { rows.addArrangedSubview(wideNineRow(3, letters: navigationKeys())) }

        let controls = UIStackView()
        if needsInputModeSwitchKey {
            let globe = styledButton("◎", style: .control)
            globe.setImage(UIImage(systemName: "globe"), for: .normal)
            globe.setTitle(nil, for: .normal)
            globe.accessibilityLabel = "切换键盘"
            globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
            controls.addArrangedSubview(globe)
            if layout == .compact {
                globe.widthAnchor.constraint(equalTo: controls.widthAnchor, multiplier: 0.16).isActive = true
            }
        }
        let numbers = button(symbols ? "ABC" : "123", style: .control) {
            if !$0.isEnteringCode { $0.finishComposition() }
            $0.symbols.toggle()
            $0.shifted = false
            $0.rebuild()
        }
        controls.addArrangedSubview(numbers)
        let punctuation = field == .emailAddress ? "@" : (field == .URL ? "/" : (english ? "," : "，"))
        let comma = button(punctuation, style: .control) {
            $0.finishComposition()
            $0.textDocumentProxy.insertText(punctuation)
        }
        controls.addArrangedSubview(comma)
        if nineKeys {
            controls.addArrangedSubview(button("⌫", style: .control) {
                if $0.composition.spelling.isEmpty { $0.textDocumentProxy.deleteBackward() }
                else { $0.composition.backspace() }
            })
        }
        if !wideNine && layout != .compact {
            let navigation = navigationKeys()
            controls.addArrangedSubview(navigation)
            navigation.widthAnchor.constraint(equalToConstant: 150).isActive = true
        }
        let space = button("", style: .space) { $0.insert(defaultText: " ") }
        space.accessibilityLabel = english ? "space" : "空格"
        space.accessibilityHint = "长按开始语音转文字"
        let drag = UILongPressGestureRecognizer(target: self, action: #selector(moveCursor(_:)))
        drag.delegate = self
        space.addGestureRecognizer(drag)
        let voiceHold = UILongPressGestureRecognizer(target: self, action: #selector(spaceVoiceHold(_:)))
        voiceHold.minimumPressDuration = 0.65
        voiceHold.delegate = self
        space.addGestureRecognizer(voiceHold)
        controls.addArrangedSubview(space)
        let language = button(english ? "中" : "英", style: .control) {
            $0.finishComposition()
            $0.english.toggle()
            $0.symbols = false
            $0.shifted = false
            $0.rebuild()
        }
        controls.addArrangedSubview(language)
        let enter = button("回车", style: .accent) { $0.commitReturn() }
        enterKey = enter
        controls.addArrangedSubview(enter)
        enter.widthAnchor.constraint(equalTo: controls.widthAnchor, multiplier: layout == .compact ? 0.20 : 0.16).isActive = true
        if layout == .compact {
            for (cap, width) in [(numbers, 0.16), (comma, 0.10), (language, 0.12)] {
                cap.widthAnchor.constraint(equalTo: controls.widthAnchor, multiplier: width).isActive = true
            }
        }
        if layout != .compact {
            // Give the remaining width to Space, including its cursor-drag surface.
            for case let cap as UIButton in controls.arrangedSubviews where cap !== enter && cap !== space {
                let width = layout == .tablet ? cap.widthAnchor.constraint(equalToConstant: 56)
                    : cap.widthAnchor.constraint(equalTo: controls.widthAnchor, multiplier: 0.075)
                width.isActive = true
            }
        }
        rows.addArrangedSubview(controls)
        updateReturnTitle()
    }

    private func letterButton(title: String, code: Character) -> LetterButton {
        let cap = LetterButton(type: .custom)
        cap.code = code
        _ = styledButton(title, style: .letter, key: cap)
        cap.addAction(UIAction { [weak self, weak cap] _ in
            guard let self, let cap else { return }
            let prefix = composition.spelling
            composition.append(code)
            if let point = cap.takeNeighbourPoint(), let adjacent = letterKeys.first(where: { other in
                other !== cap && other.bounds.contains(other.convert(point, from: cap))
            }), let neighbour = adjacent.code {
                edgeTouches.append(EdgeTouch(prefix: prefix + String(code), neighbour: neighbour))
            }
            refresh()
        }, for: .touchUpInside)
        letterKeys.append(cap)
        return cap
    }

    private var isEnteringCode: Bool {
        guard !english, communityID == nil, scheme != .nine else { return false }
        let first = composition.spelling.first
        return first == "R" || first == "U"
    }

    private func acceptsCodeCharacter(_ key: Character) -> Bool {
        guard isEnteringCode else { return false }
        if key.isNumber { return true }
        return composition.spelling.first == "U" ? "abcdef".contains(key) : key == "."
    }

    private func addFlickSymbol(to cap: UIButton, letter: Character) {
        let rows = [("qwertyuiop", "1234567890"), ("asdfghjkl", english ? "@#$%&*-+/" : "＠＃￥％＆＊－＋／"),
                    ("zxcvbnm", english ? "!?(),.:" : "！？（）。，：")]
        for (letters, symbols) in rows {
            guard let index = Array(letters).firstIndex(of: letter) else { continue }
            let value = Array(symbols)[index]
            let hint = UILabel()
            hint.text = String(value)
            hint.textColor = .secondaryLabel
            hint.font = .systemFont(ofSize: 9, weight: .medium)
            hint.isAccessibilityElement = false
            hint.translatesAutoresizingMaskIntoConstraints = false
            cap.addSubview(hint)
            NSLayoutConstraint.activate([
                hint.topAnchor.constraint(equalTo: cap.topAnchor, constant: 4),
                hint.trailingAnchor.constraint(equalTo: cap.trailingAnchor, constant: -5)
            ])
            let flick = SymbolFlick(target: self, action: #selector(insertFlickSymbol(_:)))
            flick.symbol = value
            flick.direction = .up
            cap.addGestureRecognizer(flick)
            cap.accessibilityHint = "上划输入" + String(value)
            break
        }
    }

    @objc private func insertFlickSymbol(_ gesture: SymbolFlick) {
        guard let symbol = gesture.symbol else { return }
        if acceptsCodeCharacter(symbol) { composition.append(symbol) }
        else { finishComposition(); textDocumentProxy.insertText(String(symbol)) }
        refresh()
    }

    private func finishComposition(allowRawFallback: Bool = true) {
        while !composition.spelling.isEmpty {
            let pending = composition.spelling
            let preview = composition.displaySpelling
            if !allowRawFallback && !composition.hasNativeCandidates { return }
            if let selected = composition.select(0) {
                textDocumentProxy.insertText(selected)
            }
            if composition.spelling == pending && composition.displaySpelling == preview {
                if !allowRawFallback { return }
                textDocumentProxy.insertText(preview)
                composition.clear()
            }
        }
    }

    private func updateReturnTitle() {
        let titles: [UIReturnKeyType: String] = [.send: "发送", .done: "完成",
            .go: "前往", .next: "下一项", .join: "加入", .continue: "继续"]
        enterKey?.configuration?.title = composition.spelling.isEmpty
            ? titles[textDocumentProxy.returnKeyType ?? .default, default: "回车"] : "回车"
    }

    @objc private func moveCursor(_ gesture: UILongPressGestureRecognizer) {
        let x = gesture.location(in: view).x
        if gesture.state == .began { cursorAnchor = x }
        guard gesture.state == .changed else { return }
        let step: CGFloat = 12
        let offset = Int((x - cursorAnchor) / step)
        guard offset != 0 else { return }
        textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
        cursorAnchor += CGFloat(offset) * step
    }

    @objc private func spaceVoiceHold(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { openVoice() }
    }

    private enum KeyStyle { case letter, control, space, accent, candidate }

    private var preferredKeyboardHeight: CGFloat {
        let pad = traitCollection.userInterfaceIdiom == .pad
        let standard: CGFloat = pad ? 320 : 268
        let delta: CGFloat
        switch appearance.height {
        case .small: delta = pad ? -18 : -12
        case .standard: delta = 0
        case .large: delta = pad ? 48 : 36
        }
        return standard + delta + (traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 16 : 0)
    }

    private func keyFont(_ style: KeyStyle) -> UIFont {
        let base: CGFloat = style == .letter ? 22 : (style == .candidate ? 18 : 16)
        let adjusted = base + CGFloat(appearance.font.rawValue) * 2
        let maximum: CGFloat = style == .letter ? 34 : (style == .candidate ? 28 : 25)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: adjusted),
            maximumPointSize: maximum, compatibleWith: traitCollection)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard keyboardHeight != nil,
              previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }
        updateAppearance()
    }

    private func updateAppearance() {
        keyboardHeight?.constant = preferredKeyboardHeight
        candidatePanel.wordFont = keyFont(.candidate)
        rebuild()
        refresh()
    }

    @objc private func playKeyFeedback() {
        guard appearance.haptics else { return }
        if feedback == nil { feedback = UIImpactFeedbackGenerator(style: .light) }
        feedback?.impactOccurred()
    }

    private func appearanceMenu() -> UIMenu {
        func sizeMenu(_ title: String, _ labels: [String], _ key: WritableKeyPath<KeyboardAppearance, KeyboardAppearance.Level>) -> UIMenu {
            let items = zip(KeyboardAppearance.Level.allCases, labels).map { level, label in
                UIAction(title: label, state: appearance[keyPath: key] == level ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    appearance[keyPath: key] = level
                    appearance.save()
                    updateAppearance()
                }
            }
            return UIMenu(title: title, children: items)
        }
        let height = sizeMenu("键盘高度", ["紧凑", "标准高度", "加高"], \.height)
        let font = sizeMenu("按键字号", ["小号", "标准字号", "大号"], \.font)
        let haptics = UIAction(title: "按键触感", state: appearance.haptics ? .on : .off) { [weak self] _ in
            guard let self else { return }
            appearance.haptics.toggle()
            appearance.save()
            if appearance.haptics { playKeyFeedback() } else { feedback = nil }
            refresh()
        }
        let reset = UIAction(title: "恢复默认外观") { [weak self] _ in
            guard let self else { return }
            appearance = KeyboardAppearance()
            appearance.save()
            feedback = nil
            updateAppearance()
        }
        return UIMenu(title: "外观与触感", image: UIImage(systemName: "textformat.size"),
                      children: [height, font, haptics, reset])
    }

    private func styledButton(_ title: String, style: KeyStyle, key: UIButton = UIButton(type: .custom)) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.baseForegroundColor = style == .accent ? Self.accentInk : .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 1, bottom: 0, trailing: 1)
        let font = keyFont(style)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes
            result.font = font
            return result
        }
        // Only inset the painted cap. The button occupies the entire cell.
        config.background.cornerRadius = 10
        config.background.backgroundInsets = NSDirectionalEdgeInsets(top: 3, leading: 2, bottom: 3, trailing: 2)
        let color: UIColor
        switch style {
        case .letter, .space: color = Self.keyColor
        case .control: color = Self.controlColor
        case .accent: color = Self.accentKey
        case .candidate:
            color = .clear
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 5)
            config.background.backgroundInsets = .zero
        }
        config.background.backgroundColor = color
        key.configuration = config
        key.titleLabel?.adjustsFontSizeToFitWidth = true
        key.titleLabel?.minimumScaleFactor = 0.75
        key.addTarget(self, action: #selector(playKeyFeedback), for: .touchUpInside)
        key.configurationUpdateHandler = { button in
            button.configuration?.background.backgroundColor = button.isHighlighted ? .systemGray2 : color
        }
        return key
    }

    private func insert(defaultText: String) {
        if composition.spelling.isEmpty { textDocumentProxy.insertText(defaultText) }
        else if let word = composition.select(0) { textDocumentProxy.insertText(word) }
    }

    private func commitReturn() {
        let raw = composition.spelling
        if raw.isEmpty {
            textDocumentProxy.insertText("\n")
        } else if communityID == nil, scheme != .nine, !isEnteringCode, !composition.hasSelectedSegment,
                  raw.utf8.contains(where: { (97...122).contains($0) }),
                  raw.utf8.allSatisfy({ (97...122).contains($0) || $0 == 39 }) {
            textDocumentProxy.insertText(raw.replacingOccurrences(of: "'", with: ""))
            composition.clear()
        } else {
            finishComposition(allowRawFallback: false)
        }
        edgeTouches.removeAll()
    }

    private func button(_ title: String, style: KeyStyle = .candidate,
                        action: @escaping (KeyboardController) -> Void) -> UIButton {
        let key = styledButton(title, style: style)
        key.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            closeCandidates()
            action(self)
            self.refresh()
        }, for: .touchUpInside)
        return key
    }

    private func phraseMenu() -> UIMenu {
        UIMenu(title: "快捷短语", image: UIImage(systemName: "text.quote"), children: [UIDeferredMenuElement.uncached { [weak self] complete in
            guard let self else { complete([]); return }
            let saved = phrases.entries
            let save = UIAction(title: "收藏选中文字", image: UIImage(systemName: "plus")) { [weak self] _ in
                guard let self, let selection = textDocumentProxy.selectedText else { return }
                phrases.add(selection)
            }
            if textDocumentProxy.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                save.attributes = .disabled
            }
            var actions: [UIMenuElement] = saved.map { phrase in
                UIAction(title: phrase) { [weak self] _ in
                    self?.textDocumentProxy.insertText(phrase)
                }
            }
            actions.append(save)
            if !saved.isEmpty {
                actions.append(UIMenu(title: "移除短语", children: saved.map { phrase in
                    UIAction(title: phrase, attributes: .destructive) { [weak self] _ in
                        self?.phrases.remove(phrase)
                    }
                }))
            }
            complete(actions)
        }])
    }

    private func correctionButtons(excluding native: [String]) -> [UIButton] {
        let raw = composition.spelling
        edgeTouches.removeAll { !raw.hasPrefix($0.prefix) }
        guard !edgeTouches.isEmpty, (3...48).contains(raw.count),
              communityID == nil, !english, !symbols, composition.displaySpelling == raw,
              !composition.canPage(backward: true), let engine = correctionSession else { return [] }

        if correctionScheme != scheme {
            guard engine.useSchema(scheme.rawValue) else { return [] }
            correctionScheme = scheme
            correctionCache.removeAll(keepingCapacity: true)
        }
        if correctionForm != outputForm || correctionCache.count > 48 {
            correctionCache.removeAll(keepingCapacity: true)
            correctionForm = outputForm
        }
        engine.setOutputForm(outputForm)
        // At most seven alternatives, considering one, two or three touched neighbours together.
        let touches = Array(edgeTouches.suffix(3))
        var seen = Set(native)
        var matches: [(code: String, word: String, edits: Int)] = []
        for mask in 1..<(1 << touches.count) {
            var letters = Array(raw)
            for (i, touch) in touches.enumerated() where mask & (1 << i) != 0 {
                letters[touch.prefix.count - 1] = touch.neighbour
            }
            let code = String(letters)
            let word: String
            if let cached = correctionCache[code] { word = cached }
            else {
                guard engine.replaceInput(code) else { continue }
                word = engine.choices.first ?? ""
                correctionCache[code] = word
            }
            if word.unicodeScalars.contains(where: { $0.properties.isIdeographic }), seen.insert(word).inserted {
                matches.append((code, word, mask.nonzeroBitCount))
            }
        }
        // Prefer a whole phrase over a shorter partial match, then the least invasive correction.
        return matches.sorted {
            if $0.word.count != $1.word.count { return $0.word.count > $1.word.count }
            if $0.edits != $1.edits { return $0.edits < $1.edits }
            return $0.code < $1.code
        }.prefix(3).map { match in
            let choice = button(match.word) { keyboard in
                guard keyboard.composition.spelling == raw else { return }
                keyboard.edgeTouches.removeAll()
                keyboard.composition.clear()
                for key in match.code { keyboard.composition.append(key) }
                if let text = keyboard.composition.selectNative(at: 0) { keyboard.textDocumentProxy.insertText(text) }
            }
            choice.configuration?.baseForegroundColor = .systemIndigo
            choice.accessibilityLabel = "纠错候选，" + match.word
            return choice
        }
    }

    private func enableContextualRanking() {
        contextualRanking = ContextualRanking { [weak self] in
            guard let self, viewIfLoaded?.window != nil else { return }
            refresh()
        }
    }

    private func updateContextualOrder() {
        guard let contextualRanking, contextualRanking.isReady else {
            composition.updateContextualOrder(nil)
            return
        }
        guard communityID == nil, scheme == .full, outputForm == .simplified, !english, !symbols,
              !composition.spelling.isEmpty, textDocumentProxy.isSecureTextEntry != true else {
            contextualRanking.clear()
            composition.updateContextualOrder(nil)
            return
        }
        composition.updateContextualOrder { [self] raw, choices in
            let prefix = ContextualRanking.trailingHan(in: textDocumentProxy.documentContextBeforeInput)
            return contextualRanking.preferredIndex(raw: raw, choices: choices, prefix: prefix,
                                                    lookup: composition.firstContextMatch)
        }
    }

    private func refreshSettingsPanel() {
        let state = KeyboardSettingsPanel.State(
            schemes: Scheme.allCases.map {
                .init(id: $0.rawValue, title: $0.title, selected: communityID == nil && $0 == scheme)
            },
            communitySchemes: (communityLibrary?.schemes ?? []).map {
                .init(id: $0.id, title: $0.name, selected: $0.id == communityID)
            },
            currentSchemeTitle: schemeTitle,
            outputForms: (communityID == nil ? RimeOutputForm.allCases : [.simplified, .traditional]).map {
                .init(id: $0.rawValue, title: $0.title, selected: $0 == effectiveOutputForm)
            },
            currentOutputFormTitle: effectiveOutputForm.title,
            heightLevel: appearance.height.rawValue,
            fontLevel: appearance.font.rawValue,
            hapticsEnabled: appearance.haptics,
            contextualEnabled: contextualRanking != nil,
            phrases: phrases.entries,
            canSaveSelection: textDocumentProxy.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            hasStandby: hasFullAccess && VoiceHandoff.standby() != nil,
            endingStandby: hasFullAccess && VoiceHandoff.standby().map { endingStandby?.id == $0.id } == true,
            hasUninsertedVoice: currentDocumentID != nil && VoiceDelivery.latestUninserted() != nil
        )
        settingsPanel.onSelectScheme = { [weak self] raw in
            guard let self, let choice = Scheme(rawValue: raw),
                  YahRimeSession.configure(), composition.useSchema(choice.rawValue) else { return }
            communityID = nil
            UserDefaults.standard.removeObject(forKey: "communitySchema")
            correctionCache.removeAll()
            edgeTouches.removeAll()
            scheme = choice
            english = false
            symbols = false
            shifted = false
            composition.setOutputForm(outputForm)
            UserDefaults.standard.set(choice.rawValue, forKey: "scheme")
            let shared = UserDefaults(suiteName: "group.local.yah.voice")
            shared?.set(choice.rawValue, forKey: "scheme")
            let revision = (shared?.integer(forKey: "schemeSelectionRevision") ?? 0) + 1
            shared?.set(revision, forKey: "schemeSelectionRevision")
            UserDefaults.standard.set(revision, forKey: "keyboardSharedSchemeRevision")
            rebuild()
            refresh()
            refreshSettingsPanel()
        }
        settingsPanel.onSelectCommunityScheme = { [weak self] id in
            guard let self, activateCommunity(id) else { return }
            rebuild()
            refresh()
            refreshSettingsPanel()
        }
        settingsPanel.onSelectOutputForm = { [weak self] raw in
            guard let self, let form = RimeOutputForm(rawValue: raw) else { return }
            outputForm = form
            composition.setOutputForm(form)
            form.save()
            refresh()
            refreshSettingsPanel()
        }
        settingsPanel.onSetHeight = { [weak self] raw in
            guard let self, let level = KeyboardAppearance.Level(rawValue: raw) else { return }
            appearance.height = level
            appearance.save()
            updateAppearance()
            refreshSettingsPanel()
        }
        settingsPanel.onSetFont = { [weak self] raw in
            guard let self, let level = KeyboardAppearance.Level(rawValue: raw) else { return }
            appearance.font = level
            appearance.save()
            updateAppearance()
            refreshSettingsPanel()
        }
        settingsPanel.onToggleHaptics = { [weak self] in
            guard let self else { return }
            appearance.haptics.toggle()
            appearance.save()
            if appearance.haptics { playKeyFeedback() } else { feedback = nil }
            refresh()
            refreshSettingsPanel()
        }
        settingsPanel.onResetAppearance = { [weak self] in
            guard let self else { return }
            appearance = KeyboardAppearance()
            appearance.save()
            feedback = nil
            updateAppearance()
            refreshSettingsPanel()
        }
        settingsPanel.onToggleContextual = { [weak self] in
            guard let self else { return }
            let enabled = contextualRanking == nil
            UserDefaults.standard.set(enabled, forKey: Self.contextPreference)
            if enabled { enableContextualRanking() } else { contextualRanking = nil }
            refresh()
            refreshSettingsPanel()
        }
        settingsPanel.onInsertPhrase = { [weak self] phrase in
            guard let self else { return }
            textDocumentProxy.insertText(phrase)
            closeSettings()
        }
        settingsPanel.onSaveSelectionPhrase = { [weak self] in
            guard let self, let selection = textDocumentProxy.selectedText else { return }
            phrases.add(selection)
            refreshSettingsPanel()
        }
        settingsPanel.onRemovePhrase = { [weak self] phrase in
            guard let self else { return }
            phrases.remove(phrase)
            refreshSettingsPanel()
        }
        settingsPanel.onStartVoice = { [weak self] in
            guard let self else { return }
            closeSettings()
            openVoice()
        }
        settingsPanel.onInsertLatestVoice = { [weak self] in
            guard let self, let document = currentDocumentID, let result = VoiceDelivery.latestUninserted() else { return }
            let id = result.id, recording = result.recordingID
            guard currentDocumentID == document,
                  let item = recording.flatMap(VoiceHandoff.pending(for:)) ?? VoiceHandoff.pending(),
                  item.id == id else { return }
            closeSettings()
            insertPendingVoice(item, explicitlyHere: true)
        }
        settingsPanel.onEndStandby = { [weak self] in
            guard let self else { return }
            endStandby()
            refreshSettingsPanel()
        }
        settingsPanel.render(state)
    }

    private func refresh() {
        // The expanded panel keeps the order and absolute indices of the rows already on screen.
        if candidatePanel.isHidden { updateContextualOrder() }
        if composition.spelling.isEmpty { closeCandidates() } else { closeSettings() }
        updateCandidateToggle()
        updateSettingsToggle()
        updateReturnTitle()
        let displayed = composition.displaySpelling
        spelling.text = nineKeys ? displayed.map { key in
            guard let ascii = key.asciiValue, (65...72).contains(ascii) else { return String(key) }
            return String(ascii - 63)
        }.joined() : displayed
        spelling.isHidden = spelling.text?.isEmpty != false
        suggestions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if !settingsPanel.isHidden { refreshSettingsPanel() }
        if composition.canPage(backward: true) {
            let previous = button("‹") { $0.composition.page(backward: true) }
            previous.accessibilityLabel = "上一页候选"
            suggestions.addArrangedSubview(previous)
        }
        let native = composition.candidates
        let corrections = correctionButtons(excluding: native)
        for (i, word) in native.enumerated() {
            suggestions.addArrangedSubview(button(word) { keyboard in
                if let selected = keyboard.composition.select(i) { keyboard.textDocumentProxy.insertText(selected) }
            })
            if i == 0 { corrections.forEach { suggestions.addArrangedSubview($0) } }
        }
        if composition.canPage(backward: false) {
            let next = button("›") { $0.composition.page(backward: false) }
            next.accessibilityLabel = "下一页候选"
            suggestions.addArrangedSubview(next)
        }
    }
}

/// Keeps the candidate scroll view and the stop target independently accessible.
private final class KeyboardRecordingPreview: UIControl {
    private let draft = UILabel()
    private let elapsed = UILabel()
    private let meter = KeyboardLevelMeter()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityIdentifier = "voice-live-preview"
        draft.font = .preferredFont(forTextStyle: .subheadline)
        draft.adjustsFontForContentSizeCategory = true
        draft.textColor = .label
        draft.lineBreakMode = .byTruncatingHead
        elapsed.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .medium)
        elapsed.adjustsFontForContentSizeCategory = true
        elapsed.textColor = .secondaryLabel
        elapsed.setContentCompressionResistancePriority(.required, for: .horizontal)
        let details = UIStackView(arrangedSubviews: [meter, elapsed])
        details.spacing = 5
        details.alignment = .center
        let contents = UIStackView(arrangedSubviews: [draft, details])
        contents.axis = .vertical
        contents.spacing = 2
        contents.isUserInteractionEnabled = false
        contents.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contents)
        NSLayoutConstraint.activate([
            contents.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            contents.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            contents.centerYAnchor.constraint(equalTo: centerYAnchor),
            meter.heightAnchor.constraint(equalToConstant: 15)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(text: String?, levels: [Float], seconds: Int, canReveal: Bool) {
        let trimmed = text?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let time = String(format: "%d:%02d", seconds / 60, seconds % 60)
        draft.text = canReveal ? "查看草稿" : String(trimmed.suffix(32))
        draft.textColor = canReveal ? .link : .label
        draft.isHidden = !canReveal && trimmed.isEmpty
        elapsed.superview?.isHidden = !draft.isHidden && traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        elapsed.text = time
        meter.isListening = true
        meter.show(levels, reduceMotion: UIAccessibility.isReduceMotionEnabled)
        isUserInteractionEnabled = canReveal
        accessibilityTraits = canReveal ? [.button] : [.staticText]
        accessibilityLabel = canReveal ? "查看本段听写草稿" : "听写预览"
        accessibilityHint = canReveal ? "在当前输入框显示草稿" : nil
        accessibilityValue = [trimmed, "已录音 " + time, meter.levelDescription].filter { !$0.isEmpty }.joined(separator: "，")
        isHidden = false
    }

    func clear() {
        guard !isHidden else { return }
        isHidden = true
        draft.text = nil
        elapsed.text = nil
        accessibilityValue = nil
        accessibilityHint = nil
        meter.isListening = false
        meter.show([], reduceMotion: true)
    }
}

private final class KeyboardLevelMeter: UIView {
    private var targetLevels: [Float] = []
    private var displayLevels: [CGFloat] = Array(repeating: 0, count: 21)
    private var reduceMotion = false
    private var displayLink: CADisplayLink?
    private var phase: CGFloat = 0
    var barColor: UIColor = .systemBlue
    var minimumBarHeight: CGFloat = 4
    var showIdleBars = false
    var isListening = false {
        didSet { updateDisplayLink() }
    }
    var levelDescription: String {
        guard let level = targetLevels.last else { return "尚无音量数据" }
        if level < 0.05 { return "安静" }
        return level < 0.5 ? "音量较低" : "音量较高"
    }

    func show(_ samples: [Float], reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        targetLevels = samples
        if reduceMotion || !isListening {
            syncDisplayLevelsImmediately()
            setNeedsDisplay()
        } else {
            updateDisplayLink()
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isAccessibilityElement = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        displayLink?.invalidate()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDisplayLink()
    }

    override var isHidden: Bool {
        didSet { updateDisplayLink() }
    }

    private func updateDisplayLink() {
        let shouldRun = window != nil && !isHidden && isListening && !reduceMotion
        if shouldRun {
            if displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(stepAnimation))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func sampledTargets(count: Int) -> [CGFloat] {
        guard !targetLevels.isEmpty else {
            return Array(repeating: 0, count: count)
        }
        let recent = Array(targetLevels.suffix(12))
        let mid = CGFloat(count - 1) / 2
        return (0..<count).map { index in
            let distance = abs(CGFloat(index) - mid) / max(1, mid)
            let sampleIndex = min(recent.count - 1, max(0, Int((1 - distance) * CGFloat(recent.count - 1))))
            let raw = CGFloat(recent[sampleIndex])
            let envelope = 0.45 + 0.55 * cos(distance * .pi * 0.5)
            return min(1, max(0, raw * envelope))
        }
    }

    private func syncDisplayLevelsImmediately() {
        let targets = sampledTargets(count: displayLevels.count)
        displayLevels = targets
    }

    @objc private func stepAnimation() {
        phase += 0.10
        let count = displayLevels.count
        let targets = sampledTargets(count: count)
        let peak = targetLevels.suffix(4).max() ?? 0
        let mid = CGFloat(count - 1) / 2
        for i in 0..<count {
            let distance = abs(CGFloat(i) - mid) / max(1, mid)
            let envelope = 0.4 + 0.6 * cos(distance * .pi * 0.5)
            // Subtle organic breathing when quiet, lively response when speaking.
            let breath = (0.08 + 0.06 * sin(phase + CGFloat(i) * 0.45)) * envelope
            let activeWave = peak > 0.03 ? (0.08 * sin(phase * 2.1 + CGFloat(i) * 0.7) * CGFloat(peak) * envelope) : 0
            let desired = min(1, max(breath, targets[i] + activeWave))
            let smoothing: CGFloat = desired > displayLevels[i] ? 0.34 : 0.18
            displayLevels[i] += (desired - displayLevels[i]) * smoothing
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        let mid = bounds.midY
        if targetLevels.isEmpty && !isListening {
            if showIdleBars {
                barColor.withAlphaComponent(0.22).setFill()
                let count = displayLevels.count
                let slot = bounds.width / CGFloat(count)
                let width = min(3.5, max(2, slot * 0.42))
                for index in 0..<count {
                    let h = minimumBarHeight
                    let x = (CGFloat(index) + 0.5) * slot - width / 2
                    UIBezierPath(roundedRect: CGRect(x: x, y: mid - h / 2, width: width, height: h), cornerRadius: width / 2).fill()
                }
            } else {
                UIColor.tertiaryLabel.setFill()
                UIBezierPath(roundedRect: CGRect(x: 0, y: mid - 0.5, width: bounds.width, height: 1), cornerRadius: 0.5).fill()
            }
            return
        }
        if reduceMotion {
            let band = max(0.12, (CGFloat(targetLevels.last ?? 0) * 4).rounded() / 4)
            barColor.setFill()
            UIBezierPath(roundedRect: CGRect(x: 0, y: mid - 2.5, width: bounds.width * band, height: 5), cornerRadius: 2.5).fill()
            return
        }
        let count = displayLevels.count
        let slot = bounds.width / CGFloat(count)
        let width = min(3.5, max(2, slot * 0.42))
        let maxHeight = max(minimumBarHeight, bounds.height - 4)
        for index in 0..<count {
            let level = displayLevels[index]
            let height = max(minimumBarHeight, minimumBarHeight + level * (maxHeight - minimumBarHeight))
            let alpha = 0.35 + 0.65 * min(1, level * 1.4)
            barColor.withAlphaComponent(alpha).setFill()
            let x = (CGFloat(index) + 0.5) * slot - width / 2
            UIBezierPath(roundedRect: CGRect(x: x, y: mid - height / 2, width: width, height: height), cornerRadius: width / 2).fill()
        }
    }
}

private final class KeyboardOrbWaveformView: UIView {
    private var targetLevels: [Float] = []
    private var displayLevels: [CGFloat] = Array(repeating: 0.12, count: 7)
    private var haloScale: CGFloat = 1.0
    private var energy: CGFloat = 0
    private var displayLink: CADisplayLink?
    private var phase: CGFloat = 0
    private var reduceMotion = false

    enum Mode { case idle, starting, listening, finishing }
    var mode: Mode = .idle {
        didSet { updateDisplayLink(); setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { displayLink?.invalidate() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDisplayLink()
    }

    override var isHidden: Bool {
        didSet { updateDisplayLink() }
    }

    func update(levels: [Float], mode: Mode, reduceMotion: Bool) {
        self.targetLevels = levels
        self.mode = mode
        self.reduceMotion = reduceMotion
        if reduceMotion || mode == .idle {
            displayLevels = [0.18, 0.36, 0.62, 0.82, 0.62, 0.36, 0.18]
            haloScale = 1.0
            energy = 0
            setNeedsDisplay()
        } else {
            updateDisplayLink()
        }
    }

    private func updateDisplayLink() {
        let shouldRun = window != nil && !isHidden && mode != .idle && !reduceMotion
        if shouldRun {
            if displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(step))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
        } else {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    @objc private func step() {
        phase += mode == .finishing ? 0.14 : 0.11
        let count = displayLevels.count
        let mid = CGFloat(count - 1) / 2
        let recent = Array(targetLevels.suffix(7))
        let peak = min(1, CGFloat(recent.max() ?? 0) * 1.6)
        let average = min(1, CGFloat(recent.reduce(0, +)) / CGFloat(max(1, recent.count)) * 2.2)
        let targetEnergy: CGFloat
        switch mode {
        case .listening: targetEnergy = max(peak * 0.6 + average * 0.4, 0.04 * (0.5 + 0.5 * sin(phase * 0.9)))
        case .starting, .finishing: targetEnergy = 0.22 + 0.16 * sin(phase * 0.8)
        case .idle: targetEnergy = 0
        }
        energy += (targetEnergy - energy) * (targetEnergy > energy ? 0.45 : 0.12)

        let targetHalo: CGFloat
        switch mode {
        case .listening:
            let idlePulse = 0.04 * (0.5 + 0.5 * sin(phase * 0.9))
            targetHalo = 1.06 + idlePulse + min(0.45, peak * 0.5)
        case .starting, .finishing:
            targetHalo = 1.10 + 0.10 * (0.5 + 0.5 * sin(phase * 1.2))
        case .idle:
            targetHalo = 1.0
        }
        haloScale += (targetHalo - haloScale) * (targetHalo > haloScale ? 0.28 : 0.14)

        for i in 0..<count {
            let distance = abs(CGFloat(i) - mid) / max(1, mid)
            let envelope = 0.28 + 0.72 * cos(distance * .pi * 0.48)
            let desired: CGFloat
            switch mode {
            case .listening:
                let sample: CGFloat
                if recent.isEmpty {
                    sample = 0
                } else {
                    let idx = min(recent.count - 1, max(0, Int((1 - distance) * CGFloat(recent.count - 1))))
                    sample = CGFloat(recent[idx])
                }
                let breath = (0.18 + 0.10 * sin(phase + CGFloat(i) * 0.7)) * envelope
                let voice = sample * envelope * (0.85 + 0.25 * sin(phase * 2.2 + CGFloat(i) * 0.9))
                desired = min(1.0, max(breath, voice * 1.35))
            case .starting, .finishing:
                let wave = 0.5 + 0.5 * sin(phase * 1.8 - CGFloat(i) * 0.65)
                desired = (0.20 + 0.45 * wave) * envelope
            case .idle:
                desired = 0.15 * envelope
            }
            let smoothing: CGFloat = desired > displayLevels[i] ? 0.36 : 0.18
            displayLevels[i] += (desired - displayLevels[i]) * smoothing
        }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let orbDiameter = min(bounds.width, bounds.height) * 0.66
        let orbRadius = orbDiameter / 2

        // Layered ripples expand with voice energy
        let label = UIColor.label.resolvedColor(with: traitCollection)
        for (index, alpha) in [(2, CGFloat(0.07)), (1, CGFloat(0.12)), (0, CGFloat(0.2))] {
            let ripple = min(min(bounds.width, bounds.height) / 2, orbRadius * (1 + (haloScale - 1) * (1 + CGFloat(index) * 0.5)))
            let fade = alpha * (0.6 + 0.4 * min(1, energy * 2))
            label.withAlphaComponent(fade).setFill()
            UIBezierPath(arcCenter: center, radius: ripple, startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()
        }

        // Core orb scales with smoothed voice energy
        let coreRadius = orbRadius * (1 + 0.14 * energy)
        let coreDiameter = coreRadius * 2
        let orbColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.95, alpha: 1) : UIColor(white: 0.08, alpha: 1) }
        orbColor.resolvedColor(with: traitCollection).setFill()
        UIBezierPath(arcCenter: center, radius: coreRadius, startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()

        // 7 crisp vertical capsule bars inside the orb
        let barColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.08, alpha: 1) : .white }
        barColor.resolvedColor(with: traitCollection).setFill()

        let count = displayLevels.count
        let barWidth: CGFloat = 4.2
        let spacing: CGFloat = 5.6
        let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * spacing
        let startX = center.x - totalWidth / 2
        let maxBarHeight = coreDiameter * 0.44
        let minBarHeight = barWidth

        for i in 0..<count {
            let level = displayLevels[i]
            let height = max(minBarHeight, minBarHeight + level * (maxBarHeight - minBarHeight))
            let x = startX + CGFloat(i) * (barWidth + spacing)
            let y = center.y - height / 2
            UIBezierPath(roundedRect: CGRect(x: x, y: y, width: barWidth, height: height), cornerRadius: barWidth / 2).fill()
        }
    }
}

private final class KeyboardVoicePanel: UIView, UIGestureRecognizerDelegate {
    enum DirectMode: Equatable { case permissions, starting, listening, finishing, failed }
    var onCancel: (() -> Void)?
    var onStop: (() -> Void)?
    var onEndStandby: (() -> Void)?
    var onPanelTap: (() -> Void)?
    var onPrimaryAction: (() -> Void)?
    var onAuthorize: (() -> Void)?

    private let orbView = KeyboardOrbWaveformView()
    private let statusLabel = UILabel()
    private let draftLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let permissionMessage = UILabel()
    private let permissionButton = UIButton(type: .system)
    private let permissionCancelButton = UIButton(type: .system)
    private let settingsContainer = UIView()
    private let permissionContent = UIStackView()
    private let activeContainer = UIView()
    private var directMode: DirectMode?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        activeContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(activeContainer)

        orbView.translatesAutoresizingMaskIntoConstraints = false
        activeContainer.addSubview(orbView)

        statusLabel.font = .systemFont(ofSize: 14, weight: .regular)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        activeContainer.addSubview(statusLabel)

        draftLabel.font = .preferredFont(forTextStyle: .footnote)
        draftLabel.textColor = .label
        draftLabel.numberOfLines = 1
        draftLabel.lineBreakMode = .byTruncatingHead
        draftLabel.textAlignment = .center
        draftLabel.translatesAutoresizingMaskIntoConstraints = false
        activeContainer.addSubview(draftLabel)

        var cancelConfig = UIButton.Configuration.filled()
        cancelConfig.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        cancelConfig.cornerStyle = .capsule
        cancelConfig.baseBackgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.24, alpha: 1) : UIColor.black.withAlphaComponent(0.08) }
        cancelConfig.baseForegroundColor = .secondaryLabel
        cancelButton.configuration = cancelConfig
        cancelButton.accessibilityLabel = "取消录音"
        cancelButton.accessibilityIdentifier = "voice-panel-cancel"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
        activeContainer.addSubview(cancelButton)

        permissionMessage.font = .preferredFont(forTextStyle: .body)
        permissionMessage.adjustsFontForContentSizeCategory = true
        permissionMessage.textColor = .secondaryLabel
        permissionMessage.numberOfLines = 0
        permissionMessage.textAlignment = .center
        permissionButton.setTitle("立即开启", for: .normal)
        permissionButton.accessibilityIdentifier = "voice-permission-authorize"
        permissionButton.addAction(UIAction { [weak self] _ in self?.onAuthorize?() }, for: .touchUpInside)
        settingsContainer.heightAnchor.constraint(equalToConstant: 36).isActive = true

        permissionCancelButton.setTitle("取消", for: .normal)
        permissionCancelButton.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
        let permissionActions = UIStackView(arrangedSubviews: [permissionCancelButton, permissionButton])
        permissionActions.spacing = 10
        permissionActions.distribution = .fillEqually
        permissionActions.translatesAutoresizingMaskIntoConstraints = false
        permissionActions.heightAnchor.constraint(equalToConstant: 42).isActive = true

        permissionContent.axis = .vertical
        permissionContent.spacing = 10
        permissionContent.alignment = .center
        permissionContent.addArrangedSubview(permissionMessage)
        permissionContent.addArrangedSubview(permissionActions)
        permissionContent.addArrangedSubview(settingsContainer)
        permissionContent.translatesAutoresizingMaskIntoConstraints = false
        permissionContent.isHidden = true
        addSubview(permissionContent)

        NSLayoutConstraint.activate([
            activeContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            activeContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            activeContainer.topAnchor.constraint(equalTo: topAnchor),
            activeContainer.bottomAnchor.constraint(equalTo: bottomAnchor),

            cancelButton.topAnchor.constraint(equalTo: activeContainer.topAnchor, constant: 10),
            cancelButton.trailingAnchor.constraint(equalTo: activeContainer.trailingAnchor, constant: -12),
            cancelButton.widthAnchor.constraint(equalToConstant: 30),
            cancelButton.heightAnchor.constraint(equalToConstant: 30),

            draftLabel.topAnchor.constraint(equalTo: activeContainer.topAnchor, constant: 12),
            draftLabel.leadingAnchor.constraint(equalTo: activeContainer.leadingAnchor, constant: 48),
            draftLabel.trailingAnchor.constraint(equalTo: activeContainer.trailingAnchor, constant: -48),

            orbView.centerXAnchor.constraint(equalTo: activeContainer.centerXAnchor),
            orbView.centerYAnchor.constraint(equalTo: activeContainer.centerYAnchor, constant: -10),
            orbView.widthAnchor.constraint(equalToConstant: 168),
            orbView.heightAnchor.constraint(equalToConstant: 168),

            statusLabel.topAnchor.constraint(equalTo: orbView.bottomAnchor, constant: 2),
            statusLabel.leadingAnchor.constraint(equalTo: activeContainer.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: activeContainer.trailingAnchor, constant: -16),

            permissionContent.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            permissionContent.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            permissionContent.centerYAnchor.constraint(equalTo: centerYAnchor),
            permissionActions.widthAnchor.constraint(equalTo: permissionContent.widthAnchor),
            permissionMessage.widthAnchor.constraint(equalTo: permissionContent.widthAnchor),
            settingsContainer.widthAnchor.constraint(equalTo: permissionContent.widthAnchor)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handlePanelTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSettingsView(_ settingsView: UIView) {
        settingsView.translatesAutoresizingMaskIntoConstraints = false
        settingsContainer.addSubview(settingsView)
        NSLayoutConstraint.activate([
            settingsView.leadingAnchor.constraint(equalTo: settingsContainer.leadingAnchor),
            settingsView.trailingAnchor.constraint(equalTo: settingsContainer.trailingAnchor),
            settingsView.topAnchor.constraint(equalTo: settingsContainer.topAnchor),
            settingsView.bottomAnchor.constraint(equalTo: settingsContainer.bottomAnchor)
        ])
    }

    func renderDirect(title: String, message: String, levels: [Float], mode: DirectMode, actionTitle: String?) {
        directMode = mode
        let isPermissionOrFailed = (mode == .permissions || mode == .failed)
        activeContainer.isHidden = isPermissionOrFailed
        permissionContent.isHidden = !isPermissionOrFailed

        if isPermissionOrFailed {
            orbView.update(levels: [], mode: .idle, reduceMotion: UIAccessibility.isReduceMotionEnabled)
            permissionMessage.text = message
            permissionButton.isHidden = mode != .permissions
            permissionButton.isEnabled = mode == .permissions
            settingsContainer.isHidden = mode != .failed
            return
        }

        statusLabel.text = title
        let trimmed = message.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        draftLabel.text = trimmed
        draftLabel.isHidden = trimmed.isEmpty
        cancelButton.isHidden = mode == .finishing
        cancelButton.isEnabled = mode == .listening || mode == .starting

        let orbMode: KeyboardOrbWaveformView.Mode
        switch mode {
        case .listening: orbMode = .listening
        case .starting: orbMode = .starting
        case .finishing: orbMode = .finishing
        case .permissions, .failed: orbMode = .idle
        }
        orbView.update(levels: levels, mode: orbMode, reduceMotion: UIAccessibility.isReduceMotionEnabled)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard directMode == .listening else { return false }
        var touchedView = touch.view
        while let current = touchedView {
            if current is UIButton { return false }
            if current === self { break }
            touchedView = current.superview
        }
        return true
    }

    @objc private func handlePanelTap() {
        guard directMode == .listening else { return }
        onPanelTap?()
    }
}

private final class KeyboardSettingsPanel: UIView {
    struct Option {
        let id: String
        let title: String
        let selected: Bool
    }
    struct State {
        let schemes: [Option]
        let communitySchemes: [Option]
        let currentSchemeTitle: String
        let outputForms: [Option]
        let currentOutputFormTitle: String
        let heightLevel: Int
        let fontLevel: Int
        let hapticsEnabled: Bool
        let contextualEnabled: Bool
        let phrases: [String]
        let canSaveSelection: Bool
        let hasStandby: Bool
        let endingStandby: Bool
        let hasUninsertedVoice: Bool
    }
    private enum Page: Equatable {
        case root, schemes, outputForm, appearance, phrases, voice
        var title: String {
            switch self {
            case .root: return "设置"
            case .schemes: return "输入方案"
            case .outputForm: return "输出字形"
            case .appearance: return "外观与触感"
            case .phrases: return "快捷短语"
            case .voice: return "语音工具"
            }
        }
    }

    var onClose: (() -> Void)?
    var onSelectScheme: ((String) -> Void)?
    var onSelectCommunityScheme: ((String) -> Void)?
    var onSelectOutputForm: ((String) -> Void)?
    var onSetHeight: ((Int) -> Void)?
    var onSetFont: ((Int) -> Void)?
    var onToggleHaptics: (() -> Void)?
    var onResetAppearance: (() -> Void)?
    var onToggleContextual: (() -> Void)?
    var onInsertPhrase: ((String) -> Void)?
    var onSaveSelectionPhrase: (() -> Void)?
    var onRemovePhrase: ((String) -> Void)?
    var onStartVoice: (() -> Void)?
    var onInsertLatestVoice: (() -> Void)?
    var onEndStandby: (() -> Void)?

    private var page: Page = .root
    private var lastState: State?

    private let navBar = UIStackView()
    private let backButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    private static let tileColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.24, alpha: 1) : .white }
    private static let activeTileColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor.systemBlue.withAlphaComponent(0.28) : UIColor.systemBlue.withAlphaComponent(0.12) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let rootStack = UIStackView()
        rootStack.axis = .vertical
        rootStack.spacing = 6
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            rootStack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])

        var backConfig = UIButton.Configuration.plain()
        backConfig.title = "返回"
        backConfig.image = UIImage(systemName: "chevron.left", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        backConfig.imagePadding = 3
        backConfig.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 8)
        backButton.configuration = backConfig
        backButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            page = .root
            if let lastState { render(lastState) }
        }, for: .touchUpInside)

        titleLabel.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        titleLabel.textAlignment = .center
        titleLabel.textColor = .label

        var closeConfig = UIButton.Configuration.plain()
        closeConfig.title = "完成"
        closeConfig.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 4)
        closeButton.configuration = closeConfig
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)

        navBar.alignment = .center
        navBar.addArrangedSubview(backButton)
        navBar.addArrangedSubview(titleLabel)
        navBar.addArrangedSubview(closeButton)
        navBar.heightAnchor.constraint(equalToConstant: 32).isActive = true
        backButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        rootStack.addArrangedSubview(navBar)

        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        contentStack.axis = .vertical
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
        rootStack.addArrangedSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func resetToRoot() {
        page = .root
    }

    func render(_ state: State) {
        lastState = state
        navBar.isHidden = (page == .root)
        titleLabel.text = page.title
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        scrollView.setContentOffset(.zero, animated: false)

        switch page {
        case .root:
            renderRoot(state)
        case .schemes:
            renderSchemes(state)
        case .outputForm:
            renderOutputForms(state)
        case .appearance:
            renderAppearance(state)
        case .phrases:
            renderPhrases(state)
        case .voice:
            renderVoice(state)
        }
    }

    private func renderRoot(_ state: State) {
        let row1 = UIStackView(arrangedSubviews: [
            makeTile(icon: "keyboard", title: "输入方案", subtitle: state.currentSchemeTitle, active: false) { [weak self] in
                self?.navigate(to: .schemes)
            },
            makeTile(icon: "character.book.closed", title: "输出字形", subtitle: state.currentOutputFormTitle, active: false) { [weak self] in
                self?.navigate(to: .outputForm)
            },
            makeTile(icon: "slider.horizontal.3", title: "外观与触感", subtitle: "高度 · 字号", active: false) { [weak self] in
                self?.navigate(to: .appearance)
            }
        ])
        row1.distribution = .fillEqually
        row1.spacing = 8
        row1.heightAnchor.constraint(equalToConstant: 82).isActive = true

        let row2 = UIStackView(arrangedSubviews: [
            makeTile(icon: "text.quote", title: "快捷短语", subtitle: state.phrases.isEmpty ? "暂无" : "\(state.phrases.count) 条", active: false) { [weak self] in
                self?.navigate(to: .phrases)
            },
            makeTile(icon: "sparkles", title: "按上文选词", subtitle: state.contextualEnabled ? "已开启" : "已关闭", active: state.contextualEnabled) { [weak self] in
                self?.onToggleContextual?()
            },
            makeTile(icon: "mic.fill", title: "语音工具", subtitle: state.hasStandby ? "待机中" : "语音输入", active: state.hasStandby) { [weak self] in
                guard let self else { return }
                if state.hasStandby || state.hasUninsertedVoice {
                    navigate(to: .voice)
                } else {
                    onStartVoice?()
                }
            }
        ])
        row2.distribution = .fillEqually
        row2.spacing = 8
        row2.heightAnchor.constraint(equalToConstant: 82).isActive = true

        contentStack.addArrangedSubview(row1)
        contentStack.addArrangedSubview(row2)
    }

    private func renderSchemes(_ state: State) {
        addOptionGrid(state.schemes) { [weak self] id in self?.onSelectScheme?(id) }
        if !state.communitySchemes.isEmpty {
            let label = UILabel()
            label.text = "社区方案"
            label.font = .preferredFont(forTextStyle: .caption1).withWeight(.medium)
            label.textColor = .secondaryLabel
            contentStack.addArrangedSubview(label)
            addOptionGrid(state.communitySchemes) { [weak self] id in self?.onSelectCommunityScheme?(id) }
        }
    }

    private func renderOutputForms(_ state: State) {
        addOptionGrid(state.outputForms) { [weak self] id in self?.onSelectOutputForm?(id) }
    }

    private func renderAppearance(_ state: State) {
        contentStack.addArrangedSubview(makeSegmentedRow(
            title: "键盘高度",
            items: [("紧凑", -1), ("标准", 0), ("加高", 1)],
            selected: state.heightLevel
        ) { [weak self] value in self?.onSetHeight?(value) })

        contentStack.addArrangedSubview(makeSegmentedRow(
            title: "按键字号",
            items: [("小号", -1), ("标准", 0), ("大号", 1)],
            selected: state.fontLevel
        ) { [weak self] value in self?.onSetFont?(value) })

        let bottomRow = UIStackView(arrangedSubviews: [
            makeActionChip(title: state.hapticsEnabled ? "按键触感：开" : "按键触感：关",
                           icon: "hand.tap",
                           active: state.hapticsEnabled) { [weak self] in self?.onToggleHaptics?() },
            makeActionChip(title: "恢复默认", icon: "arrow.counterclockwise", active: false) { [weak self] in
                self?.onResetAppearance?()
            }
        ])
        bottomRow.distribution = .fillEqually
        bottomRow.spacing = 8
        bottomRow.heightAnchor.constraint(equalToConstant: 40).isActive = true
        contentStack.addArrangedSubview(bottomRow)
    }

    private func renderPhrases(_ state: State) {
        let saveButton = makeActionChip(
            title: state.canSaveSelection ? "收藏当前选中文字" : "先选中文字即可收藏",
            icon: "plus.circle",
            active: state.canSaveSelection
        ) { [weak self] in self?.onSaveSelectionPhrase?() }
        saveButton.isEnabled = state.canSaveSelection
        saveButton.heightAnchor.constraint(equalToConstant: 38).isActive = true
        contentStack.addArrangedSubview(saveButton)

        if state.phrases.isEmpty {
            let empty = UILabel()
            empty.text = "暂无收藏短语"
            empty.font = .preferredFont(forTextStyle: .footnote)
            empty.textColor = .secondaryLabel
            empty.textAlignment = .center
            empty.heightAnchor.constraint(equalToConstant: 44).isActive = true
            contentStack.addArrangedSubview(empty)
        } else {
            for phrase in state.phrases {
                let row = UIStackView()
                row.spacing = 6
                let insertBtn = makeActionChip(title: phrase, icon: nil, active: false) { [weak self] in
                    self?.onInsertPhrase?(phrase)
                }
                let delBtn = UIButton(type: .system)
                delBtn.setImage(UIImage(systemName: "trash"), for: .normal)
                delBtn.tintColor = .systemRed
                delBtn.widthAnchor.constraint(equalToConstant: 36).isActive = true
                delBtn.addAction(UIAction { [weak self] _ in self?.onRemovePhrase?(phrase) }, for: .touchUpInside)
                row.addArrangedSubview(insertBtn)
                row.addArrangedSubview(delBtn)
                row.heightAnchor.constraint(equalToConstant: 38).isActive = true
                contentStack.addArrangedSubview(row)
            }
        }
    }

    private func renderVoice(_ state: State) {
        let startBtn = makeActionChip(title: "开始语音输入", icon: "mic.fill", active: true) { [weak self] in
            self?.onStartVoice?()
        }
        startBtn.heightAnchor.constraint(equalToConstant: 44).isActive = true
        contentStack.addArrangedSubview(startBtn)

        if state.hasUninsertedVoice {
            let insertBtn = makeActionChip(title: "插入上段听写", icon: "text.badge.plus", active: false) { [weak self] in
                self?.onInsertLatestVoice?()
            }
            insertBtn.heightAnchor.constraint(equalToConstant: 44).isActive = true
            contentStack.addArrangedSubview(insertBtn)
        }
        if state.hasStandby {
            let endBtn = makeActionChip(title: state.endingStandby ? "正在结束连续听写…" : "结束连续听写",
                                        icon: "power",
                                        active: false) { [weak self] in self?.onEndStandby?() }
            endBtn.isEnabled = !state.endingStandby
            endBtn.heightAnchor.constraint(equalToConstant: 44).isActive = true
            contentStack.addArrangedSubview(endBtn)
        }
    }

    private func navigate(to target: Page) {
        page = target
        if let lastState { render(lastState) }
    }

    private func makeTile(icon: String, title: String, subtitle: String, active: Bool, action: @escaping () -> Void) -> UIButton {
        let btn = UIButton(type: .custom)
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = active ? Self.activeTileColor : Self.tileColor
        config.baseForegroundColor = active ? .systemBlue : .label
        config.background.cornerRadius = 12
        config.image = UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium))
        config.imagePlacement = .top
        config.imagePadding = 6
        config.title = title
        config.subtitle = subtitle
        config.titleAlignment = .center
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attr in
            var out = attr
            out.font = .systemFont(ofSize: 13, weight: .medium)
            return out
        }
        config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attr in
            var out = attr
            out.font = .systemFont(ofSize: 11, weight: .regular)
            out.foregroundColor = active ? UIColor.systemBlue : UIColor.secondaryLabel
            return out
        }
        btn.configuration = config
        btn.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return btn
    }

    private func addOptionGrid(_ options: [Option], onSelect: @escaping (String) -> Void) {
        var index = 0
        while index < options.count {
            let row = UIStackView()
            row.distribution = .fillEqually
            row.spacing = 8
            row.heightAnchor.constraint(equalToConstant: 44).isActive = true
            for col in 0..<2 {
                if index + col < options.count {
                    let opt = options[index + col]
                    row.addArrangedSubview(makeActionChip(
                        title: opt.title,
                        icon: opt.selected ? "checkmark.circle.fill" : nil,
                        active: opt.selected
                    ) { onSelect(opt.id) })
                } else {
                    row.addArrangedSubview(UIView())
                }
            }
            contentStack.addArrangedSubview(row)
            index += 2
        }
    }

    private func makeSegmentedRow(title: String, items: [(String, Int)], selected: Int, onSelect: @escaping (Int) -> Void) -> UIView {
        let row = UIStackView()
        row.spacing = 8
        row.alignment = .center
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabel
        label.widthAnchor.constraint(equalToConstant: 64).isActive = true
        row.addArrangedSubview(label)

        let pills = UIStackView()
        pills.distribution = .fillEqually
        pills.spacing = 6
        for (name, value) in items {
            let chip = makeActionChip(title: name, icon: nil, active: value == selected) { onSelect(value) }
            pills.addArrangedSubview(chip)
        }
        pills.heightAnchor.constraint(equalToConstant: 36).isActive = true
        row.addArrangedSubview(pills)
        return row
    }

    private func makeActionChip(title: String, icon: String?, active: Bool, action: @escaping () -> Void) -> UIButton {
        let btn = UIButton(type: .custom)
        var config = UIButton.Configuration.filled()
        config.title = title
        config.image = icon.flatMap { UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)) }
        config.imagePadding = 5
        config.baseBackgroundColor = active ? Self.activeTileColor : Self.tileColor
        config.baseForegroundColor = active ? .systemBlue : .label
        config.background.cornerRadius = 10
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attr in
            var out = attr
            out.font = .systemFont(ofSize: 13, weight: active ? .semibold : .regular)
            return out
        }
        btn.configuration = config
        btn.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return btn
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

private struct KeyboardAppearance {
    enum Level: Int, CaseIterable { case small = -1, standard = 0, large = 1 }
    var height: Level = .standard
    var font: Level = .standard
    var haptics = false

    static var saved: Self {
        let defaults = UserDefaults.standard
        return Self(height: Level(rawValue: defaults.integer(forKey: "keyboardAppearance.height")) ?? .standard,
                    font: Level(rawValue: defaults.integer(forKey: "keyboardAppearance.font")) ?? .standard,
                    haptics: defaults.bool(forKey: "keyboardAppearance.haptics"))
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(height.rawValue, forKey: "keyboardAppearance.height")
        defaults.set(font.rawValue, forKey: "keyboardAppearance.font")
        defaults.set(haptics, forKey: "keyboardAppearance.haptics")
    }
}

// Store only opaque recording, result and document IDs in the extension's own sandbox.
// Exclusive creation prevents two keyboard instances from inserting one result twice.
private enum VoiceDelivery {
    private static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("YahVoiceDelivery", isDirectory: true)

    private static func file(_ prefix: String, _ id: UUID) -> URL? {
        guard let directory else { return nil }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return nil }
        return directory.appendingPathComponent(prefix + id.uuidString)
    }

    static func origin(for recording: UUID) -> UUID? {
        guard let url = file("origin-", recording), let data = try? Data(contentsOf: url),
              let value = String(data: data, encoding: .utf8) else { return nil }
        return UUID(uuidString: value)
    }

    static func latestUninserted() -> VoiceHandoff? {
        if let latest = VoiceHandoff.pending(), !wasInserted(latest.id) { return latest }
        for id in recordings(in: nil).reversed() {
            if let item = VoiceHandoff.pending(for: id), !wasInserted(item.id) { return item }
        }
        return nil
    }

    static func recordings(in document: UUID?) -> [UUID] {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        return files.compactMap { url -> (UUID, Date)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("origin-"), let id = UUID(uuidString: String(name.dropFirst(7))) else { return nil }
            if let document, (try? Data(contentsOf: url)) != Data(document.uuidString.utf8) { return nil }
            return (id, (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }.sorted { $0.1 < $1.1 }.map { $0.0 }
    }

    static func bind(_ recording: UUID, to document: UUID) -> UUID? {
        if let prior = origin(for: recording) { return prior }
        guard let url = file("origin-", recording) else { return nil }
        do {
            try Data(document.uuidString.utf8).write(to: url, options: .withoutOverwriting)
            return document
        } catch { return origin(for: recording) }
    }

    @discardableResult
    static func rebind(_ recording: UUID, to document: UUID) -> UUID? {
        guard let url = file("origin-", recording) else { return nil }
        do {
            try Data(document.uuidString.utf8).write(to: url, options: .atomic)
            return document
        } catch { return origin(for: recording) }
    }

    static func wasInserted(_ id: UUID) -> Bool {
        if UserDefaults.standard.string(forKey: "lastInsertedVoice") == id.uuidString { return true }
        return file("inserted-", id).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    static func claim(_ id: UUID) -> Bool {
        guard !wasInserted(id), let url = file("inserted-", id) else { return false }
        do { try Data().write(to: url, options: .withoutOverwriting) }
        catch { return false }
        UserDefaults.standard.set(id.uuidString, forKey: "lastInsertedVoice")
        return true
    }

    static func prune() {
        guard let directory, let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for url in urls {
            if let stamp = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate, stamp < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    struct ArmedOrigin: Codable {
        let launchID: UUID
        let document: UUID?
        let issued: Date
        let expires: Date
    }

    static func saveArmedOrigin(launchID: UUID, document: UUID?, lifetime: TimeInterval = 90) {
        guard let url = directory?.appendingPathComponent("armed-origin.json") else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let now = Date()
        let origin = ArmedOrigin(launchID: launchID, document: document, issued: now, expires: now.addingTimeInterval(lifetime))
        if let data = try? JSONEncoder().encode(origin) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func armedOrigin(for launchID: UUID) -> ArmedOrigin? {
        guard let url = directory?.appendingPathComponent("armed-origin.json"),
              let data = try? Data(contentsOf: url),
              let origin = try? JSONDecoder().decode(ArmedOrigin.self, from: data),
              origin.launchID == launchID, origin.expires > Date() else { return nil }
        return origin
    }

    static func clearArmedOrigin(_ launchID: UUID) {
        guard let url = directory?.appendingPathComponent("armed-origin.json"),
              let data = try? Data(contentsOf: url),
              let origin = try? JSONDecoder().decode(ArmedOrigin.self, from: data),
              origin.launchID == launchID else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func markCancelled(_ recording: UUID) {
        guard let url = file("cancelled-", recording) else { return }
        try? Data().write(to: url, options: .atomic)
    }

    static func wasCancelled(_ recording: UUID) -> Bool {
        file("cancelled-", recording).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }
}

extension KeyboardController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        composition.spelling.isEmpty
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

/// Personal phrases live in the keyboard's own container.
final class PhraseBook {
    private let defaults: UserDefaults
    private let key = "personalPhrases"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var entries: [String] { defaults.stringArray(forKey: key) ?? [] }

    func add(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        defaults.set([text] + entries.filter { $0 != text }, forKey: key)
    }

    func remove(_ text: String) {
        defaults.set(entries.filter { $0 != text }, forKey: key)
    }
}

private final class SymbolFlick: UISwipeGestureRecognizer {
    var symbol: Character?
}

private final class LetterButton: UIButton {
    var code: Character?
    private var neighbourPoint: CGPoint?

    func takeNeighbourPoint() -> CGPoint? {
        defer { neighbourPoint = nil }
        return neighbourPoint
    }

    override func cancelTracking(with event: UIEvent?) {
        neighbourPoint = nil
        super.cancelTracking(with: event)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let point = touch.location(in: self)
        let xMargin = min(10, bounds.width * 0.2)
        let yMargin = min(9, bounds.height * 0.2)
        // Project through the closest edge only. The real layout accounts for staggered
        // rows, wide nine-key buttons, landscape size, and adjacent non-letter controls.
        let edges: [(distance: CGFloat, beyond: CGPoint)] = [
            (point.x / xMargin, CGPoint(x: bounds.minX - 2, y: point.y)),
            ((bounds.maxX - point.x) / xMargin, CGPoint(x: bounds.maxX + 2, y: point.y)),
            (point.y / yMargin, CGPoint(x: point.x, y: bounds.minY - 2)),
            ((bounds.maxY - point.y) / yMargin, CGPoint(x: point.x, y: bounds.maxY + 2))
        ]
        let closest = edges.min { $0.distance < $1.distance }
        neighbourPoint = closest.flatMap { $0.distance < 1 ? $0.beyond : nil }
        return super.beginTracking(touch, with: event)
    }
}
