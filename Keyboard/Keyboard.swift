import SwiftUI
import UIKit

private struct KeyboardVoiceLink: View {
    let ticket: UUID?
    let recovery: UUID?
    let onRequest: () -> Bool
    let onRejected: () -> Void
    @Environment(\.openURL) private var openURL
    var body: some View {
        Button {
            guard onRequest() else { return }
            let base = recovery.map { URL(string: "local-yah-voice://resume/")!.appendingPathComponent($0.uuidString) }
                ?? URL(string: "local-yah-voice://start/")!
            openURL(base.appendingPathComponent(ticket?.uuidString ?? "setup")) { accepted in
                if !accepted { onRejected() }
            }
        } label: {
            Group {
                if recovery != nil { Text("离线重试") }
                else { Label("语音", systemImage: "mic.fill") }
            }
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .accessibilityLabel(recovery == nil ? "开始语音输入" : "离线重试上次转写")
        .accessibilityInputLabels(recovery == nil ? ["开始语音输入"] : ["离线重试", "继续上次离线转写", "继续"])
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
    private var revealedPreview: (recording: UUID, document: UUID)?
    private var voiceTimer: Timer?
    private var waitingForVoice: (recording: UUID, document: UUID)?
    private var startingVoice: (recording: UUID, document: UUID, expires: Date)?
    private var retryingVoice: (recording: UUID, document: UUID?, until: Date)?
    private var stoppingVoice: (recording: UUID, until: Date)?
    private var endingStandby: (id: UUID, document: UUID?, until: Date)?
    private var voiceMessage: (text: String, document: UUID?, until: Date)?
    private var singleSource: (document: UUID, since: Date)?
    private var foregroundStart: (id: UUID, expires: Date)?
    private var offeredSingle: (document: UUID?, until: Date)?
    private var lastDeliveryLookup: (document: UUID, latest: UUID?)?
    private var resultWaitBegan: Date?
    private let voiceStatus = UILabel()
    private weak var typingHeader: UIView?
    private let insertVoice = UIButton(type: .system)
    private let voiceTools = UIStackView()
    private let fallbackVoice = UIButton(type: .system)
    private var voiceLaunchCheck: Task<Void, Never>?
    private let voiceHint = UILabel()
    private lazy var voiceLink = UIHostingController(rootView: makeVoiceLink())

    private var recoverableRecording: UUID?

    private func makeVoiceLink() -> KeyboardVoiceLink {
        KeyboardVoiceLink(ticket: VoiceHandoff.keyboardTicket(), recovery: recoverableRecording,
                          onRequest: { [weak self] in self?.requestVoice() ?? false },
                          onRejected: { [weak self] in self?.showLaunchFallback() })
    }

    /// True allows the SwiftUI control to ask the system to open the containing app.
    private func requestVoice() -> Bool {
        let now = Date()
        guard VoiceHandoff.activeRecording() == nil else { updateVoiceHandoff(); return false }
        if let startingVoice, startingVoice.expires > now { return false }
        if let retryingVoice, retryingVoice.until > now { return false }
        if recoverableRecording != VoiceHandoff.recovery()?.recording {
            updateVoiceHandoff()
            reportVoice("语音状态已更新，请点当前语音按钮。", in: currentDocumentID)
            return false
        }
        voiceMessage = nil
        let standby = VoiceHandoff.standby()
        if let recording = recoverableRecording, hasFullAccess, let standby {
            do {
                try VoiceHandoff.requestRetry(in: standby, recording: recording)
                if waitingForVoice?.recording == recording { waitingForVoice = nil; resultWaitBegan = nil }
                retryingVoice = (recording, currentDocumentID, now.addingTimeInterval(VoiceHandoff.startRequestLifetime))
                updateVoiceHandoff()
            } catch { reportVoice("未能请求离线重试，请再点一次。", in: currentDocumentID) }
            return false
        }
        if recoverableRecording == nil, let standby, !hasFullAccess {
            let document = currentDocumentID
            if offeredSingle?.until ?? .distantPast <= now || offeredSingle?.document != document {
                offeredSingle = (document, min(standby.expires, now.addingTimeInterval(16)))
                reportVoice("请在设置 → 通用 → 键盘 → 键盘 → Yah 允许完全访问。再点语音可单次录音。", in: document)
                return false
            }
            offeredSingle = nil
        }
        if recoverableRecording == nil, hasFullAccess, let standby {
            guard let source = currentDocumentID else {
                reportVoice("请回到输入框，再点麦克风。", in: nil)
                return false
            }
            if endingStandby?.id == standby.id { return false }
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
                startingVoice = (recording, source, now.addingTimeInterval(VoiceHandoff.startRequestLifetime))
                waitingForVoice = (recording, source)
                resultWaitBegan = nil
                updateVoiceHandoff()
            } catch {
                reportVoice("未能请求录音，请再点麦克风。", in: source)
            }
            return false
        }
        if recoverableRecording == nil, hasFullAccess,
           foregroundStart.map({ $0.expires <= now }) ?? true,
           let id = try? VoiceHandoff.rememberForegroundStart() {
            foregroundStart = (id, now.addingTimeInterval(15))
        }
        if recoverableRecording == nil, let document = currentDocumentID { singleSource = (document, now) }
        else { singleSource = nil }
        voiceLaunchCheck?.cancel()
        voiceLaunchCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.showLaunchFallback()
        }
        return true
    }

