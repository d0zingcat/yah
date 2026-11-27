import ActivityKit
import AppIntents
import Foundation

@available(iOS 16.2, *)
struct VoiceStandbyAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case standby
            case listening
            case transcribing
        }

        var phase: Phase
        var expires: Date
        var started: Date?
        var recordingID: UUID?
    }

    let sessionID: UUID
}

@available(iOS 17.0, *)
struct StopVoiceDictationIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "停止录音"
    static var openAppWhenRun = false

    @Parameter(title: "录音")
    var recordingID: String

    init() { recordingID = "" }
    init(recordingID: UUID) { self.recordingID = recordingID.uuidString }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: recordingID),
              let recording = VoiceHandoff.activeRecording(), recording.id == id,
              !recording.transcribing else { throw CocoaError(.userCancelled) }
        guard notify_post(recording.stopSignal) == NOTIFY_STATUS_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        return .result()
    }
}

@available(iOS 17.0, *)
struct EndVoiceStandbyIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "结束待机"
    static var openAppWhenRun = false

    @Parameter(title: "待机")
    var sessionID: String

    init() { sessionID = "" }
    init(sessionID: UUID) { self.sessionID = sessionID.uuidString }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: sessionID),
              let session = VoiceHandoff.standby(), session.id == id else {
            throw CocoaError(.userCancelled)
        }
        try VoiceHandoff.requestStandbyEnd(session)
        return .result()
    }
}
