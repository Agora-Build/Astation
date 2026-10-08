import Foundation

enum TranscriptionProvider: String, Codable, CaseIterable {
    case local, agora, custom
    var title: String {
        switch self {
        case .local: return "Local - On this Mac"
        case .agora: return "Cloud - Agora Real-Time STT & Translation"
        case .custom: return "Custom - OpenAI-compatible HTTP"
        }
    }
}

enum LocalTranscriptionModel: String, Codable, CaseIterable, Sendable {
    case parakeet, whisperTurbo, whisperLarge
    var id: String {
        switch self {
        case .parakeet: return "parakeet-eou-120m-320ms-v1"
        case .whisperTurbo: return "whisper-large-v3-turbo-coreml-v1"
        case .whisperLarge: return "whisper-large-v3-coreml-v1"
        }
    }
    var name: String {
        switch self {
        case .parakeet: return "Parakeet EOU 120M"
        case .whisperTurbo: return "Whisper large-v3 Turbo"
        case .whisperLarge: return "Whisper large-v3"
        }
    }
    var title: String {
        switch self {
        case .parakeet: return "Parakeet - Low latency / English"
        case .whisperTurbo: return "Whisper Turbo - Faster multilingual"
        case .whisperLarge: return "Whisper large-v3 - Accuracy-oriented"
        }
    }
    var detail: String {
        switch self {
        case .parakeet: return "Native streaming English, 320 ms chunks. Designed for low latency; smallest download."
        case .whisperTurbo: return "Multilingual, reduced decoder. Rolling audio windows add a few seconds of latency. Faster than full Whisper large-v3."
        case .whisperLarge: return "Full multilingual Whisper large-v3. Accuracy-oriented, with more memory and processing. Not a universal benchmark winner."
        }
    }
    var isEnglishOnly: Bool { self == .parakeet }
    var manifestResource: String { self == .parakeet ? "transcription-model" : id }
}

struct TranscriptionSettings: Codable, Equatable {
    var provider: TranscriptionProvider = .local
    var localModel: LocalTranscriptionModel = .parakeet
    var sourceID = "microphone"
    var additionalSourceIDs: [String] = []
    var selectedSourceIDs: [String] {
        var seen = Set<String>()
        return ([sourceID] + additionalSourceIDs).filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    var language = "en-US"
    var translationLanguage: String?
    var modelManifestURL = ""
    var floatingCaptions = true
    var customEndpoint = ""
    var customModel = "whisper-1"
    var customChunkSeconds = 5
    var autoSaveTranscript = false
    var transcriptFolderPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        .appendingPathComponent("Astation/Transcripts", isDirectory: true).path

    init() {}
    private enum CodingKeys: String, CodingKey {
        case provider, localModel, sourceID, additionalSourceIDs, language, translationLanguage, modelManifestURL, floatingCaptions
        case customEndpoint, customModel, customChunkSeconds, autoSaveTranscript, transcriptFolderPath
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        provider = try values.decodeIfPresent(TranscriptionProvider.self, forKey: .provider) ?? .local
        localModel = try values.decodeIfPresent(LocalTranscriptionModel.self, forKey: .localModel) ?? .parakeet
        sourceID = try values.decodeIfPresent(String.self, forKey: .sourceID) ?? "microphone"
        additionalSourceIDs = try values.decodeIfPresent([String].self, forKey: .additionalSourceIDs) ?? []
        language = try values.decodeIfPresent(String.self, forKey: .language) ?? "en-US"
        translationLanguage = try values.decodeIfPresent(String.self, forKey: .translationLanguage)
        modelManifestURL = try values.decodeIfPresent(String.self, forKey: .modelManifestURL) ?? ""
        floatingCaptions = try values.decodeIfPresent(Bool.self, forKey: .floatingCaptions) ?? true
        customEndpoint = try values.decodeIfPresent(String.self, forKey: .customEndpoint) ?? ""
        customModel = try values.decodeIfPresent(String.self, forKey: .customModel) ?? "whisper-1"
        customChunkSeconds = try values.decodeIfPresent(Int.self, forKey: .customChunkSeconds) ?? 5
        autoSaveTranscript = try values.decodeIfPresent(Bool.self, forKey: .autoSaveTranscript) ?? false
        transcriptFolderPath = try values.decodeIfPresent(String.self, forKey: .transcriptFolderPath) ?? transcriptFolderPath
    }
}

enum TranscriptionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct TranscriptSegment: Codable, Equatable, Sendable {
    let id: String
    let sourceID: String
    let language: String
    let text: String
    let isFinal: Bool
    let offset: TimeInterval
    var isTranslation = false
    var key: String { "\(sourceID):\(id):\(language):\(isTranslation)" }
    var isValid: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf8.count <= 65_536
            && offset.isFinite && offset >= 0 && offset < Double(Int.max)
    }
}

