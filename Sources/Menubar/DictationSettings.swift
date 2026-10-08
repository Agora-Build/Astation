import Foundation

enum DictationLLMProvider: String, Codable, CaseIterable {
    case local, localServer, cloud, custom
    var title: String {
        switch self {
        case .local: return "Local - Apple on-device model"
        case .localServer: return "Local - Qwen / Ollama / llama.cpp"
        case .cloud: return "Cloud - OpenAI"
        case .custom: return "Custom - OpenAI-compatible / local server"
        }
    }
}

struct DictationSettings: Codable, Equatable {
    var polishing = false
    var provider: DictationLLMProvider = .local
    var typeInActiveTextField = true
    var sendToAtem = false
    var cloudModel = "gpt-4.1-mini"
    var localEndpoint = "http://localhost:11434/v1/chat/completions"
    var localModel = "qwen3:4b"
    var customEndpoint = "http://localhost:11434/v1/chat/completions"
    var customModel = "qwen3:4b"
    // Consent is bound to the exact endpoint, not a global permission to upload text.
    var consentEndpoint: String?
    var endpoint: String {
        switch provider {
        case .cloud: return "https://api.openai.com/v1/chat/completions"
        case .localServer: return localEndpoint
        default: return customEndpoint
        }
    }
    var model: String {
        switch provider {
        case .cloud: return cloudModel
        case .localServer: return localModel
        default: return customModel
        }
    }
    var requiresUploadConsent: Bool {
        guard provider != .local else { return false }
        guard let url = CustomTranscriptionHTTP.endpoint(endpoint), let host = url.host else { return true }
        return !["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
    }
    var hasUploadConsent: Bool { !requiresUploadConsent || consentEndpoint == endpoint }
    var outputSummary: String {
        var outputs = [String]()
        if typeInActiveTextField { outputs.append("Active text field") }
        if sendToAtem { outputs.append("Active Atem") }
        outputs.append("Floating captions")
        return outputs.joined(separator: " + ")
    }

    private enum CodingKeys: String, CodingKey {
        case polishing, provider, typeInActiveTextField, sendToAtem
        case cloudModel, localEndpoint, localModel, customEndpoint, customModel, consentEndpoint
    }
    private enum LegacyCodingKeys: String, CodingKey { case destination }
    private enum LegacyDestination: String, Decodable { case captions, activeText, atem }
}

extension DictationSettings {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        polishing = try values.decodeIfPresent(Bool.self, forKey: .polishing) ?? polishing
        provider = try values.decodeIfPresent(DictationLLMProvider.self, forKey: .provider) ?? provider
        if values.contains(.typeInActiveTextField) || values.contains(.sendToAtem) {
            typeInActiveTextField = try values.decodeIfPresent(Bool.self, forKey: .typeInActiveTextField) ?? typeInActiveTextField
            sendToAtem = try values.decodeIfPresent(Bool.self, forKey: .sendToAtem) ?? sendToAtem
        } else {
            // Preserve the old output choice without opting existing users into another output.
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            if let destination = try legacy.decodeIfPresent(LegacyDestination.self, forKey: .destination) {
                typeInActiveTextField = destination == .activeText
                sendToAtem = destination == .atem
            }
        }
        cloudModel = try values.decodeIfPresent(String.self, forKey: .cloudModel) ?? cloudModel
        localEndpoint = try values.decodeIfPresent(String.self, forKey: .localEndpoint) ?? localEndpoint
        localModel = try values.decodeIfPresent(String.self, forKey: .localModel) ?? localModel
        customEndpoint = try values.decodeIfPresent(String.self, forKey: .customEndpoint) ?? customEndpoint
        customModel = try values.decodeIfPresent(String.self, forKey: .customModel) ?? customModel
        consentEndpoint = try values.decodeIfPresent(String.self, forKey: .consentEndpoint)
    }
}

enum DictationError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
