import Foundation

/// Append-only history retains the entire session even when the UI buffer is truncated.
final class TranscriptAutoSaver: @unchecked Sendable {
    let folder: URL
    private let queue = DispatchQueue(label: "build.agora.astation.transcript-files", qos: .utility)
    private let textFile: FileHandle
    private let eventsFile: FileHandle
    private let onError: @Sendable (String) -> Void
    private var seen: [String: TranscriptSegment] = [:]
    private var seenOrder: [String] = []
    private var failed = false
    private var closed = false
    init(root: URL, settings: TranscriptionSettings, startedAt: Date, onError: @escaping @Sendable (String) -> Void) throws {
        self.onError = onError
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        folder = root.appendingPathComponent("\(formatter.string(from: startedAt))_\(UUID().uuidString.prefix(8))", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let textURL = folder.appendingPathComponent("transcript.txt"), eventsURL = folder.appendingPathComponent("transcript.jsonl")
        for url in [textURL, eventsURL] {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw TranscriptionError.message("The transcript files could not be created.")
            }
        }
        textFile = try FileHandle(forWritingTo: textURL); eventsFile = try FileHandle(forWritingTo: eventsURL)
        struct Metadata: Encodable { let schemaVersion = 1; let startedAt: Date; let settings: TranscriptionSettings }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Metadata(startedAt: startedAt, settings: settings)).write(to: folder.appendingPathComponent("session.json"), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder.appendingPathComponent("session.json").path)
    }
    deinit { try? textFile.close(); try? eventsFile.close() }
    func append(_ segment: TranscriptSegment) {
        guard segment.isValid else { return }
        queue.async { [self] in
            guard !failed, !closed, seen[segment.key] != segment else { return }
            if let previous = seen[segment.key], previous.isFinal && !segment.isFinal { return }
            if seen[segment.key] == nil { seenOrder.append(segment.key) }
            seen[segment.key] = segment
            while seenOrder.count > 2_000 { seen.removeValue(forKey: seenOrder.removeFirst()) }
            do {
                var event = try JSONEncoder().encode(segment); event.append(0x0a)
                try eventsFile.write(contentsOf: event)
                if segment.isFinal {
                    let seconds = Int(segment.offset)
                    let stamp = String(format: "%02d:%02d", seconds / 60, seconds % 60)
                    let kind = segment.isTranslation ? "translation" : "final"
                    let line = "[\(stamp) \(segment.sourceID) \(segment.language) \(kind)] \(segment.text)\n"
                    try textFile.write(contentsOf: Data(line.utf8))
                }
            } catch { reportFailure() }
        }
    }
    func flush() {
        queue.sync {
            guard !failed, !closed else { return }
            do { try textFile.synchronize(); try eventsFile.synchronize() }
            catch { reportFailure() }
        }
    }
    func finish() {
        queue.sync {
            guard !closed else { return }
            do {
                try textFile.synchronize(); try eventsFile.synchronize()
                try textFile.close(); try eventsFile.close()
            } catch { if !failed { reportFailure() } }
            closed = true
        }
    }
    private func reportFailure() {
        failed = true
        onError("Transcript auto-save failed. Captions and audio recording continue; use Save Transcript to save the current buffer elsewhere.")
    }
}
