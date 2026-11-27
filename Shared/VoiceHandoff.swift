import Foundation

struct VoiceHandoff: Codable {
    let id: UUID
    let text: String
    let expires: Date
    let recordingID: UUID?

    private static func file(_ name: String = "pending-transcript.json") throws -> URL {
        guard let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.local.yah.voice"
        ) else { throw CocoaError(.fileReadNoPermission) }
        return directory.appendingPathComponent(name)
    }

    // Only the containing app issues and consumes tickets. An ordinary external link can open
    // the settings screen, but only an unused ticket from our app group can begin recording.
    static func keyboardTicket() -> UUID? {
        guard let url = try? file("keyboard-ticket"), let data = try? Data(contentsOf: url),
              let value = String(data: data, encoding: .utf8) else { return nil }
        return UUID(uuidString: value)
    }

    static func issueKeyboardTicket() throws {
        try Data(UUID().uuidString.utf8).write(to: file("keyboard-ticket"), options: [.atomic, .completeFileProtection])
    }

    @MainActor static func acceptKeyboardLink(_ url: URL) -> Bool {
        guard url.scheme == "local-yah-voice", ["start", "standby", "resume"].contains(url.host),
              let ticket = UUID(uuidString: url.lastPathComponent), ticket == keyboardTicket() else { return false }
        do { try issueKeyboardTicket(); return true }
        catch { return false }
    }

    static func publish(_ text: String, recordingID: UUID? = nil) throws {
        clearExpired()
        let item = VoiceHandoff(id: UUID(), text: text, expires: Date().addingTimeInterval(300), recordingID: recordingID)
        let data = try JSONEncoder().encode(item)
        if let recordingID {
            let folder = try file("voice-results")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
            try data.write(to: folder.appendingPathComponent(recordingID.uuidString), options: [.atomic, .completeFileProtection])
        }
        try data.write(to: file(), options: [.atomic, .completeFileProtection])
        notifyStateChanged()
    }

    static func pending() -> VoiceHandoff? {
        guard let url = try? file(), let data = try? Data(contentsOf: url),
              let item = try? JSONDecoder().decode(Self.self, from: data),
              item.expires > Date() else { return nil }
        return item
    }

    static func pending(for recording: UUID) -> VoiceHandoff? {
        guard let folder = try? file("voice-results"),
              let data = try? Data(contentsOf: folder.appendingPathComponent(recording.uuidString)),
              let item = try? JSONDecoder().decode(Self.self, from: data),
              item.recordingID == recording, item.expires > Date() else { return nil }
        return item
    }

    // Only the containing app clears the shared file. The keyboard reads it.
    static func clearExpired() {
        if let folder = try? file("voice-results"),
           let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let cutoff = Date().addingTimeInterval(-300)
            for url in urls {
                if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   date <= cutoff { try? FileManager.default.removeItem(at: url) }
            }
        }
        if pending() == nil, let url = try? file() { try? FileManager.default.removeItem(at: url) }
    }
}

extension VoiceHandoff {
    struct Preview: Codable {
        let text: String
        let levels: [Float]
        let updated: Date
    }

    struct Recording: Codable {
        let id: UUID
        let started: Date
        var updated = Date()
        var transcribing = false
        var preview: Preview?

        var currentPreview: Preview? {
            guard !transcribing, let preview, (0..<5).contains(Date().timeIntervalSince(preview.updated)) else { return nil }
            return preview
        }

        mutating func updatePreview(text: String, levels: [Float]) {
            guard !transcribing else { preview = nil; return }
            updated = Date()
            let safeLevels = levels.suffix(16).map { $0.isFinite ? min(1, max(0, $0)) : 0 }
            preview = Preview(text: String(text.suffix(120)), levels: safeLevels, updated: updated)
        }

        var stopSignal: String { "local.yah.stop." + id.uuidString }
        var cancelSignal: String { "local.yah.cancel." + id.uuidString }
    }

    static func publishRecording(_ recording: Recording) throws {
        try JSONEncoder().encode(recording).write(to: file("voice-session.json"), options: [.atomic, .completeFileProtection])
        notifyStateChanged()
    }

    static func activeRecording() -> Recording? {
        guard let url = try? file("voice-session.json"), let data = try? Data(contentsOf: url),
              let recording = try? JSONDecoder().decode(Recording.self, from: data),
              (0..<5).contains(Date().timeIntervalSince(recording.updated)) else { return nil }
        return recording
    }

    static func preview(for recording: UUID) -> Preview? {
        guard let state = activeRecording(), state.id == recording else { return nil }
        return state.currentPreview
    }

    struct Recovery: Codable {
        let recording: UUID
        let expires: Date
    }

    // Only the identifier crosses the app group. Audio stays in the containing app.
    static func publishRecovery(_ recording: UUID, expires: Date) throws {
        let data = try JSONEncoder().encode(Recovery(recording: recording, expires: expires))
        try data.write(to: file("voice-recovery.json"), options: [.atomic, .completeFileProtection])
    }

