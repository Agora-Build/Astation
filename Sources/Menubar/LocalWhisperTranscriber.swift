import Foundation
import CoreML
import Hub
import Tokenizers
import WhisperKit

protocol WhisperWindowDecoding: AnyObject {
    func start(directory: URL) async throws
    func decode(_ samples: [Float], language: String) async throws -> String
    func cancel() async
}

private final class OfflineWhisperTokenizer: WhisperTokenizer {
    private let tokenizer: any Tokenizer
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>
    init(_ tokenizer: any Tokenizer) throws {
        self.tokenizer = tokenizer
        func token(_ text: String) throws -> Int {
            guard let value = tokenizer.convertTokenToId(text) else { throw TranscriptionError.message("The installed Whisper tokenizer is incompatible.") }
            return value
        }
        specialTokens = try SpecialTokens(endToken: token("<|endoftext|>"), englishToken: token("<|en|>"),
            noSpeechToken: token("<|nospeech|>"), noTimestampsToken: token("<|notimestamps|>"),
            specialTokenBegin: token("<|endoftext|>"), startOfPreviousToken: token("<|startofprev|>"),
            startOfTranscriptToken: token("<|startoftranscript|>"), timeTokenBegin: token("<|0.00|>"),
            transcribeToken: token("<|transcribe|>"), translateToken: token("<|translate|>"),
            whitespaceToken: tokenizer.convertTokenToId("\u{0120}") ?? 220)
        allLanguageTokens = Set(Constants.languages.values.compactMap { tokenizer.convertTokenToId("<|\($0)|>") })
    }
    func encode(text: String) -> [Int] { tokenizer.encode(text: text) }
    func decode(tokens: [Int]) -> String { tokenizer.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        // Word-level alignment is disabled; preserve the complete span without inventing timestamps.
        ([decode(tokens: tokenIds)], [tokenIds])
    }
}

actor WhisperKitWindowDecoder: WhisperWindowDecoding {
    private var pipe: WhisperKit?
    func start(directory: URL) async throws {
        let tokenizerFolder = directory.appendingPathComponent("tokenizer", isDirectory: true)
        let configuration = LanguageModelConfigurationFromHub(modelFolder: tokenizerFolder,
            hubApi: HubApi(downloadBase: tokenizerFolder, useOfflineMode: true))
        guard let tokenizerConfig = try await configuration.tokenizerConfig else {
            throw TranscriptionError.message("The installed Whisper tokenizer configuration is missing.")
        }
        let tokenizer = try PreTrainedTokenizer(tokenizerConfig: tokenizerConfig, tokenizerData: try await configuration.tokenizerData)
        #if arch(arm64)
        let compute = ModelComputeOptions()
        #else
        let compute = ModelComputeOptions(melCompute: .cpuOnly, audioEncoderCompute: .cpuOnly, textDecoderCompute: .cpuOnly)
        #endif
        let instance = try await WhisperKit(WhisperKitConfig(modelFolder: directory.path, computeOptions: compute,
            verbose: false, prewarm: false, load: false, download: false))
        pipe = instance
        // Inject the local tokenizer so the SDK cannot fall back to a network download.
        instance.tokenizer = try OfflineWhisperTokenizer(tokenizer)
        instance.textDecoder.isModelMultilingual = true
        try await instance.prewarmModels()
        try await instance.loadModels()
        try Task.checkCancellation()
    }
    func decode(_ samples: [Float], language: String) async throws -> String {
        guard let pipe else { throw TranscriptionError.message("Whisper is not ready.") }
        let code = language.split(separator: "-").first.map(String.init) ?? "en"
        let options = DecodingOptions(language: code, temperatureFallbackCount: 1, usePrefillCache: false,
            detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: true, wordTimestamps: false,
            windowClipTime: 0, suppressBlank: true, concurrentWorkerCount: 1)
        let result: [TranscriptionResult] = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        try Task.checkCancellation()
        return result.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func cancel() async { await pipe?.unloadModels(); pipe = nil }
}

actor LocalWhisperTranscriber: LiveTranscribing {
    private let directory: URL
    private let settings: TranscriptionSettings
    private let decoder: WhisperWindowDecoding
    private var buffer = SpeechWindowBuffer()
    private var callback: (@Sendable (TranscriptSegment) -> Void)?
    init(directory: URL, settings: TranscriptionSettings, decoder: WhisperWindowDecoding = WhisperKitWindowDecoder()) {
        self.directory = directory; self.settings = settings; self.decoder = decoder
    }
    func start(onSegment: @escaping @Sendable (TranscriptSegment) -> Void) async throws {
        callback = onSegment
        try await decoder.start(directory: directory)
    }
    func consume(_ samples: [Float]) async throws {
        for window in buffer.append(samples) { try await transcribe(window) }
    }
    func finish() async throws { if let window = buffer.finish() { try await transcribe(window) } }
    func cancel() async { callback = nil; await decoder.cancel() }
    private func transcribe(_ window: SpeechWindowBuffer.Window) async throws {
        let text = try await decoder.decode(window.samples, language: settings.language)
        try Task.checkCancellation()
        callback?(TranscriptSegment(id: window.id, sourceID: settings.sourceID, language: settings.language,
            text: text, isFinal: window.isFinal, offset: window.offset))
    }
}
