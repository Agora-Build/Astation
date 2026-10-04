import Foundation
import CStationCore

enum AgoraCaptionDecoder {
    static func decode(_ payload: Data, sourceID: String, publisherUID: UInt32) throws -> [TranscriptSegment] {
        guard payload.count <= 262_144 else { throw TranscriptionError.message("Cloud caption message is too large.") }
        var data = payload
        if payload.starts(with: [0x1f, 0x8b]) {
            var output = [UInt8](repeating: 0, count: 1_048_576)
            let count = payload.withUnsafeBytes { input in
                output.withUnsafeMutableBufferPointer {
                    astation_caption_inflate(input.bindMemory(to: UInt8.self).baseAddress, payload.count, $0.baseAddress, $0.count)
                }
            }
            guard count > 0 else { throw TranscriptionError.message("Invalid compressed cloud caption message.") }
            data = Data(output.prefix(count))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var segments: [TranscriptSegment] = []
        if let item = object["transcript"] as? [String: Any], (item["uid"] as? NSNumber) == NSNumber(value: publisherUID) {
            let rows = item["results"] as? [[String: Any]]
            // Empty results are the protocol's compatibility duplicate, not a replacement for live text.
            if rows == nil || rows?.isEmpty == false {
                let text = rows?.compactMap { $0["text"] as? String }.joined(separator: " ") ?? (item["text"] as? String ?? "")
                let final = rows?.allSatisfy { $0["isFinal"] as? Bool == true } ?? (item["isFinal"] as? Bool == true)
                segments.append(segment(item, text: text, final: final, language: item["language"] as? String ?? "en-US", sourceID: sourceID))
            }
        }
        if let item = object["translation"] as? [String: Any], (item["uid"] as? NSNumber) == NSNumber(value: publisherUID) {
            var rows = item["results"] as? [[String: Any]]
            if rows == nil, let fallback = item["results0"] as? [String: Any] { rows = [fallback] }
            let grouped = Dictionary(grouping: rows ?? [], by: { $0["language"] as? String ?? "" })
            for (language, results) in grouped where !language.isEmpty {
                let text = results.flatMap { $0["texts"] as? [String] ?? [] }.joined(separator: " ")
                let final = results.allSatisfy { ($0["isFinal"] as? Bool) ?? (item["isFinal"] as? Bool == true) }
                var value = segment(item, text: text, final: final, language: language, sourceID: sourceID)
                value.isTranslation = true
                segments.append(value)
            }
        }
        return segments
    }
    private static func segment(_ item: [String: Any], text: String, final: Bool, language: String, sourceID: String) -> TranscriptSegment {
        let identifier = (item["sentenceId"] as? NSNumber)?.stringValue
            ?? (item["textTs"] as? NSNumber)?.stringValue ?? UUID().uuidString
        let offset = max(0, (item["offset"] as? NSNumber)?.doubleValue ?? 0) / 1_000
        return TranscriptSegment(id: identifier, sourceID: sourceID, language: language, text: text, isFinal: final, offset: offset)
    }
}