    static func recovery() -> Recovery? {
        guard let url = try? file("voice-recovery.json"), let data = try? Data(contentsOf: url),
              let job = try? JSONDecoder().decode(Recovery.self, from: data), job.expires > Date() else { return nil }
        return job
    }

    static func clearRecovery(_ id: UUID) {
        guard let url = try? file("voice-recovery.json"), let data = try? Data(contentsOf: url),
              let job = try? JSONDecoder().decode(Recovery.self, from: data), job.recording == id else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func endRecording(_ id: UUID) {
        guard let url = try? file("voice-session.json"), let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(Recording.self, from: data), state.id == id else { return }
        try? FileManager.default.removeItem(at: url)
        notifyStateChanged()
    }
}

import UserNotifications

enum VoicePrompt {
    static let identifier = "local.yah.voice.user-request"

    static func request() async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized,
              settings.alertSetting == .enabled || settings.notificationCenterSetting == .enabled else { return false }
        let content = UNMutableNotificationContent()
        content.title = "开始本次语音输入"
        content.body = "点此打开 Yah 并录音，然后返回原输入框。"
        content.userInfo = ["requestedAt": Date().timeIntervalSince1970]
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
        return true
    }

    static func recognizes(_ response: UNNotificationResponse) -> Bool {
        let request = response.notification.request
        guard request.identifier == identifier,
              response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let issued = request.content.userInfo["requestedAt"] as? TimeInterval else { return false }
        return (0..<60).contains(Date().timeIntervalSince1970 - issued)
    }
}

extension VoiceHandoff {
    static let stateNotification = "local.yah.voice.state"

    static func notifyStateChanged() {
        notify_post(stateNotification)
    }

    struct Standby: Codable {
        let id: UUID
        var expires: Date
        var updated = Date()
        var signal: String { "local.yah.voice.control." + id.uuidString }
    }

    private struct Start: Codable {
        let session: UUID
        let recording: UUID
        let issued: Date
    }

    private struct Failure: Codable {
        let id: UUID
        let message: String
        let expires: Date
    }

    static let startRequestLifetime: TimeInterval = 6

    private static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let url = try? file(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, _ name: String) throws {
        try JSONEncoder().encode(value).write(to: file(name), options: [.atomic, .completeFileProtection])
    }

    private static func withControlLock<T>(_ perform: () throws -> T) throws -> T {
        let lock = try file("voice-control.lock")
        let fd = open(lock.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(fd, LOCK_UN) }
        return try perform()
    }

    static func standby() -> Standby? {
        guard let value = read(Standby.self, "voice-standby.json"), value.expires > Date(),
              (0..<5).contains(Date().timeIntervalSince(value.updated)) else { return nil }
        return value
    }

    static func publishStandby(_ value: Standby, notify: Bool = false) throws {
        try write(value, "voice-standby.json")
        if notify { notifyStateChanged() }
    }

    static func finishStandby(_ session: Standby) {
        let removed = (try? withControlLock { () -> Bool in
            guard read(Standby.self, "voice-standby.json")?.id == session.id else { return false }
            for name in ["voice-standby.json", "voice-standby-start.json", "voice-standby-end.json", "voice-standby-retry.json", "voice-standby-armed.json"] {
                if let url = try? file(name) { try? FileManager.default.removeItem(at: url) }
            }
            return true
        }) ?? false
        if removed { notifyStateChanged() }
    }

    static func pendingStart(in session: Standby) -> UUID? {
        guard let item = read(Start.self, "voice-standby-start.json"), item.session == session.id,
              (0..<startRequestLifetime).contains(Date().timeIntervalSince(item.issued)) else { return nil }
        return item.recording
    }

    static func requestStart(in session: Standby) throws -> UUID {
        try withControlLock {
            guard standby()?.id == session.id else { throw CocoaError(.userCancelled) }
            if let id = pendingStart(in: session) { return id }
            let id = UUID()
            try write(Start(session: session.id, recording: id, issued: Date()), "voice-standby-start.json")
            notify_post(session.signal)
            return id
        }
    }

    static func clearStart(_ id: UUID) {
        try? withControlLock {
            guard read(Start.self, "voice-standby-start.json")?.recording == id else { return }
            try FileManager.default.removeItem(at: file("voice-standby-start.json"))
        }
    }

    struct Retry: Codable {
        let id: UUID
        let session: UUID
        let recording: UUID
        let issued: Date
    }

    static func requestRetry(in session: Standby, recording: UUID) throws {
        try withControlLock {
            guard standby()?.id == session.id, recovery()?.recording == recording else { throw CocoaError(.userCancelled) }
            if let existing = pendingRetry(in: session), existing.recording == recording { return }
            if let failure = read(Failure.self, "voice-failure.json"), failure.id == recording {
                try? FileManager.default.removeItem(at: file("voice-failure.json"))
            }
            try write(Retry(id: UUID(), session: session.id, recording: recording, issued: Date()), "voice-standby-retry.json")
            notify_post(session.signal)
        }
    }

