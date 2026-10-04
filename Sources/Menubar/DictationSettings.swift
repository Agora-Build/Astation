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

enum DictationDestination: String, Codable, CaseIterable {
    case captions, activeText, atem
    var title: String {
        switch self {
        case .captions: return "Floating captions only"
        case .activeText: return "Type in the active text field + captions"
        case .atem: return "Send to the active Atem + captions"
        }
    }
}

struct DictationSettings: Codable, Equatable {
    var polishing = false
    var provider: DictationLLMProvider = .local
    var destination: DictationDestination = .atem
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
}

enum DictationError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
