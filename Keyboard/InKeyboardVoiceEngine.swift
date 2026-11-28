import AVFAudio
import Foundation

@MainActor
final class InKeyboardVoiceEngine: NSObject, @preconcurrency AVAudioRecorderDelegate {
    enum EngineError: LocalizedError {
        case microphoneDenied
        case recordingUnavailable

        var errorDescription: String? {
            switch self {
            case .microphoneDenied:
                return "请在系统设置中允许 Yah 键盘使用麦克风。"
            case .recordingUnavailable:
                return "麦克风暂不可用，请检查权限或稍后重试。"
            }
        }
    }

    var onLevels: (([Float]) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onTimeLimit: (() -> Void)?

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var meterTimer: Timer?
    private var audioSessionActive = false
    private var levels: [Float] = []

    static var permissionsUndetermined: Bool {
        AVAudioSession.sharedInstance().recordPermission == .undetermined
    }

    static var permissionsDenied: Bool {
        AVAudioSession.sharedInstance().recordPermission == .denied
    }

    private func configuration() throws -> VoiceConfiguration {
        guard let configuration = try VoiceConfigurationStore.load(),
              !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceTranscriptionError.missingAPIKey
        }
        guard configuration.hasValidEndpoint else { throw VoiceTranscriptionError.invalidEndpoint }
        return configuration
    }

    func start() async throws {
        guard recorder == nil else { return }
        _ = try configuration()
        let session = AVAudioSession.sharedInstance()
        if session.recordPermission == .undetermined {
            let granted = await withCheckedContinuation { continuation in
                session.requestRecordPermission { continuation.resume(returning: $0) }
            }
            guard granted else { throw EngineError.microphoneDenied }
        } else if session.recordPermission != .granted {
            throw EngineError.microphoneDenied
        }
        try Task.checkCancellation()

        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .duckOthers])
            try session.setActive(true)
            audioSessionActive = true
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("yah-keyboard-\(UUID().uuidString).wav")
            fileURL = url
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            self.recorder = recorder
            levels = []
            guard recorder.record() else { throw EngineError.recordingUnavailable }
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateMeter() }
            }
        } catch {
            cancel()
            throw error
        }
    }

    func finish() async throws -> String {
        guard recorder != nil, let url = fileURL else { throw EngineError.recordingUnavailable }
        stopRecording()
        fileURL = nil
        defer { removeFile(url) }
        try releaseAudioSession()
        try Task.checkCancellation()
        let stored = try configuration()
        return try await VoiceTranscriptionProviderFactory.make(for: stored)
            .transcribe(audioURL: url, configuration: stored)
    }

    func cancel() {
        stopRecording()
        if let url = fileURL {
            removeFile(url)
            fileURL = nil
        }
        do { try releaseAudioSession() }
        catch { onFailure?(error) }
    }

    private func updateMeter() {
        guard let recorder else { return }
        guard recorder.isRecording else {
            cancel()
            onFailure?(EngineError.recordingUnavailable)
            return
        }
        if recorder.currentTime >= 120 {
            onTimeLimit?()
            return
        }
        recorder.updateMeters()
        let level = max(0.06, min(1, pow(10, recorder.averagePower(forChannel: 0) / 40)))
        levels.append(level)
        if levels.count > 16 { levels.removeFirst() }
        onLevels?(levels)
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        cancel()
        onFailure?(error ?? EngineError.recordingUnavailable)
    }

    private func stopRecording() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
    }

    private func releaseAudioSession() throws {
        guard audioSessionActive else { return }
        audioSessionActive = false
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func removeFile(_ url: URL) {
        do { try FileManager.default.removeItem(at: url) }
        catch where (error as NSError).code == NSFileNoSuchFileError { }
        catch { NSLog("无法删除临时录音：%@", error.localizedDescription) }
    }
}