    private func showLaunchFallback() {
        guard viewIfLoaded?.window != nil, VoiceHandoff.activeRecording() == nil,
              startingVoice == nil, voiceTools.isHidden else { return }
        voiceLaunchCheck?.cancel()
        fallbackVoice.sendActions(for: .touchUpInside)
    }

    private func reportVoice(_ message: String, in document: UUID?) {
        voiceMessage = (message, document, Date().addingTimeInterval(16))
        if document == nil || document == currentDocumentID {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
        updateVoiceHandoff()
    }

    private func endStandby() {
        guard hasFullAccess, let standby = VoiceHandoff.standby(), endingStandby?.id != standby.id else { return }
        do {
            try VoiceHandoff.requestStandbyEnd(standby)
            endingStandby = (standby.id, currentDocumentID, Date().addingTimeInterval(VoiceHandoff.startRequestLifetime))
            updateVoiceHandoff()
        } catch { reportVoice("未能结束连续听写，请重试。", in: currentDocumentID) }
    }

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

    private func closeCandidates() {
        guard !candidatePanel.isHidden else { return }
        candidatePanel.dismiss()
        rows.isHidden = false
        updateCandidateToggle()
    }

    private func updateCandidateToggle() {
        expandCandidates.isHidden = composition.spelling.isEmpty || !voiceTools.isHidden
        let closed = candidatePanel.isHidden
        expandCandidates.accessibilityLabel = closed ? "展开候选" : "收起候选"
        expandCandidates.setImage(UIImage(systemName: closed ? "chevron.down" : "chevron.up"), for: .normal)
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
        if let saved = UserDefaults.standard.string(forKey: "scheme"), let choice = Scheme(rawValue: saved),
           composition.useSchema(saved) { scheme = choice }
        composition.setOutputForm(outputForm)
        view.backgroundColor = .systemGray5
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
        typingHeader = header
        header.axis = .vertical
        header.isLayoutMarginsRelativeArrangement = true
        header.layoutMargins = UIEdgeInsets(top: 1, left: 8, bottom: 1, right: 8)
        let scroll = UIScrollView()
        // The toolbar is a single opaque keyboard row. System scroll-edge glass can obscure
        // the candidate glyphs on iOS 26 even when the content fits on one line.
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .systemGray5
        scroll.clipsToBounds = true
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
            suggestions.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            header.heightAnchor.constraint(equalToConstant: 52)])
        addChild(voiceLink)
        voiceLink.view.backgroundColor = .clear
        voiceLink.view.widthAnchor.constraint(equalToConstant: 74).isActive = true
        let voice = fallbackVoice
        voice.setTitle("打字", for: .normal)
        voice.accessibilityLabel = "返回打字"
        voice.isHidden = true

