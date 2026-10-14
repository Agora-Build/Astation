import CAtemCore
import Foundation

enum AgoraTokenIdentity: Equatable {
    case uid(UInt32)
    case account(String)
}

enum AgoraTokenRole: UInt32, CaseIterable {
    case custom = 0, publisher = 1, subscriber = 2
}

struct AgoraRTCRequest {
    var channel: String
    var identity: AgoraTokenIdentity
    var role: AgoraTokenRole = .publisher
    var tokenExpiry: UInt32 = 3600
    var privilegeExpiry: UInt32 = 3600
    var joinExpiry: UInt32 = 3600
    var audioExpiry: UInt32 = 3600
    var videoExpiry: UInt32 = 3600
    var dataExpiry: UInt32 = 3600
    var includeRTM = false
    var rtmUser: String?
    var rtmExpiry: UInt32 = 3600
    var issuedAt: UInt32 = 0
    var salt: UInt32 = 0
}

struct AgoraDecodedToken: Decodable {
    struct Service: Decodable {
        struct Details: Decodable {
            let kind: String
            let channel: String?
            let account: String?
            let user_id: String?
        }
        let service_type: Int
        let privileges: [String: UInt32]
        let details: Details
    }
    let version: String
    let app_id: String
    let issued_at: UInt32
    let expire: UInt32
    let salt: UInt32
    let services: [Service]

    var issuedDate: Date { Date(timeIntervalSince1970: TimeInterval(issued_at)) }
    var expiryDate: Date { date(after: expire) }
    func date(after seconds: UInt32) -> Date {
        Date(timeIntervalSince1970: TimeInterval(issued_at) + TimeInterval(seconds))
    }
}

enum AgoraTokenError: LocalizedError {
    case invalid(String)
    case library(Int32)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .library(let code):
            switch code {
            case 10: return "The App ID must contain 32 hexadecimal characters."
            case 11: return "This project needs a valid App Certificate to generate or verify tokens."
            case 12: return "Enter a channel name between 1 and 64 UTF-8 bytes."
            case 13: return "Enter a user account between 1 and 255 UTF-8 bytes."
            case 14: return "Enter an RTM user ID between 1 and 64 UTF-8 bytes."
            case 15: return "Every expiry must be at least one second."
            case 20: return "Only AccessToken2 tokens beginning with 007 are supported."
            case 21: return "This token could not be decoded. Check that you pasted the complete token."
            default: return "The token operation failed. Please try again."
            }
        }
    }
}

enum AgoraTokenService {
    static var isCompatible: Bool { atem_core_abi_version() == ATEM_CORE_ABI_VERSION }

    static func rtc(appID: String, certificate: String, request: AgoraRTCRequest) throws -> String {
        let account: String?
        let uid: UInt32
        switch request.identity {
        case .uid(let value): uid = value; account = nil
        case .account(let value): uid = 0; account = value
        }
        return try withStrings([appID, certificate, request.channel, account, request.rtmUser]) { strings in
            var params = AtemCoreRtcTokenParams()
            params.struct_size = UInt32(MemoryLayout<AtemCoreRtcTokenParams>.size)
            params.app_id = strings[0]; params.app_certificate = strings[1]; params.channel = strings[2]
            params.uid = uid; params.user_account = strings[3]; params.role = request.role.rawValue
            params.token_expire = request.tokenExpiry; params.privilege_expire = request.privilegeExpiry
            params.join_channel_expire = request.joinExpiry; params.publish_audio_expire = request.audioExpiry
            params.publish_video_expire = request.videoExpiry; params.publish_data_expire = request.dataExpiry
            params.with_rtm = request.includeRTM ? 1 : 0; params.rtm_user_id = strings[4]
            params.rtm_expire = request.rtmExpiry; params.issued_at = request.issuedAt; params.salt = request.salt
            return try stringResult { atem_core_build_rtc_token(&params, $0, $1) }
        }
    }

    static func rtm(appID: String, certificate: String, user: String, expiry: UInt32 = 3600,
                    issuedAt: UInt32 = 0, salt: UInt32 = 0) throws -> String {
        try withStrings([appID, certificate, user]) { strings in
            var params = AtemCoreRtmTokenParams()
            params.struct_size = UInt32(MemoryLayout<AtemCoreRtmTokenParams>.size)
            params.app_id = strings[0]; params.app_certificate = strings[1]; params.user_id = strings[2]
            params.expire = expiry; params.issued_at = issuedAt; params.salt = salt
            return try stringResult { atem_core_build_rtm_token(&params, $0, $1) }
        }
    }

    static func decode(_ token: String) throws -> AgoraDecodedToken {
        try JSONDecoder().decode(AgoraDecodedToken.self, from: Data(decodedJSON(token).utf8))
    }

    static func decodedJSON(_ token: String) throws -> String {
        guard token.utf8.count <= 65_536 else { throw AgoraTokenError.invalid("The token is too large to inspect.") }
        return try withStrings([token]) { strings in
            try stringResult { atem_core_decode_token(strings[0], $0, $1) }
        }
    }

    static func verify(_ token: String, certificate: String) throws -> Bool {
        guard token.utf8.count <= 65_536 else { throw AgoraTokenError.invalid("The token is too large to verify.") }
        return try withStrings([token, certificate]) { strings in
            var valid: Int32 = 0
            var error: UnsafeMutablePointer<CChar>?
            defer { atem_core_string_free(error) }
            let status = atem_core_verify_token_signature(strings[0], strings[1], &valid, &error)
            guard status == ATEM_CORE_OK else { throw AgoraTokenError.library(status) }
            return valid == 1
        }
    }

    private static func stringResult(_ operation: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                                                   UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32) throws -> String {
        var value: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        defer { atem_core_string_free(value); atem_core_string_free(error) }
        let status = operation(&value, &error)
        guard status == ATEM_CORE_OK, let value else { throw AgoraTokenError.library(status) }
        return String(cString: value)
    }

    private static func withStrings<T>(_ values: [String?], operation: ([UnsafePointer<CChar>?]) throws -> T) throws -> T {
        guard isCompatible else { throw AgoraTokenError.invalid("The token library is incompatible with this app. Reinstall Astation.") }
        guard !values.contains(where: { $0?.contains("\0") == true }) else {
            throw AgoraTokenError.invalid("Token fields cannot contain a NUL character.")
        }
        let buffers = values.map { $0.map { value in value.withCString { strdup($0) } } ?? nil }
        defer { buffers.forEach { free($0) } }
        for (value, buffer) in zip(values, buffers) where value != nil && buffer == nil {
            throw AgoraTokenError.library(99)
        }
        return try operation(buffers.map { $0.map { UnsafePointer($0) } })
    }
}