struct TranscriptBuffer {
    private(set) var segments: [TranscriptSegment] = []
    private(set) var wasTruncated = false
    mutating func update(_ segment: TranscriptSegment) {
        guard segment.isValid else { return }
        if let index = segments.firstIndex(where: { $0.key == segment.key }) {
            guard !segments[index].isFinal || segment.isFinal else { return }
            segments[index] = segment
        } else { segments.append(segment) }
        while segments.count > 2_000 || segments.reduce(0, { $0 + $1.text.utf8.count }) > 2_000_000 {
            segments.removeFirst()
            wasTruncated = true
        }
    }
    var text: String {
        let multipleSources = Set(segments.map(\.sourceID)).count > 1
        return segments.map { segment in
            let seconds = Int(segment.offset)
            let stamp = String(format: "%02d:%02d", seconds / 60, seconds % 60)
            let kind = segment.isTranslation ? "translation" : (segment.isFinal ? "final" : "live")
            let source = multipleSources ? " \(segment.sourceID)" : ""
            return "[\(stamp)\(source) \(segment.language) \(kind)] \(segment.text)"
        }.joined(separator: "\n")
    }
}

/// Uses monotonic receipt time, not the provider's audio timestamp or wall clock.
struct FloatingCaptionBuffer {
    static let retention: TimeInterval = 20
    struct Line: Equatable {
        let segment: TranscriptSegment
        let updatedAt: TimeInterval
    }
    private(set) var lines: [Line] = []
    private var seen: [String: TranscriptSegment] = [:]
    private var seenOrder: [String] = []
    mutating func update(_ segment: TranscriptSegment, now: TimeInterval, refreshReceipt: Bool = false) {
        expire(now: now)
        guard segment.isValid, now.isFinite else { return }
        if let previous = seen[segment.key] {
            guard previous != segment || refreshReceipt, !previous.isFinal || segment.isFinal else { return }
        } else {
            seenOrder.append(segment.key)
        }
        seen[segment.key] = segment
        while seenOrder.count > 2_000 { seen.removeValue(forKey: seenOrder.removeFirst()) }
        let line = Line(segment: segment, updatedAt: now)
        if let index = lines.firstIndex(where: { $0.segment.key == segment.key }) { lines[index] = line }
        else { lines.append(line) }
        while lines.count > 128 || lines.reduce(0, { $0 + $1.segment.text.utf8.count }) > 65_536 { lines.removeFirst() }
    }
    mutating func expire(now: TimeInterval) {
        lines.removeAll { now - $0.updatedAt >= Self.retention }
    }
    mutating func remove(keys: Set<String>) { lines.removeAll { keys.contains($0.segment.key) } }
}

protocol LiveTranscribing: AnyObject {
    func start(onSegment: @escaping @Sendable (TranscriptSegment) -> Void) async throws
    func consume(_ samples: [Float]) async throws
    func finish() async throws
    func cancel() async
}

struct TranscriptionPCM: @unchecked Sendable {
    let samples: [Float]
    let sampleRate: Double
    let channels: Int
    var hostTime: UInt64 = 0
    var duration: TimeInterval { Double(samples.count) / Double(channels) / sampleRate }
}

/// The capture worker never waits for inference or pipe writes.
final class TranscriptionInbox: @unchecked Sendable {
    let stream: AsyncStream<TranscriptionPCM>
    private let continuation: AsyncStream<TranscriptionPCM>.Continuation
    private let lock = NSLock()
    private var queuedSeconds: TimeInterval = 0
    private var closed = false
    init() {
        let pair = AsyncStream<TranscriptionPCM>.makeStream(bufferingPolicy: .bufferingOldest(256))
        stream = pair.stream
        continuation = pair.continuation
    }
    func offer(_ pcm: TranscriptionPCM) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, pcm.sampleRate > 0, pcm.channels > 0, pcm.duration.isFinite else { return false }
        guard queuedSeconds + pcm.duration <= 8 else { return false }
        switch continuation.yield(pcm) {
        case .enqueued: queuedSeconds += pcm.duration; return true
        default: return false
        }
    }
    func consumed(_ pcm: TranscriptionPCM) {
        lock.lock(); queuedSeconds = max(0, queuedSeconds - pcm.duration); lock.unlock()
    }
    func finish() {
        lock.lock(); closed = true; continuation.finish(); lock.unlock()
    }
}
