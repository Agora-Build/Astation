import CryptoKit
import Foundation

/// Session payloads use the integer-only JCS domain. The wire scanner also
/// rejects duplicate keys before Foundation can silently discard them.
indirect enum AtemSessionJSON: Codable, Equatable {
    case object(Object), array([AtemSessionJSON]), string(String)
    case integer(Int64), bool(Bool), null
    case otherNumber(String)

    static let maximumInteger: Int64 = 9_007_199_254_740_991
    enum Invalid: Error { case json, limit, duplicateKey, number }
    static let rawRootKey = CodingUserInfoKey(rawValue: "atemSessionRawJSON")!

    init(from decoder: Decoder) throws {
        // Foundation keyed containers normalize Unicode keys. Recover arbitrary
        // payloads from the scanned bytes before that normalization can alter JCS.
        if var raw = decoder.userInfo[Self.rawRootKey] as? Self {
            for key in decoder.codingPath {
                if case .array(let values) = raw, let index = key.intValue, values.indices.contains(index) {
                    raw = values[index]
                } else if let field = raw[key.stringValue] { raw = field }
                else { throw Invalid.json }
            }
            self = raw
            return
        }
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let integer = try? value.decode(Int64.self), integer >= -Self.maximumInteger, integer <= Self.maximumInteger { self = .integer(integer) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([Self].self) { self = .array(array) }
        else if let object = try? value.decode(Object.self) { self = .object(object) }
        else { throw Invalid.json }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let bool): try value.encode(bool)
        case .integer(let integer):
            guard integer >= -Self.maximumInteger, integer <= Self.maximumInteger else { throw Invalid.number }
            try value.encode(integer)
        case .string(let string): try value.encode(string)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        case .otherNumber: throw Invalid.number
        }
    }

    subscript(_ key: String) -> Self? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var string: String? { if case .string(let text) = self { return text }; return nil }

    /// Swift String equality normalizes Unicode. JCS object keys must retain
    /// distinct Unicode spellings, so lookups and duplicate checks use bytes.
    struct Object: Codable, Equatable, ExpressibleByDictionaryLiteral {
        typealias Key = String
        typealias Value = AtemSessionJSON
        private var entries: [(String, AtemSessionJSON)] = []
        private var indices: [Data: Int] = [:]
        init() {}
        init(dictionaryLiteral elements: (String, AtemSessionJSON)...) {
            for (key, value) in elements { self[key] = value }
        }
        var count: Int { entries.count }
        var keys: [String] { entries.map { $0.0 } }
        subscript(_ key: String) -> AtemSessionJSON? {
            get { indices[Data(key.utf8)].map { entries[$0].1 } }
            set {
                let bytes = Data(key.utf8)
                if let index = indices[bytes] {
                    if let newValue { entries[index].1 = newValue }
                    else {
                        entries.remove(at: index)
                        indices.removeValue(forKey: bytes)
                        for position in index..<entries.count { indices[Data(entries[position].0.utf8)] = position }
                    }
                } else if let newValue {
                    indices[bytes] = entries.count
                    entries.append((key, newValue))
                }
            }
        }
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.count == rhs.count && lhs.entries.allSatisfy { rhs[$0.0] == $0.1 }
        }
        private struct FieldKey: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: FieldKey.self)
            for key in c.allKeys { self[key.stringValue] = try c.decode(AtemSessionJSON.self, forKey: key) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: FieldKey.self)
            for (key, value) in entries { try c.encode(value, forKey: FieldKey(stringValue: key)) }
        }
    }

    func canonical(allowOtherNumbers: Bool = false) throws -> String {
        switch self {
        case .null: return "null"
        case .bool(let bool): return bool ? "true" : "false"
        case .integer(let integer):
            guard integer >= -Self.maximumInteger, integer <= Self.maximumInteger else { throw Invalid.number }
            return String(integer)
        case .string(let string):
            var result = "\""
            for scalar in string.unicodeScalars {
                switch scalar.value {
                case 8: result += "\\b"
                case 9: result += "\\t"
                case 10: result += "\\n"
                case 12: result += "\\f"
                case 13: result += "\\r"
                case 34: result += "\\\""
                case 92: result += "\\\\"
                case 0..<32: result += String(format: "\\u%04x", scalar.value)
                default: result.unicodeScalars.append(scalar)
                }
            }
            return result + "\""
        case .array(let values): return "[" + (try values.map { try $0.canonical(allowOtherNumbers: allowOtherNumbers) }).joined(separator: ",") + "]"
        case .object(let values):
            let keys = values.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            return "{" + (try keys.map { try Self.string($0).canonical() + ":" + values[$0]!.canonical(allowOtherNumbers: allowOtherNumbers) }).joined(separator: ",") + "}"
        case .otherNumber(let token):
            guard allowOtherNumbers else { throw Invalid.number }
            return token
        }
    }

    func digest() throws -> String {
        SHA256.hash(data: Data(try canonical().utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func parse(_ data: Data, integersOnly: Bool = true, limit: Int = 1_048_576) throws -> Self {
        guard data.count <= limit else { throw Invalid.limit }
        var parser = Parser(bytes: Array(data), integersOnly: integersOnly)
        let value = try parser.value(depth: 0)
        parser.space()
        guard parser.index == parser.bytes.count else { throw Invalid.json }
        return value
    }

    /// Validate the original bytes, including relay envelopes, before a JSON
    /// round trip can erase duplicate keys or non-canonical number spellings.
    @discardableResult
    static func validatePacket(_ data: Data) throws -> Self {
        let root = try parse(data, integersOnly: false, limit: 2_097_152)
        let packet = root["payload"] ?? root
        if packet["type"]?.string == "session" {
            guard let body = packet["data"], try body.canonical(allowOtherNumbers: true).utf8.count <= 1_048_576 else { throw Invalid.limit }
            try integers(body, keys: ["v", "host_trust_gen", "authorization_ms_left", "server_time", "runtime_epoch", "seq", "ms_left", "lease_epoch", "updated_at"])
            try integers(body["binding"], keys: ["lease_epoch"])
            for target in [body["binding"]?["target"], body["target"]] { try integers(target, keys: ["host_trust_gen"]) }
            try integers(body["controller"], keys: ["lease_epoch"])
            var descriptors: [AtemSessionJSON] = []
            if let descriptor = body["descriptor"] { descriptors.append(descriptor) }
            if case .array(let values)? = body["sessions"] { descriptors += values }
            for descriptor in descriptors {
                try integers(descriptor, keys: ["activity_since", "created_at"])
                try integers(descriptor["controller"], keys: ["lease_epoch"])
            }
            if case .array(let values)? = body["receipts"] {
                for receipt in values {
                    try integers(receipt, keys: ["updated_at"])
                    try integers(receipt["target"], keys: ["host_trust_gen"])
                }
            }
            if let payload = body["payload"], try payload.canonical().utf8.count > 65_536 { throw Invalid.limit }
        } else if packet["type"]?.string == "terminal", let body = packet["data"], body["binding"] != nil {
            try integers(body, keys: ["v", "sequence", "offset", "rows", "cols"])
            try integers(body["binding"], keys: ["lease_epoch"])
            try integers(body["binding"]?["target"], keys: ["host_trust_gen"])
        }
        return root
    }

    private static func integers(_ object: AtemSessionJSON?, keys: [String]) throws {
        for key in keys {
            if let value = object?[key] {
                guard case .integer(let number) = value, number >= 0 else { throw Invalid.number }
            }
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        let integersOnly: Bool
        var index = 0
        mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func consume(_ byte: UInt8) -> Bool {
            space()
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
        mutating func value(depth: Int) throws -> AtemSessionJSON {
            space()
            guard depth <= 64, index < bytes.count else { throw Invalid.limit }
            switch bytes[index] {
            case 123:
                index += 1
                var object = Object()
                if consume(125) { return .object(object) }
                repeat {
                    let key = try string()
                    guard object[key] == nil else { throw Invalid.duplicateKey }
                    guard consume(58) else { throw Invalid.json }
                    object[key] = try value(depth: depth + 1)
                    if consume(125) { return .object(object) }
                } while consume(44)
                throw Invalid.json
            case 91:
                index += 1
                var array: [AtemSessionJSON] = []
                if consume(93) { return .array(array) }
                repeat {
                    array.append(try value(depth: depth + 1))
                    if consume(93) { return .array(array) }
                } while consume(44)
                throw Invalid.json
            case 34: return .string(try string())
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 110: try literal("null"); return .null
            default:
                let start = index
                while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
                let token = String(decoding: bytes[start..<index], as: UTF8.self)
                guard !token.isEmpty, token.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else { throw Invalid.json }
                if token.range(of: #"[.eE]"#, options: .regularExpression) == nil,
                   let integer = Int64(token), integer >= -AtemSessionJSON.maximumInteger, integer <= AtemSessionJSON.maximumInteger {
                    return .integer(integer)
                }
                guard !integersOnly else { throw Invalid.number }
                return .otherNumber(token)
            }
        }
        mutating func string() throws -> String {
            space()
            guard index < bytes.count, bytes[index] == 34 else { throw Invalid.json }
            let start = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 34 {
                    let data = Data(bytes[start..<index])
                    guard String(data: data, encoding: .utf8) != nil else { throw Invalid.json }
                    return try JSONDecoder().decode(String.self, from: data)
                }
                if byte == 92 { index += 1 }
                else if byte < 32 { throw Invalid.json }
            }
            throw Invalid.json
        }
        mutating func literal(_ text: String) throws {
            let token = Array(text.utf8)
            guard index + token.count <= bytes.count, Array(bytes[index..<index + token.count]) == token else { throw Invalid.json }
            index += token.count
        }
    }
}
