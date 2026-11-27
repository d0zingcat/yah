import AVFAudio
import Darwin
import Foundation

enum VoiceRecorderError: LocalizedError {
    case permissionDenied
    case recordingUnavailable
    case noRecording
    case standbyEnded

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "请在系统设置中允许 Yah 使用麦克风。"
        case .recordingUnavailable:
            "麦克风暂时不可用。"
        case .noRecording:
            "没有可转写的录音。"
        case .standbyEnded:
            "连续听写已结束，本段录音已丢弃。"
        }
    }
}

// Only an explicit segment owns a file and a converter. The tap consumes no samples while idle.
private final class StandbyCapture: @unchecked Sendable {
    enum Boundary { case expired, segmentLimit(UUID), failed(UUID) }

    private final class Segment {
        let id = UUID()
        let openedAt = mach_absolute_time()
        let limit: TimeInterval
        let url: URL
        let converter: AVAudioConverter
        let output: AVAudioFormat
        var file: AVAudioFile?
        var stopped = false
        var failed = false
        var frames: AVAudioFramePosition = 0

        init(input: AVAudioFormat, maximum: TimeInterval, url: URL, settings: [String: Any]) throws {
            guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: input, to: output) else { throw VoiceRecorderError.recordingUnavailable }
            self.url = url
            self.output = output
            self.converter = converter
            self.limit = ProcessInfo.processInfo.systemUptime + maximum
            self.file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }

        func append(_ buffer: AVAudioPCMBuffer) throws {
            let needed = ceil(Double(buffer.frameLength) * output.sampleRate / buffer.format.sampleRate)
            guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(needed) + 256) else {
                throw VoiceRecorderError.recordingUnavailable
            }
            var used = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                if used { state.pointee = .noDataNow; return nil }
                used = true
                state.pointee = .haveData
                return buffer
            }
            guard status != .error && error == nil else { throw VoiceRecorderError.recordingUnavailable }
            if converted.frameLength > 0 {
                try file?.write(from: converted)
                frames += AVAudioFramePosition(converted.frameLength)
            }
        }

        func finish() throws {
            guard frames > 0, let tail = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 512) else {
                throw VoiceRecorderError.noRecording
            }
            // Flush samples retained in the sample-rate converter before closing the file.
            while true {
                tail.frameLength = 0
                var error: NSError?
                let status = converter.convert(to: tail, error: &error) { _, state in
                    state.pointee = .endOfStream
                    return nil
                }
                guard status != .error && error == nil else { throw VoiceRecorderError.recordingUnavailable }
                if tail.frameLength > 0 { try file?.write(from: tail) }
                if status == .endOfStream || tail.frameLength == 0 { break }
            }
            file = nil
        }
    }

    private let lock = NSLock()
    private let input: AVAudioFormat
    private var limit: TimeInterval
    private var notifiedExpiry = false
    private var current: Segment?

    init(input: AVAudioFormat, duration: TimeInterval) {
        self.input = input
        self.limit = ProcessInfo.processInfo.systemUptime + duration
    }

    func extend(by duration: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        guard !notifiedExpiry, now < limit else { return false }
        limit = now + duration
        return true
    }

    func begin(url: URL, settings: [String: Any], maximum: TimeInterval) throws -> UUID {
        lock.lock()
        defer { lock.unlock() }
        guard current == nil, ProcessInfo.processInfo.systemUptime < limit else { throw VoiceRecorderError.recordingUnavailable }
        let segment = try Segment(input: input, maximum: maximum, url: url, settings: settings)
        current = segment
        return segment.id
    }

    func install(on node: AVAudioInputNode, report: @escaping @Sendable (Boundary) -> Void) {
        node.installTap(onBus: 0, bufferSize: 1024, format: nil) { [self] buffer, time in
            if let boundary = receive(buffer, at: time) { report(boundary) }
        }
    }

    func receive(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) -> Boundary? {
        lock.lock()
        defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        if now >= limit {
            guard !notifiedExpiry else { return nil }
            notifiedExpiry = true
            return .expired
        }
        guard let current, !current.stopped else { return nil }
        if now >= current.limit {
            current.stopped = true
            return .segmentLimit(current.id)
        }
        // A hardware buffer delivered after the button tap can begin before it.
        guard time.isHostTimeValid, time.hostTime >= current.openedAt else { return nil }
        do { try current.append(buffer) }
        catch {
            current.stopped = true
            current.failed = true
            return .failed(current.id)
        }
        return nil
    }

    func matches(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return current?.id == id
    }

    func end(keeping: Bool) -> Result<URL, Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard let segment = current else { return nil }
        current = nil
        do {
            guard keeping else { throw VoiceRecorderError.standbyEnded }
            guard !segment.failed else { throw VoiceRecorderError.recordingUnavailable }
            try segment.finish()
            return .success(segment.url)
        } catch {
            segment.file = nil
            try? FileManager.default.removeItem(at: segment.url)
            return .failure(error)
        }
    }
}

