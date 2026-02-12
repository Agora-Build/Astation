import CryptoKit
import Foundation

/// AccessToken2 builder — Swift port of Atem/src/token.rs.
/// Generates real Agora AccessToken2 tokens using CryptoKit HMAC-SHA256.
enum AccessToken2 {
    enum RTCRole {
        case publisher
        case subscriber
    }

    // Service types
    static let serviceTypeRTC: UInt16 = 1
    static let serviceTypeRTM: UInt16 = 2

    // RTC privilege types
    static let privilegeJoinChannel: UInt16 = 1
    static let privilegePublishAudio: UInt16 = 2
    static let privilegePublishVideo: UInt16 = 3
    static let privilegePublishData: UInt16 = 4

    // RTM privilege types
    static let privilegeLogin: UInt16 = 1

    /// Build an AccessToken2 for RTC.
    static func buildTokenRTC(
        appId: String,
        appCertificate: String,
        channel: String,
        uid: UInt32,
        role: RTCRole,
        expireSecs: UInt32,
        issuedAt: UInt32
    ) -> String {
        guard !appCertificate.isEmpty else { return "" }

        let salt = UInt32.random(in: UInt32.min...UInt32.max)
        let expireAt = issuedAt &+ expireSecs

        // Build privileges based on role
        var privileges: [(UInt16, UInt32)] = [(privilegeJoinChannel, expireAt)]
        if case .publisher = role {
            privileges.append((privilegePublishAudio, expireAt))
            privileges.append((privilegePublishVideo, expireAt))
            privileges.append((privilegePublishData, expireAt))
        }

        // Pack binary content
        var content = Data()
        packString(&content, appId)
        packUInt32(&content, issuedAt)
        packUInt32(&content, expireSecs)
        packUInt32(&content, salt)
        packUInt16(&content, 1) // 1 service (RTC)
        packUInt16(&content, serviceTypeRTC)
        packUInt16(&content, UInt16(privileges.count))
        for (key, value) in privileges {
            packUInt16(&content, key)
            packUInt32(&content, value)
        }
        packString(&content, channel)
        packString(&content, String(uid))

        // Derive signing key
        let signingKey = deriveSigningKey(
            appCertificate: appCertificate, issuedAt: issuedAt, salt: salt)

        // Sign content
        let signature = HMAC<SHA256>.authenticationCode(
            for: content, using: SymmetricKey(data: signingKey))
        let signatureData = Data(signature)

        // Final token: "007" + base64(packBytes(signature) + content)
        var tokenBuf = Data()
        packBytes(&tokenBuf, signatureData)
        tokenBuf.append(content)

        return "007" + tokenBuf.base64EncodedString()
    }

    /// Build an AccessToken2 for RTM.
    static func buildTokenRTM(
        appId: String,
        appCertificate: String,
        userId: String,
        expireSecs: UInt32,
        issuedAt: UInt32
    ) -> String {
        guard !appCertificate.isEmpty else { return "" }

        let salt = UInt32.random(in: UInt32.min...UInt32.max)
        let expireAt = issuedAt &+ expireSecs

        let privileges: [(UInt16, UInt32)] = [(privilegeLogin, expireAt)]

        var content = Data()
        packString(&content, appId)
        packUInt32(&content, issuedAt)
        packUInt32(&content, expireSecs)
        packUInt32(&content, salt)
        packUInt16(&content, 1) // 1 service (RTM)
        packUInt16(&content, serviceTypeRTM)
        packUInt16(&content, UInt16(privileges.count))
        for (key, value) in privileges {
            packUInt16(&content, key)
            packUInt32(&content, value)
        }
        packString(&content, userId)

        let signingKey = deriveSigningKey(
            appCertificate: appCertificate, issuedAt: issuedAt, salt: salt)

        let signature = HMAC<SHA256>.authenticationCode(
            for: content, using: SymmetricKey(data: signingKey))
        let signatureData = Data(signature)

        var tokenBuf = Data()
        packBytes(&tokenBuf, signatureData)
        tokenBuf.append(content)

        return "007" + tokenBuf.base64EncodedString()
    }

    // MARK: - Signing Key Derivation

    private static func deriveSigningKey(
        appCertificate: String, issuedAt: UInt32, salt: UInt32
    ) -> Data {
        let certData = Data(appCertificate.utf8)

        // Step 1: HMAC(certificate, issue_ts_LE)
        var issuedAtLE = issuedAt.littleEndian
        let issuedAtData = Data(bytes: &issuedAtLE, count: MemoryLayout<UInt32>.size)
        let key1 = HMAC<SHA256>.authenticationCode(
            for: issuedAtData, using: SymmetricKey(data: certData))

        // Step 2: HMAC(key1, salt_LE)
        var saltLE = salt.littleEndian
        let saltData = Data(bytes: &saltLE, count: MemoryLayout<UInt32>.size)
        let key2 = HMAC<SHA256>.authenticationCode(
            for: saltData, using: SymmetricKey(data: Data(key1)))

        return Data(key2)
    }

    // MARK: - Binary Packing (little-endian)

    static func packUInt16(_ buf: inout Data, _ val: UInt16) {
        withUnsafeBytes(of: val.littleEndian) { buf.append(contentsOf: $0) }
    }

    static func packUInt32(_ buf: inout Data, _ val: UInt32) {
        withUnsafeBytes(of: val.littleEndian) { buf.append(contentsOf: $0) }
    }

    static func packString(_ buf: inout Data, _ s: String) {
        let bytes = Data(s.utf8)
        packUInt16(&buf, UInt16(bytes.count))
        buf.append(bytes)
    }

    static func packBytes(_ buf: inout Data, _ data: Data) {
        packUInt16(&buf, UInt16(data.count))
        buf.append(data)
    }
}
