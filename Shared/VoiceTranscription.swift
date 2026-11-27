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
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw VoiceTranscriptionError.invalidResponse }
        return text
    }

    private func multipartBody(
        boundary: String,
        audio: Data,
        configuration: VoiceConfiguration
    ) -> Data {
        var body = Data()
        body.appendFormField(name: "model_id", value: configuration.model, boundary: boundary)
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