@MainActor
final class VoiceRecorder: NSObject {
    static let maximumDuration: TimeInterval = 5 * 60

    var didFinish: ((Result<URL, Error>) -> Void)?
    var didCancelFromKeyboard: (() -> Void)?

    private var keyboardSession: VoiceHandoff.Recording?
    private var stopToken: Int32?
    private var cancelToken: Int32?
    private var heartbeat: Timer?

    func connectKeyboard(id: UUID = UUID()) throws {
        if let existing = keyboardSession {
            guard existing.id == id else { throw VoiceRecorderError.recordingUnavailable }
            return
        }
        let session = VoiceHandoff.Recording(id: id, started: Date())
        var token: Int32 = 0
        guard notify_register_dispatch(session.stopSignal, &token, .main, { [weak self] _ in
            guard let self, self.keyboardSession?.id == session.id else { return }
            self.stop()
        }) == NOTIFY_STATUS_OK else { throw VoiceRecorderError.recordingUnavailable }
        var cToken: Int32 = 0
        guard notify_register_dispatch(session.cancelSignal, &cToken, .main, { [weak self] _ in
            guard let self, self.keyboardSession?.id == session.id else { return }
            if let handler = self.didCancelFromKeyboard { handler() }
            else { self.cancel() }
        }) == NOTIFY_STATUS_OK else {
            notify_cancel(token)
            throw VoiceRecorderError.recordingUnavailable
        }
        stopToken = token
        cancelToken = cToken
        keyboardSession = session
        do { try VoiceHandoff.publishRecording(session) }
        catch { disconnectKeyboard(); throw error }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, var current = self.keyboardSession else { return }
                current.updated = Date()
                try? VoiceHandoff.publishRecording(current)
            }
        }
    }

    var keyboardSessionID: UUID? { keyboardSession?.id }

    func markTranscribing() {
        keyboardSession?.transcribing = true
        if let session = keyboardSession { try? VoiceHandoff.publishRecording(session) }
    }

    func disconnectKeyboard() {
        if let token = stopToken { notify_cancel(token) }
        stopToken = nil
        if let token = cancelToken { notify_cancel(token) }
        cancelToken = nil
        heartbeat?.invalidate()
        heartbeat = nil
        if let session = keyboardSession { VoiceHandoff.endRecording(session.id) }
        keyboardSession = nil
    }

    private var recorder: AVAudioRecorder?

    private var previewConfiguration: ((String, [Float]) -> Void)?
    private var levelTask: Task<Void, Never>?
    private var previewDraft = ""
    private var previewLevels: [Float] = []
    private var previewID = UUID()

    /// Live level bars read from the unfinished WAV.
    func configurePreview(handler: @escaping (String, [Float]) -> Void) {
        previewConfiguration = handler
    }

    private func pushPreview() {
        guard let handler = previewConfiguration else { return }
        handler(previewDraft, previewLevels)
        if var session = keyboardSession {
            session.updatePreview(text: previewDraft, levels: previewLevels)
            keyboardSession = session
            try? VoiceHandoff.publishRecording(session)
        }
    }

    private func startPreview(url: URL) {
        stopPreview()
        guard previewConfiguration != nil else { return }
        let id = UUID()
        previewID = id
        previewDraft = ""
        previewLevels = []
        let reader = RecordingPreview(recording: url)
        levelTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self, self.previewID == id else { break }
                guard let levels = await reader.levels(barCount: 16) else { continue }
                guard !Task.isCancelled, self.previewID == id else { break }
                self.previewLevels = levels
                self.pushPreview()
            }
        }
    }

    private func stopPreview() {
        levelTask?.cancel()
        levelTask = nil
        previewDraft = ""
        previewLevels = []
    }

    private static let standbyDuration: TimeInterval = 10 * 60
    private(set) var standbyDeadline: Date?
    var standbyDidEnd: (() -> Void)?
    private var engine: AVAudioEngine?
    private var capture: StandbyCapture?
    private var deadlineTimer: Timer?
    private var segmentTimer: Timer?
    private var configurationObserver: NSObjectProtocol?
    private var pendingStart: UUID?
    private var pendingStandby: UUID?

    private static var newFile: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("yah-voice-\(UUID().uuidString).wav")
    }

    private static let wavSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM), AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsFloatKey: false
    ]

    private func activateAudio(forStandby: Bool = false) throws {
        let session = AVAudioSession.sharedInstance()
        do {
            if forStandby {
                try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .allowBluetoothHFP])
            } else {
                try session.setCategory(.record, mode: .measurement, options: [])
            }
            try session.setActive(true)
        } catch { throw VoiceRecorderError.recordingUnavailable }
    }

    func enableStandby() async throws {
        if let deadline = standbyDeadline, deadline > Date() { return }
        guard recorder == nil, pendingStart == nil, pendingStandby == nil else { throw VoiceRecorderError.recordingUnavailable }
        if capture != nil { endStandby(keeping: true) }
        let request = UUID()
        pendingStandby = request
        defer { if pendingStandby == request { pendingStandby = nil } }
        let granted = await requestPermission()
        try Task.checkCancellation()
        guard pendingStandby == request else { throw CancellationError() }
        guard granted else { throw VoiceRecorderError.permissionDenied }
        try activateAudio(forStandby: true)
        let session = AVAudioSession.sharedInstance()
        guard session.isInputAvailable, !session.currentRoute.inputs.isEmpty,
              session.inputNumberOfChannels > 0, session.sampleRate.isFinite, session.sampleRate > 0 else {
            deactivateAudio()
            throw VoiceRecorderError.recordingUnavailable
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard hardware.sampleRate.isFinite, hardware.sampleRate > 0, hardware.channelCount > 0,
              format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            deactivateAudio()
            throw VoiceRecorderError.recordingUnavailable
        }
        let capture = StandbyCapture(input: format, duration: Self.standbyDuration)
        capture.install(on: input) { [weak self, weak capture] boundary in
            Task { @MainActor in
                guard let self, let capture, self.capture === capture else { return }
                switch boundary {
                case .expired: self.endStandby(keeping: true)
                case .segmentLimit(let id): if capture.matches(id) { self.stop() }
                case .failed(let id): if capture.matches(id) { self.fail() }
                }
            }
        }
        do { try engine.start() }
        catch {
            input.removeTap(onBus: 0)
            deactivateAudio()
            throw VoiceRecorderError.recordingUnavailable
        }
        self.engine = engine
        self.capture = capture
        standbyDeadline = Date().addingTimeInterval(Self.standbyDuration)
        scheduleDeadlineTimer(for: capture)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.capture === capture else { return }
                self.disableStandby()
            }
        }
    }

    func disableStandby() {
        pendingStandby = nil
        endStandby(keeping: false)
    }

    @discardableResult
    func extendStandby() -> Date? {
        guard let capture, capture.extend(by: Self.standbyDuration) else { return nil }
        let next = Date().addingTimeInterval(Self.standbyDuration)
        standbyDeadline = next
        scheduleDeadlineTimer(for: capture)
        return next
    }

    private func scheduleDeadlineTimer(for capture: StandbyCapture) {
        deadlineTimer?.invalidate()
        deadlineTimer = Timer.scheduledTimer(withTimeInterval: Self.standbyDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.capture === capture else { return }
                self.endStandby(keeping: true)
            }
        }
    }

    private func endStandby(keeping: Bool) {
        guard let capture, let engine else { return }
        self.capture = nil
        self.engine = nil
        standbyDeadline = nil
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        if let observer = configurationObserver { NotificationCenter.default.removeObserver(observer) }
        configurationObserver = nil
        segmentTimer?.invalidate()
        segmentTimer = nil
        stopPreview()
        let result = capture.end(keeping: keeping)
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        deactivateAudio()
        if let result { didFinish?(result) }
        standbyDidEnd?()
    }

    private func deactivateAudio() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func start() async throws {
        try Task.checkCancellation()
        guard recorder == nil, pendingStart == nil, pendingStandby == nil else { throw VoiceRecorderError.recordingUnavailable }
        let url = Self.newFile
        if let capture {
            guard let deadline = standbyDeadline, deadline > Date() else {
                endStandby(keeping: true)
                throw VoiceRecorderError.recordingUnavailable
            }
            do {
                let id = try capture.begin(url: url, settings: Self.wavSettings, maximum: Self.maximumDuration)
                startPreview(url: url)
                segmentTimer = Timer.scheduledTimer(withTimeInterval: Self.maximumDuration, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.capture === capture, capture.matches(id) else { return }
                        self.stop()
                    }
                }
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            return
        }
        let request = UUID()
        pendingStart = request
        defer { if pendingStart == request { pendingStart = nil } }
        let granted = await requestPermission()
        try Task.checkCancellation()
        guard pendingStart == request else { throw CancellationError() }
        guard granted else { throw VoiceRecorderError.permissionDenied }
        try activateAudio()
        do {
            let audioRecorder = try AVAudioRecorder(url: url, settings: Self.wavSettings)
            audioRecorder.delegate = self
            guard audioRecorder.record(forDuration: Self.maximumDuration) else {
                throw VoiceRecorderError.recordingUnavailable
            }
            recorder = audioRecorder
            startPreview(url: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            deactivateAudio()
            throw VoiceRecorderError.recordingUnavailable
        }
    }

    func stop() {
        stopPreview()
        segmentTimer?.invalidate()
        segmentTimer = nil
        if let capture {
            if let result = capture.end(keeping: true) { didFinish?(result) }
            return
        }
        guard let url = releaseRecording() else { return }
        didFinish?(.success(url))
    }

    func cancel() {
        stopPreview()
        pendingStart = nil
        segmentTimer?.invalidate()
        segmentTimer = nil
        if let capture { _ = capture.end(keeping: false); return }
        if let url = releaseRecording() { try? FileManager.default.removeItem(at: url) }
    }

    private func releaseRecording() -> URL? {
        guard let current = recorder else { return nil }
        recorder = nil
        current.delegate = nil
        current.stop()
        deactivateAudio()
        return current.url
    }

    private func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

extension VoiceRecorder: @preconcurrency AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        guard self.recorder === recorder else { return }
        if flag { stop() }
        else { fail() }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        guard self.recorder === recorder else { return }
        fail()
    }

    func fail() {
        if capture != nil || pendingStandby != nil { disableStandby(); return }
        guard recorder != nil else { return }
        cancel()
        didFinish?(.failure(VoiceRecorderError.recordingUnavailable))
    }
}

