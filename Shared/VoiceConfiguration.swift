import Foundation
import Security

struct VoiceConfiguration: Codable, Equatable {
    enum Provider: String, Codable, CaseIterable, Identifiable {
        case elevenLabs

        var id: String { rawValue }
        var displayName: String { "ElevenLabs" }
    }

    var provider: Provider
    var apiKey: String
    var endpoint: String
    var model: String
    var language: String

    static let defaults = VoiceConfiguration(
        provider: .elevenLabs,
        apiKey: "",
        endpoint: "https://api.elevenlabs.io/v1/speech-to-text",
        model: "scribe_v2",
        language: "zh"
    )

    var hasValidEndpoint: Bool {
        guard let url = URL(string: endpoint) else { return false }
        return url.scheme == "https" && !(url.host?.isEmpty ?? true)
    }
}

enum VoiceConfigurationError: LocalizedError {
    case keychainNotConfigured
    case keychainFailure(OSStatus)
    case invalidStoredData

    var errorDescription: String? {
        switch self {
        case .keychainNotConfigured:
            "共享 Keychain 未配置，请使用有效的开发团队重新签名应用。"
        case .keychainFailure(let status):
            SecCopyErrorMessageString(status, nil).map { String($0) } ??
                "语音服务配置读取失败（\(status)）。"
        case .invalidStoredData:
            "语音服务配置已损坏，请重新保存。"
        }
    }
}

enum VoiceConfigurationStore {
    private static let service = "local.yah.voice-configuration"

    static func load() throws -> VoiceConfiguration? {
        var query = try baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw VoiceConfigurationError.keychainFailure(status) }
        guard let data = result as? Data else { throw VoiceConfigurationError.invalidStoredData }
        do {
            return try JSONDecoder().decode(VoiceConfiguration.self, from: data)
        } catch {
            throw VoiceConfigurationError.invalidStoredData
        }
    }

    static func save(_ configuration: VoiceConfiguration) throws {
        let data = try JSONEncoder().encode(configuration)
        var query = try baseQuery()
        let attributes = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as [String: Any]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw VoiceConfigurationError.keychainFailure(status)
        }
        query.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw VoiceConfigurationError.keychainFailure(addStatus)
        }
    }

    static func remove() throws {
        let status = SecItemDelete(try baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VoiceConfigurationError.keychainFailure(status)
        }
    }

    private static func baseQuery() throws -> [String: Any] {
        guard let configuredGroup = Bundle.main.object(
            forInfoDictionaryKey: "YahKeychainAccessGroup"
        ) as? String,
            !configuredGroup.isEmpty,
            !configuredGroup.contains("$(") else {
            throw VoiceConfigurationError.keychainNotConfigured
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "voice",
            kSecAttrAccessGroup as String: configuredGroup
        ]
    }
}