        let hint = voiceHint
        hint.font = .preferredFont(forTextStyle: .caption2)
        hint.numberOfLines = 2
        hint.text = "点开始后，轻点系统通知录音"
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        let paste = UIPasteControl(configuration: .init())
        paste.target = self
        paste.accessibilityLabel = "粘贴转写文字"
        voiceTools.spacing = 8
        voiceTools.alignment = .center
        voice.addAction(UIAction { [weak self, weak voice, weak hint] _ in
            guard let self else { return }
            closeCandidates()
            voiceTools.isHidden.toggle()
            updateCandidateToggle()
            header.isHidden = !voiceTools.isHidden
            voice?.isHidden = voiceTools.isHidden
            updateVoiceHandoff()
            if voiceTools.isHidden {
                if let start = foregroundStart { VoiceHandoff.cancelForegroundStart(start.id) }
                foregroundStart = nil
                singleSource = nil
                return
            }
            if recoverableRecording != nil {
                hint?.text = "请打开 Yah，点「继续上次离线转写」。"
                UIAccessibility.post(notification: .announcement, argument: hint?.text)
                return
            }
            hint?.text = foregroundStart.map { $0.expires > Date() } == true
                ? "现在打开 Yah 即可录音。" : "正在尝试用通知打开 Yah…"
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let sent = try await VoicePrompt.request()
                    guard !voiceTools.isHidden else { return }
                    if foregroundStart.map({ $0.expires > Date() }) == true { hint?.text = "现在打开 Yah 即可录音。" }
                    else { hint?.text = sent ? "轻点 Yah 通知开始录音" : "请打开 Yah，点「开始跨应用语音输入」，再返回这里。" }
                } catch {
                    guard !voiceTools.isHidden else { return }
                    hint?.text = foregroundStart.map { $0.expires > Date() } == true
                        ? "现在打开 Yah 即可录音。" : "请打开 Yah，点「开始跨应用语音输入」，再返回这里。"
                }
                UIAccessibility.post(notification: .announcement, argument: hint?.text)
            }
        }, for: .touchUpInside)
        voiceTools.addArrangedSubview(hint)
        voiceTools.addArrangedSubview(paste)
        voiceTools.isHidden = true
        insertVoice.setTitle("插入转写", for: .normal)
        insertVoice.accessibilityLabel = "插入转写"
        insertVoice.addAction(UIAction { [weak self] _ in
            if let item = VoiceHandoff.pending() { self?.insertPendingVoice(item) }
        }, for: .touchUpInside)
        stopVoice.tintColor = .systemRed
        stopVoice.setImage(UIImage(systemName: "stop.fill"), for: .normal)
        stopVoice.titleLabel?.font = .preferredFont(forTextStyle: .callout)
        stopVoice.titleLabel?.adjustsFontForContentSizeCategory = true
        stopVoice.titleLabel?.adjustsFontSizeToFitWidth = true
        stopVoice.isHidden = true
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
        expandCandidates.widthAnchor.constraint(equalToConstant: 34).isActive = true
        expandCandidates.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            if candidatePanel.isHidden {
                rows.isHidden = true
                candidatePanel.show()
                updateCandidateToggle()
            } else { closeCandidates() }
        }, for: .touchUpInside)
        let toolbar = UIStackView(arrangedSubviews: [header, expandCandidates, voiceTools, recordingPreview, stopVoice, insertVoice, voice, voiceLink.view!])
        let previewWidth = recordingPreview.widthAnchor.constraint(equalTo: toolbar.widthAnchor, multiplier: 0.40)
        previewWidth.priority = .defaultHigh
        previewWidth.isActive = true
        toolbar.heightAnchor.constraint(equalToConstant: 52).isActive = true
        stack.addArrangedSubview(toolbar)
        voiceStatus.font = .preferredFont(forTextStyle: .caption1)
        voiceStatus.textAlignment = .center
        voiceStatus.textColor = .label
        voiceStatus.numberOfLines = 2
        voiceStatus.isHidden = true
        voiceStatus.accessibilityIdentifier = "voice-request-status"
        stack.addArrangedSubview(voiceStatus)
        voiceLink.didMove(toParent: self)

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
            if let document = VoiceDelivery.origin(for: session.id) ?? currentDocumentID,
               let origin = VoiceDelivery.bind(session.id, to: document) {
                waitingForVoice = (session.id, origin)
                resultWaitBegan = nil
            }
        } else { reportVoice("未能请求停止录音，请重试。", in: currentDocumentID) }
        updateVoiceHandoff()
    }

    private func updateVoiceHandoff() {
        let now = Date()
        let document = currentDocumentID
        if let start = foregroundStart, start.expires <= now {
            foregroundStart = nil
            if !voiceTools.isHidden { voiceHint.text = "请打开 Yah，点「开始跨应用语音输入」，再返回这里。" }
        }
        let session = VoiceHandoff.activeRecording()
        let pending = VoiceHandoff.pending()
        let standby = hasFullAccess ? VoiceHandoff.standby() : nil

        if let retry = retryingVoice {
            if (session?.id == retry.recording && session?.transcribing == true) || pending?.recordingID == retry.recording {
                retryingVoice = nil
            } else if retry.until <= now {
                retryingVoice = nil
                voiceMessage = (VoiceHandoff.failure(for: retry.recording) ?? "Yah 未确认离线重试，请再点一次。",
                                retry.document, now.addingTimeInterval(16))
            }
        }
        if session == nil, retryingVoice == nil, startingVoice == nil, waitingForVoice == nil,
           let standby, let request = VoiceHandoff.pendingStart(in: standby), let document,
           VoiceDelivery.origin(for: request) == document, VoiceHandoff.failure(for: request) == nil,
           pending?.recordingID != request {
            startingVoice = (request, document, now.addingTimeInterval(VoiceHandoff.startRequestLifetime))
            waitingForVoice = (request, document)
        }
        if let session {
            foregroundStart = nil
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
            if !voiceTools.isHidden {
                voiceTools.isHidden = true
                typingHeader?.isHidden = false
                fallbackVoice.isHidden = true
                updateCandidateToggle()
            }
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
        if let stopping = stoppingVoice, stopping.recording != session?.id || stopping.until <= now {
            stoppingVoice = nil
        }
        if let message = voiceMessage, message.until <= now { voiceMessage = nil }
        var status: String?
        if let ending = endingStandby, ending.document == document { status = "正在请求结束连续听写…" }
        else if let retry = retryingVoice, retry.document == document { status = "正在请求离线重试…" }
        else if let starting = startingVoice, starting.document == document { status = "正在请求 Yah 开始录音…" }
        else if let message = voiceMessage, message.document == nil || message.document == document { status = message.text }
        else if session == nil, resultWaitBegan != nil, waitingForVoice?.document == document { status = "正在等待转写结果…" }
        voiceStatus.text = status
        voiceStatus.isHidden = status == nil

        let recovery = session == nil ? VoiceHandoff.recovery()?.recording : nil
        if recoverableRecording != recovery {
            recoverableRecording = recovery
            voiceLink.rootView = makeVoiceLink()
        }
        voiceLink.view.isHidden = session != nil || !voiceTools.isHidden
        voiceLink.view.isUserInteractionEnabled = startingVoice == nil && retryingVoice == nil && endingStandby == nil
        stopVoice.isHidden = session == nil
        if revealedPreview?.recording != session?.id || revealedPreview?.document != document { revealedPreview = nil }
        if let session {
            let stopping = stoppingVoice?.recording == session.id
            let capturing = !session.transcribing && !stopping
            stopVoice.setTitle(session.transcribing ? " 转写中" : stopping ? " 停止中" : " 停止", for: .normal)
            stopVoice.isEnabled = capturing
            stopVoice.accessibilityLabel = session.transcribing ? "正在转写" : stopping ? "正在停止" : "停止录音并输入"
            if capturing {
                let snapshot = session.currentPreview
                let origin = waitingForVoice?.recording == session.id ? waitingForVoice?.document : nil
                let visible = document != nil && (origin == document || (origin == nil && revealedPreview?.recording == session.id))
                let canReveal = origin == nil && document != nil && !visible && snapshot?.text.isEmpty == false
                recordingPreview.show(text: visible ? snapshot?.text : nil, levels: snapshot?.levels ?? [],
                                      seconds: max(0, Int(now.timeIntervalSince(session.started))), canReveal: canReveal)
            } else { recordingPreview.clear() }
        } else { recordingPreview.clear() }

        // A newer result from another field can replace the shared latest pointer.
        // Scan the extension's opaque origin IDs only on a field or result change.
        if let document, viewIfLoaded?.window != nil,
           lastDeliveryLookup?.document != document || lastDeliveryLookup?.latest != pending?.id {
            lastDeliveryLookup = (document, pending?.id)
            for recording in VoiceDelivery.recordings(in: document) where recording != session?.id {
                guard let saved = VoiceHandoff.pending(for: recording), !VoiceDelivery.wasInserted(saved.id) else { continue }
                insertPendingVoice(saved)
            }
        }
        guard let item = pending, session?.id != item.recordingID || session == nil,
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
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        lastDeliveryLookup = nil
        voiceTimer?.invalidate()
        voiceTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateVoiceHandoff() }
        }
        voiceLink.rootView = makeVoiceLink()
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

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        recordingPreview.clear()
        revealedPreview = nil
        contextualRanking?.clear()
        composition.updateContextualOrder(nil)
        closeCandidates()
        voiceLaunchCheck?.cancel()
        voiceLaunchCheck = nil
        voiceTimer?.invalidate()
        voiceTimer = nil
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
            row.distribution = .fillEqually
            let last = index == lines.count - 1
            if last && !symbols && !nineKeys {
                row.addArrangedSubview(button(shifted ? "⬆" : "⇧", style: .control) {
                    $0.shifted.toggle()
                    $0.rebuild()
                })
            }
            for key in line {
                if nineKeys, let digit = key.wholeNumberValue {
                    if digit == 1 {
                        row.addArrangedSubview(button("分词", style: .control) {
                            if !$0.composition.spelling.isEmpty { $0.composition.append("'") }
                        })
                    } else {
                        let code = Character(UnicodeScalar(65 + digit - 2)!)
                        row.addArrangedSubview(letterButton(title: groups[digit - 2], code: code))
                    }
                    continue
                }
                if communityID == nil && !english && !shifted && !symbols && key.isLetter {
                    let cap = letterButton(title: String(key), code: key)
                    addFlickSymbol(to: cap, letter: key)
                    row.addArrangedSubview(cap)
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
                row.addArrangedSubview(cap)
            }
            if last && !nineKeys {
                let delete = button("⌫", style: .control) { keyboard in
                    if keyboard.composition.spelling.isEmpty { keyboard.textDocumentProxy.deleteBackward() }
                    else { keyboard.composition.backspace() }
                }
                delete.accessibilityLabel = "退格"
                row.addArrangedSubview(delete)
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
        controls.addArrangedSubview(button(symbols ? "ABC" : "123", style: .control) {
            if !$0.isEnteringCode { $0.finishComposition() }
            $0.symbols.toggle()
            $0.shifted = false
            $0.rebuild()
        })
        controls.addArrangedSubview(button(english ? "中" : "英", style: .control) {
            $0.finishComposition()
            $0.english.toggle()
            $0.symbols = false
            $0.shifted = false
            $0.rebuild()
        })
        let punctuation = field == .emailAddress ? "@" : (field == .URL ? "/" : (english ? "," : "，"))
        controls.addArrangedSubview(button(punctuation, style: .control) {
            $0.finishComposition()
            $0.textDocumentProxy.insertText(punctuation)
        })
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
        let space = button(english ? "space" : "空格", style: .space) { $0.insert(defaultText: " ") }
        let drag = UILongPressGestureRecognizer(target: self, action: #selector(moveCursor(_:)))
        drag.delegate = self
        space.addGestureRecognizer(drag)
        controls.addArrangedSubview(space)
        let enter = button("回车", style: .accent) { $0.insert(defaultText: "\n") }
        enterKey = enter
        controls.addArrangedSubview(enter)
        enter.widthAnchor.constraint(equalTo: controls.widthAnchor, multiplier: layout == .compact ? 0.24 : 0.16).isActive = true
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

    private func finishComposition() {
        while !composition.spelling.isEmpty {
            let pending = composition.spelling
            let preview = composition.displaySpelling
            if let selected = composition.select(0) {
                textDocumentProxy.insertText(selected)
            }
            if composition.spelling == pending && composition.displaySpelling == preview {
                textDocumentProxy.insertText(preview)
                composition.clear()
            }
        }
    }

    private func updateReturnTitle() {
        let titles: [UIReturnKeyType: String] = [.send: "发送", .search: "搜索", .done: "完成",
            .go: "前往", .next: "下一项", .join: "加入", .continue: "继续"]
        enterKey?.configuration?.title = composition.spelling.isEmpty
            ? titles[textDocumentProxy.returnKeyType ?? .default, default: "回车"] : "确认"
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
        config.baseForegroundColor = style == .accent ? .white : .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 1, bottom: 0, trailing: 1)
        let font = keyFont(style)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var result = attributes
            result.font = font
            return result
        }
        // Only inset the painted cap. The button occupies the entire cell.
        config.background.cornerRadius = 6
        config.background.backgroundInsets = NSDirectionalEdgeInsets(top: 3, leading: 2, bottom: 3, trailing: 2)
        let color: UIColor
        switch style {
        case .letter, .space: color = .systemBackground
        case .control: color = .systemGray3
        case .accent: color = .systemIndigo
        case .candidate:
            color = .clear
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 9, bottom: 0, trailing: 9)
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

    private func phraseButton() -> UIButton {
        let key = styledButton("短语", style: .candidate)
        key.accessibilityLabel = "快捷短语"
        key.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] complete in
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
        key.showsMenuAsPrimaryAction = true
        return key
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

    private func refresh() {
        // The expanded panel keeps the order and absolute indices of the rows already on screen.
        if candidatePanel.isHidden { updateContextualOrder() }
        if composition.spelling.isEmpty { closeCandidates() }
        updateCandidateToggle()
        updateReturnTitle()
        let displayed = composition.displaySpelling
        spelling.text = nineKeys ? displayed.map { key in
            guard let ascii = key.asciiValue, (65...72).contains(ascii) else { return String(key) }
            return String(ascii - 63)
        }.joined() : displayed
        spelling.isHidden = spelling.text?.isEmpty != false
        suggestions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if !composition.spelling.isEmpty {
            suggestions.addArrangedSubview(button("分词") { $0.composition.append("'") })
        } else {
            let mode = styledButton(schemeTitle + effectiveOutputForm.suffix, style: .candidate)
            let schemes = Scheme.allCases.map { choice in
                UIAction(title: choice.title, state: communityID == nil && choice == scheme ? .on : .off) { [weak self] _ in
                    guard let self, YahRimeSession.configure(), composition.useSchema(choice.rawValue) else { return }
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
                    rebuild()
                    refresh()
                }
            }
            let forms: [RimeOutputForm] = communityID == nil ? RimeOutputForm.allCases : [.simplified, .traditional]
            let convert = UIMenu(title: "输出字形", children: forms.map { form in
                UIAction(title: form.title, state: form == effectiveOutputForm ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    outputForm = form
                    composition.setOutputForm(form)
                    form.save()
                    refresh()
                }
            })
            var actions: [UIMenuElement] = schemes
            if let library = communityLibrary {
                let imported = library.schemes.map { entry in
                    UIAction(title: entry.name, state: entry.id == communityID ? .on : .off) { [weak self] _ in
                        guard let self, activateCommunity(entry.id) else { return }
                        rebuild()
                        refresh()
                    }
                }
                actions.append(UIMenu(title: "社区方案", options: .displayInline, children: imported))
            }
            let tools = UIAction(title: "语音工具", image: UIImage(systemName: "mic")) { [weak self] _ in
                self?.fallbackVoice.sendActions(for: .touchUpInside)
            }
            let contextual = UIAction(title: "按上文选词", state: contextualRanking == nil ? .off : .on) {
                [weak self] _ in
                guard let self else { return }
                let enabled = contextualRanking == nil
                UserDefaults.standard.set(enabled, forKey: Self.contextPreference)
                if enabled { enableContextualRanking() }
                else { contextualRanking = nil }
                refresh()
            }
            contextual.subtitle = "简体全拼 · 本机处理"
            let voiceActions = UIDeferredMenuElement.uncached { [weak self] complete in
                guard let self else { complete([]); return }
                var items: [UIMenuElement] = []
                if let document = currentDocumentID, let result = VoiceDelivery.latestUninserted() {
                    let id = result.id, recording = result.recordingID
                    let insert = UIAction(title: "插入上段听写", image: UIImage(systemName: "text.badge.plus")) { [weak self] _ in
                        guard let self, currentDocumentID == document,
                              let item = recording.flatMap(VoiceHandoff.pending(for:)) ?? VoiceHandoff.pending(),
                              item.id == id else { return }
                        insertPendingVoice(item, explicitlyHere: true)
                    }
                    insert.subtitle = "插入到当前输入框"
                    items.append(insert)
                }
                if hasFullAccess, let standby = VoiceHandoff.standby() {
                    let pending = endingStandby?.id == standby.id
                    items.append(UIAction(title: pending ? "正在结束连续听写…" : "结束连续听写",
                                          attributes: pending ? .disabled : []) { [weak self] _ in self?.endStandby() })
                }
                complete(items)
            }
            mode.menu = UIMenu(children: [voiceActions] + actions + [convert, appearanceMenu(), contextual, tools])
            mode.showsMenuAsPrimaryAction = true
            suggestions.addArrangedSubview(mode)
            suggestions.addArrangedSubview(phraseButton())
            for mark in (english ? [".", "?", "!", "-", "_"] : ["。", "？", "！", "、", "……"]) {
                suggestions.addArrangedSubview(button(mark) { $0.textDocumentProxy.insertText(mark) })
            }
        }
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
        // At accessibility text sizes, the draft takes the row. VoiceOver still reads the time and level.
        elapsed.superview?.isHidden = !draft.isHidden && traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        elapsed.text = time
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
        meter.show([], reduceMotion: true)
    }
}

private final class KeyboardLevelMeter: UIView {
    private var levels: [Float] = []
    private var reduceMotion = false
    var levelDescription: String {
        guard let level = levels.last else { return "尚无音量数据" }
        if level < 0.05 { return "安静" }
        return level < 0.5 ? "音量较低" : "音量较高"
    }

    func show(_ samples: [Float], reduceMotion: Bool) {
        guard levels != samples || self.reduceMotion != reduceMotion else { return }
        levels = samples
        self.reduceMotion = reduceMotion
        setNeedsDisplay()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isAccessibilityElement = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        let mid = bounds.midY
        UIColor.tertiaryLabel.setFill()
        UIBezierPath(roundedRect: CGRect(x: 0, y: mid - 0.5, width: bounds.width, height: 1), cornerRadius: 0.5).fill()
        guard !levels.isEmpty else { return }
        UIColor.label.setFill()
        if reduceMotion {
            let band = (CGFloat(levels.last ?? 0) * 4).rounded() / 4
            UIBezierPath(roundedRect: CGRect(x: 0, y: mid - 2, width: bounds.width * band, height: 4), cornerRadius: 2).fill()
        } else {
            let slot = bounds.width / 16
            for (index, level) in levels.suffix(16).reversed().enumerated() {
                let height = max(2, CGFloat(level) * bounds.height)
                let width = min(3.5, max(1, slot - 1))
                let x = bounds.maxX - (CGFloat(index) + 0.5) * slot - width / 2
                UIBezierPath(roundedRect: CGRect(x: x, y: mid - height / 2, width: width, height: height), cornerRadius: width / 2).fill()
            }
        }
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
}

extension KeyboardController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        composition.spelling.isEmpty
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
