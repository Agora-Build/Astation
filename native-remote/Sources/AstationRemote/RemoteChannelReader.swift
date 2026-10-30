import Foundation

public enum RemoteHostChannelEvent: Equatable, Sendable {
    case frame(handle: String, bytes: Data)
    case close(handle: String, reason: String?)
}

public struct RemoteChannelReadError: Error {
    public let handle: String?
    public let reason: RemoteChannelCloseReason
}

extension RemoteChannelEnvelope {
    /// Only routing fields are decoded here. The shared endpoint validates the untouched inner frame.
    public static func readHost(_ data: Data) throws -> RemoteHostChannelEvent {
        if data.count > maximumBytes {
            throw RemoteChannelReadError(handle: oversizedHandle(data), reason: .tooLarge)
        }
        var handle: String?
        do {
            let fields = try RawFields.read(data)
            guard fields.string("type") == "channel" else { throw RemoteChannelWriteError.malformedFrame }
            handle = fields.string("channel").flatMap(validHandle)
            guard let handle, let event = fields.string("event") else { throw RemoteChannelWriteError.malformedFrame }
            switch event {
            case "frame":
                guard fields.values.count == 4, let frame = fields.values["frame"],
                      frame.first == 123 else { throw RemoteChannelWriteError.malformedFrame }
                return .frame(handle: handle, bytes: frame)
            case "close":
                guard Set(fields.values.keys).isSubset(of: ["type", "event", "channel", "reason"]),
                      fields.values.count >= 3 else { throw RemoteChannelWriteError.malformedFrame }
                let reason = fields.string("reason")
                if fields.values["reason"] != nil {
                    guard let reason, (1...32).contains(reason.utf8.count), reason.utf8.allSatisfy({
                        (97...122).contains($0) || $0 == 95
                    }) else { throw RemoteChannelWriteError.malformedFrame }
                }
                return .close(handle: handle, reason: reason)
            default: throw RemoteChannelWriteError.malformedFrame
            }
        } catch {
            throw RemoteChannelReadError(handle: handle ?? oversizedHandle(data), reason: .malformed)
        }
    }

    private static func validHandle(_ value: String) -> String? {
        RemoteChannelRoute.isValidHandle(value) ? value : nil
    }

    /// R9.7a permits identifying an oversized channel only from its first 4 KiB, before frame.
    private static func oversizedHandle(_ data: Data) -> String? {
        var reader = RawFields(bytes: Array(data.prefix(4096)))
        guard reader.consume(123) else { return nil }
        var fields: [String: Data] = [:]
        while let key = try? reader.string() {
            guard fields[key] == nil, reader.consume(58) else { return nil }
            if key == "frame" {
                let header = RawFields(values: fields)
                return header.string("type") == "channel" ? header.string("channel").flatMap(validHandle) : nil
            }
            guard let value = try? reader.value() else { return nil }
            fields[key] = value
            guard reader.consume(44) else { return nil }
        }
        return nil
    }
}

/// A bounded framing reader, not a cryptographic or membership verifier.
/// Foundation validates JSON syntax; ranges retain original inner number/string representations.
struct RawFields {
    var bytes: [UInt8] = []
    var index = 0
    var values: [String: Data] = [:]

    static func read(_ data: Data) throws -> RawFields {
        guard String(data: data, encoding: .utf8) != nil,
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw RemoteChannelWriteError.malformedFrame
        }
        var reader = RawFields(bytes: Array(data))
        guard reader.consume(123) else { throw RemoteChannelWriteError.malformedFrame }
        if reader.consume(125) { return reader }
        repeat {
            let key = try reader.string()
            guard reader.values[key] == nil, reader.consume(58) else { throw RemoteChannelWriteError.malformedFrame }
            reader.values[key] = try reader.value()
            if reader.consume(125) { return reader }
        } while reader.consume(44)
        throw RemoteChannelWriteError.malformedFrame
    }

    func string(_ key: String) -> String? {
        values[key].flatMap { try? JSONDecoder().decode(String.self, from: $0) }
    }

    mutating func space() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func consume(_ byte: UInt8) -> Bool {
        space()
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    mutating func string() throws -> String {
        space()
        let start = index
        guard consume(34) else { throw RemoteChannelWriteError.malformedFrame }
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
            if byte == 92 { index += 1 }
        }
        throw RemoteChannelWriteError.malformedFrame
    }

    mutating func value() throws -> Data {
        space()
        let start = index
        guard index < bytes.count else { throw RemoteChannelWriteError.malformedFrame }
        var nesting = 0
        repeat {
            let byte = bytes[index]
            if byte == 34 { _ = try string(); continue }
            if byte == 123 || byte == 91 {
                nesting += 1
                guard nesting <= 64 else { throw RemoteChannelWriteError.malformedFrame }
            } else if byte == 125 || byte == 93 {
                if nesting == 0 { break }
                nesting -= 1
            } else if nesting == 0, [9, 10, 13, 32, 44].contains(byte) { break }
            index += 1
        } while index < bytes.count && (nesting > 0 || ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]))
        guard nesting == 0, index > start else { throw RemoteChannelWriteError.malformedFrame }
        return Data(bytes[start..<index])
    }
}
