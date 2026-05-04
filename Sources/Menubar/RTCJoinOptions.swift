import Foundation

enum RTCEncryptionMode: Int32, CaseIterable {
    case none = 0
    case aes256Gcm2 = 8
    case aes128Gcm2 = 7
    case aes256Gcm = 6
    case aes128Gcm = 5
    case aes256Xts = 3
    case aes128Ecb = 2
    case aes128Xts = 1
    case sm4_128Ecb = 4

    static let manualJoinDefault: RTCEncryptionMode = .aes256Gcm2

    static let manualJoinPickerOptions: [RTCEncryptionMode] = [
        .aes256Gcm2,
        .aes128Gcm2,
        .none,
        .aes256Gcm,
        .aes128Gcm,
        .aes256Xts,
        .aes128Xts,
        .aes128Ecb,
        .sm4_128Ecb
    ]

    var title: String {
        switch self {
        case .none:
            return "Off"
        case .aes256Gcm2:
            return "AES-256-GCM2"
        case .aes128Gcm2:
            return "AES-128-GCM2"
        case .aes256Gcm:
            return "AES-256-GCM"
        case .aes128Gcm:
            return "AES-128-GCM"
        case .aes256Xts:
            return "AES-256-XTS"
        case .aes128Ecb:
            return "AES-128-ECB"
        case .aes128Xts:
            return "AES-128-XTS"
        case .sm4_128Ecb:
            return "SM4-128-ECB"
        }
    }

    var requiresSalt: Bool {
        switch self {
        case .aes128Gcm2, .aes256Gcm2:
            return true
        default:
            return false
        }
    }

    var isEnabled: Bool {
        self != .none
    }
}

enum RTCGeoFence: UInt32, CaseIterable {
    case noFence = 0xFFFFFFFF
    case northAmerica = 0x00000002
    case europe = 0x00000004
    case asia = 0x00000008
    case japan = 0x00000010
    case india = 0x00000020
    case mainlandChina = 0x00000001

    static let manualJoinDefault: RTCGeoFence = .noFence

    static let manualJoinPickerOptions: [RTCGeoFence] = [
        .noFence,
        .northAmerica,
        .asia,
        .mainlandChina,
        .europe,
        .japan,
        .india
    ]

    var title: String {
        switch self {
        case .noFence:
            return "Global (Default)"
        case .northAmerica:
            return "North America"
        case .asia:
            return "Asia Pacific"
        case .mainlandChina:
            return "Mainland China"
        case .europe:
            return "Europe"
        case .japan:
            return "Japan"
        case .india:
            return "India"
        }
    }
}

enum RTCEncryptionValidationError: LocalizedError, Equatable {
    case keyRequired
    case saltMustBe32Bytes
    case saltInvalidFormat

    var errorDescription: String? {
        switch self {
        case .keyRequired:
            return "Encryption key required"
        case .saltMustBe32Bytes:
            return "Salt must decode to 32 bytes (hex or base64)"
        case .saltInvalidFormat:
            return "Salt must be valid hex or base64"
        }
    }
}

struct RTCEncryptionConfiguration: Equatable {
    let mode: RTCEncryptionMode
    let key: String
    let saltBytes: [UInt8]

    static func make(
        mode: RTCEncryptionMode,
        key: String,
        salt: String
    ) throws -> RTCEncryptionConfiguration? {
        guard mode.isEnabled else {
            return nil
        }

        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw RTCEncryptionValidationError.keyRequired
        }

        let saltBytes: [UInt8]
        if mode.requiresSalt {
            saltBytes = try parseSaltValue(salt)
        } else {
            saltBytes = []
        }

        return RTCEncryptionConfiguration(
            mode: mode,
            key: trimmedKey,
            saltBytes: saltBytes
        )
    }

    static func generateSaltHex() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32)
            .map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &generator) }
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func parseSaltValue(_ rawValue: String) throws -> [UInt8] {
        if let hexBytes = try parseHexSalt(rawValue) {
            return hexBytes
        }
        if let base64Bytes = parseBase64Salt(rawValue) {
            return base64Bytes
        }

        let compact = rawValue.filter { !$0.isWhitespace }
        if compact.isEmpty {
            throw RTCEncryptionValidationError.saltMustBe32Bytes
        }

        if compact.count == 64 {
            throw RTCEncryptionValidationError.saltInvalidFormat
        }
        throw RTCEncryptionValidationError.saltMustBe32Bytes
    }

    private static func parseHexSalt(_ rawValue: String) throws -> [UInt8]? {
        let normalized = rawValue.lowercased().filter { character in
            !character.isWhitespace && character != ":" && character != "-"
        }

        guard !normalized.isEmpty else {
            return nil
        }
        guard normalized.count == 64 else {
            return nil
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)

        var index = normalized.startIndex
        while index < normalized.endIndex {
            let nextIndex = normalized.index(index, offsetBy: 2)
            let byteString = normalized[index..<nextIndex]
            guard let byte = UInt8(byteString, radix: 16) else {
                throw RTCEncryptionValidationError.saltInvalidFormat
            }
            bytes.append(byte)
            index = nextIndex
        }

        return bytes
    }

    private static func parseBase64Salt(_ rawValue: String) -> [UInt8]? {
        let normalized = rawValue.filter { !$0.isWhitespace }
        guard !normalized.isEmpty else {
            return nil
        }

        let paddedStandard = padBase64(normalized)
        if let data = Data(base64Encoded: paddedStandard), data.count == 32 {
            return Array(data)
        }

        let urlSafe = normalized
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddedURLSafe = padBase64(urlSafe)
        if let data = Data(base64Encoded: paddedURLSafe), data.count == 32 {
            return Array(data)
        }

        return nil
    }

    private static func padBase64(_ value: String) -> String {
        let remainder = value.count % 4
        guard remainder != 0 else {
            return value
        }
        return value + String(repeating: "=", count: 4 - remainder)
    }
}

struct RTCJoinOptions: Equatable {
    let geoFence: RTCGeoFence
    let encryption: RTCEncryptionConfiguration?

    static let standard = RTCJoinOptions(
        geoFence: .noFence,
        encryption: nil
    )
}
