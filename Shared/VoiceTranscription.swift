import Foundation

protocol VoiceTranscriptionProvider {
    func transcribe(
        audioURL: URL,
        configuration: VoiceConfiguration
    ) async throws -> String
}

enum VoiceTranscriptionError: LocalizedError {
    case missingAPIKey
    case invalidEndpoint
    case unreadableAudio
    case invalidResponse
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "请在 Yah 中填写 ElevenLabs API Key。"
        case .invalidEndpoint:
            "语音服务地址无效，必须使用 HTTPS。"
        case .unreadableAudio:
            "录音文件读取失败。"
        case .invalidResponse:
            "语音服务返回了无法识别的结果。"
        case .server(let status, let message):
            "转写失败（\(status)）：\(message)"
        }
    }
}

extension VoiceTranscriptionError {
    static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
                 .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed:
                return true
            default: return false
            }
        }
        if case .server(let status, _) = error as? VoiceTranscriptionError {
            return status == 408 || status == 429 || status >= 500
        }
        return false
    }

    static func reason(for error: Error) -> String {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? "网络超时" : "网络连接失败"
        }
        switch error as? VoiceTranscriptionError {
        case .server(let status, _): return status == 429 ? "服务繁忙" : "服务异常 \(status)"
        case .invalidResponse: return "未识别到语音内容"
        case .unreadableAudio: return "录音读取失败"
        default: return "未知原因"
        }
    }
}

enum VoiceTranscriptionProviderFactory {
    static func make(for configuration: VoiceConfiguration) -> VoiceTranscriptionProvider {
        switch configuration.provider {
        case .elevenLabs:
            ElevenLabsTranscriptionProvider()
        }
    }
}

struct ElevenLabsTranscriptionProvider: VoiceTranscriptionProvider {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func transcribe(
        audioURL: URL,
        configuration: VoiceConfiguration
    ) async throws -> String {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceTranscriptionError.missingAPIKey
        }
        guard configuration.hasValidEndpoint, let endpoint = URL(string: configuration.endpoint) else {
            throw VoiceTranscriptionError.invalidEndpoint
        }
        guard let audio = try? Data(contentsOf: audioURL) else {
            throw VoiceTranscriptionError.unreadableAudio
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(configuration.apiKey, forHTTPHeaderField: "xi-api-key")
        request.httpBody = multipartBody(
            boundary: boundary,
            audio: audio,
            configuration: configuration
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VoiceTranscriptionError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode(ElevenLabsErrorResponse.self, from: data)
            throw VoiceTranscriptionError.server(
                status: http.statusCode,
                message: body?.detail?.message ?? body?.detail?.status ?? "服务暂时不可用"
            )
        }

        guard let decoded = try? JSONDecoder().decode(ElevenLabsTranscriptionResponse.self, from: data) else {
            throw VoiceTranscriptionError.invalidResponse
        }
        let text = Self.stripAudioEventTags(decoded.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceTranscriptionError.invalidResponse }
        return text
    }

    /// Removes residual non-speech audio event tags (e.g. `[写字声]`, `(笑声)`) if any slip through.
    private static func stripAudioEventTags(_ text: String) -> String {
        let pattern = #"[\[\(（【][^\]\)）】]{1,16}(?:声|音|笑|哭|咳|叹气|呼吸|鼓掌|掌声|音乐|噪声|噪音|杂音|静默|沉默|静音)[^\]\)）】]{0,4}[\]\)）】]"#
        let stripped = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        return stripped.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
    }

    private func multipartBody(
        boundary: String,
        audio: Data,
        configuration: VoiceConfiguration
    ) -> Data {
        var body = Data()
        body.appendFormField(name: "model_id", value: configuration.model, boundary: boundary)
        body.appendFormField(name: "tag_audio_events", value: "false", boundary: boundary)
        if !configuration.language.isEmpty {
            body.appendFormField(name: "language_code", value: configuration.language, boundary: boundary)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"voice.wav\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}

private extension Data {
    mutating func appendFormField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append(value.data(using: .utf8)!)
        append("\r\n".data(using: .utf8)!)
    }
}

private struct ElevenLabsTranscriptionResponse: Decodable {
    let text: String
}

private struct ElevenLabsErrorResponse: Decodable {
    let detail: Detail?

    struct Detail: Decodable {
        let message: String?
        let status: String?
    }
}