    static func pendingRetry(in session: Standby) -> Retry? {
        guard let item = read(Retry.self, "voice-standby-retry.json"), item.session == session.id,
              (0..<startRequestLifetime).contains(Date().timeIntervalSince(item.issued)) else { return nil }
        return item
    }

    static func acknowledgeRetry(_ request: Retry) {
        try? withControlLock {
            if read(Retry.self, "voice-standby-retry.json")?.id == request.id {
                try FileManager.default.removeItem(at: file("voice-standby-retry.json"))
            }
        }
    }

    static func requestStandbyEnd(_ session: Standby) throws {
        try withControlLock {
            guard standby()?.id == session.id else { throw CocoaError(.userCancelled) }
            try write(session.id, "voice-standby-end.json")
            notify_post(session.signal)
        }
    }

    static func hasRequestedEnd(_ session: Standby) -> Bool {
        read(UUID.self, "voice-standby-end.json") == session.id
    }

    static func publishFailure(_ message: String, for id: UUID) {
        try? write(Failure(id: id, message: message, expires: Date().addingTimeInterval(30)), "voice-failure.json")
        notifyStateChanged()
    }

    static func failure(for id: UUID) -> String? {
        guard let item = read(Failure.self, "voice-failure.json"), item.id == id, item.expires > Date() else { return nil }
        return item.message
    }
}


extension VoiceHandoff {
    private struct ForegroundStart: Codable {
        let id: UUID
        let issued: Date
    }

    // Filled only by a microphone tap in the keyboard. It never wakes the app by itself.
    static func rememberForegroundStart() throws -> UUID {
        let request = ForegroundStart(id: UUID(), issued: Date())
        try withControlLock { try write(request, "voice-foreground-start.json") }
        return request.id
    }

    static func cancelForegroundStart(_ id: UUID) {
        try? withControlLock {
            guard read(ForegroundStart.self, "voice-foreground-start.json")?.id == id else { return }
            try FileManager.default.removeItem(at: file("voice-foreground-start.json"))
        }
    }

    @MainActor static func takeForegroundStart() -> UUID? {
        try? withControlLock {
            guard let request = read(ForegroundStart.self, "voice-foreground-start.json") else { return nil }
            try FileManager.default.removeItem(at: file("voice-foreground-start.json"))
            return (0..<15).contains(Date().timeIntervalSince(request.issued)) ? request.id : nil
        }
    }
}

extension VoiceHandoff {
    private struct StandbyLaunch: Codable {
        let id: UUID
        let issued: Date
    }

    struct ArmedStart: Codable, Equatable {
        let launchID: UUID
        let sessionID: UUID
        let readyAt: Date
        let expires: Date
    }

    static func rememberStandbyLaunch(id: UUID) throws {
        let request = StandbyLaunch(id: id, issued: Date())
        try withControlLock { try write(request, "voice-standby-launch.json") }
    }

    static func cancelStandbyLaunch(_ id: UUID) {
        try? withControlLock {
            guard read(StandbyLaunch.self, "voice-standby-launch.json")?.id == id else { return }
            try FileManager.default.removeItem(at: file("voice-standby-launch.json"))
        }
    }

    @MainActor static func takeStandbyLaunch() -> UUID? {
        try? withControlLock {
            guard let request = read(StandbyLaunch.self, "voice-standby-launch.json") else { return nil }
            try FileManager.default.removeItem(at: file("voice-standby-launch.json"))
            return (0..<30).contains(Date().timeIntervalSince(request.issued)) ? request.id : nil
        }
    }

    static func publishArmedStart(launchID: UUID, sessionID: UUID, lifetime: TimeInterval = 60) throws {
        let now = Date()
        let item = ArmedStart(launchID: launchID, sessionID: sessionID, readyAt: now, expires: now.addingTimeInterval(lifetime))
        try withControlLock { try write(item, "voice-standby-armed.json") }
        notifyStateChanged()
    }

    static func pendingArmedStart(for session: Standby) -> ArmedStart? {
        guard let item = read(ArmedStart.self, "voice-standby-armed.json"),
              item.sessionID == session.id, item.expires > Date() else { return nil }
        return item
    }

    static func consumeArmedStart(_ launchID: UUID, in session: Standby) -> ArmedStart? {
        try? withControlLock {
            guard let item = read(ArmedStart.self, "voice-standby-armed.json"),
                  item.launchID == launchID, item.sessionID == session.id, item.expires > Date() else { return nil }
            try FileManager.default.removeItem(at: file("voice-standby-armed.json"))
            return item
        }
    }

    static func clearArmedStart(sessionID: UUID? = nil) {
        try? withControlLock {
            if let sessionID {
                guard read(ArmedStart.self, "voice-standby-armed.json")?.sessionID == sessionID else { return }
            }
            try FileManager.default.removeItem(at: file("voice-standby-armed.json"))
        }
    }
}