/// Reads the trailing PCM of an unfinished 16 kHz mono WAV to draw level bars.
private actor RecordingPreview {
    private let url: URL
    private var dataOffset: UInt64?

    init(recording url: URL) { self.url = url }

    private func pcmOffset() -> UInt64? {
        if let dataOffset { return dataOffset }
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, kAudioFileWAVEType, &file) == noErr,
              let file else { return nil }
        defer { AudioFileClose(file) }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: format))
        guard AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format) == noErr,
              format.mFormatID == kAudioFormatLinearPCM, format.mChannelsPerFrame == 1,
              format.mSampleRate == 16_000, format.mBytesPerFrame == 2, format.mBitsPerChannel == 16,
              format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else { return nil }
        var offset: Int64 = 0
        size = UInt32(MemoryLayout.size(ofValue: offset))
        guard AudioFileGetProperty(file, kAudioFilePropertyDataOffset, &size, &offset) == noErr,
              offset > 0 else { return nil }
        dataOffset = UInt64(offset)
        return dataOffset
    }

    func levels(barCount: Int = 16) -> [Float]? {
        let windowFrames = max(1, barCount) * 800
        guard !Task.isCancelled, let offset = pcmOffset(), let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let extent = try? file.seekToEnd(), extent > offset else { return nil }
        let frames = Int((extent - offset) / 2)
        let window = min(frames, windowFrames)
        guard window > 0, (try? file.seek(toOffset: offset + UInt64(frames - window) * 2)) != nil,
              let data = try? file.read(upToCount: window * 2), data.count == window * 2 else { return nil }
        let samples: [Float] = data.withUnsafeBytes { bytes in
            (0..<window).map {
                Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768
            }
        }
        // Each bar covers the RMS power of 50 ms. Keep quiet speech visible while preserving zero for silence.
        return (0..<barCount).map { index in
            let end = window - (barCount - 1 - index) * 800
            guard end > 0 else { return 0 }
            let block = samples[max(0, end - 800)..<end]
            let power = block.reduce(Float(0)) { $0 + $1 * $1 } / Float(block.count)
            return min(1, max(0, (10 * log10(max(power, 1e-10)) + 56) / 50))
        }
    }
}
