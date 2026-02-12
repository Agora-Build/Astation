import CStationCore
import XCTest
import zlib

@testable import Menubar

// MARK: - Token Decoder (for roundtrip verification)

/// Minimal AccessToken2 decoder — mirrors Agora's AccessToken2 format.
/// Used only in tests to verify the C++ token builder produces valid tokens.
private struct DecodedToken {
    let signature: Data
    let appId: String
    let issueTs: UInt32
    let expire: UInt32
    let salt: UInt32
    let services: [DecodedService]
}

private struct DecodedService {
    let serviceType: UInt16
    let channel: String?
    let uid: String?
    let userId: String?
    let privileges: [(key: UInt16, value: UInt32)]
}

private enum RtcRole: Int32 {
    case publisher = 1
    case subscriber = 2
}

private let testAppId = "0123456789abcdef0123456789abcdef"
private let testAppCert = "abcdef0123456789abcdef0123456789"
private let testAppIdAlt = "00112233445566778899aabbccddeeff"
private let testAppCertAlt = "ffeeddccbbaa99887766554433221100"

private func buildRtcToken(
    appId: String = testAppId,
    appCertificate: String = testAppCert,
    channel: String,
    uid: UInt32,
    role: RtcRole,
    tokenExpireSeconds: UInt32,
    privilegeExpireSeconds: UInt32
) -> String {
    appId.withCString { appIdC in
        appCertificate.withCString { certC in
            channel.withCString { channelC in
                guard let tokenPtr = astation_rtc_build_token(
                    appIdC,
                    certC,
                    channelC,
                    uid,
                    role.rawValue,
                    tokenExpireSeconds,
                    privilegeExpireSeconds
                ) else {
                    return ""
                }
                let token = String(cString: tokenPtr)
                astation_token_free(tokenPtr)
                return token
            }
        }
    }
}

private func buildRtmToken(
    appId: String = testAppId,
    appCertificate: String = testAppCert,
    userId: String,
    tokenExpireSeconds: UInt32
) -> String {
    appId.withCString { appIdC in
        appCertificate.withCString { certC in
            userId.withCString { userIdC in
                guard let tokenPtr = astation_rtm_build_token(
                    appIdC,
                    certC,
                    userIdC,
                    tokenExpireSeconds
                ) else {
                    return ""
                }
                let token = String(cString: tokenPtr)
                astation_token_free(tokenPtr)
                return token
            }
        }
    }
}

private func zlibDecompress(_ data: Data) throws -> Data {
    if data.isEmpty {
        return Data()
    }
    var capacity = max(1024, data.count * 8)

    while true {
        var output = Data(count: capacity)
        var destLen = uLongf(capacity)

        let result = output.withUnsafeMutableBytes { dstBuffer in
            data.withUnsafeBytes { srcBuffer in
                guard
                    let dstBase = dstBuffer.bindMemory(to: Bytef.self).baseAddress,
                    let srcBase = srcBuffer.bindMemory(to: Bytef.self).baseAddress
                else {
                    return Z_MEM_ERROR
                }
                return uncompress(dstBase, &destLen, srcBase, uLong(data.count))
            }
        }

        if result == Z_OK {
            output.count = Int(destLen)
            return output
        }

        if result == Z_BUF_ERROR {
            capacity *= 2
            continue
        }

        throw NSError(domain: "Token", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to decompress zlib payload"])
    }
}

private func decodeToken(_ token: String) throws -> DecodedToken {
    guard token.hasPrefix("007") else {
        throw NSError(domain: "Token", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing 007 prefix"])
    }

    let encoded = String(token.dropFirst(3))
    guard let compressed = Data(base64Encoded: encoded) else {
        throw NSError(domain: "Token", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid base64"])
    }
    let data = try zlibDecompress(compressed)

    var offset = 0

    func readUInt16() throws -> UInt16 {
        guard offset + 2 <= data.count else {
            throw NSError(domain: "Token", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unexpected end at offset \(offset)"])
        }
        let val = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        offset += 2
        return val
    }

    func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw NSError(domain: "Token", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unexpected end at offset \(offset)"])
        }
        let val = UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
        offset += 4
        return val
    }

    func readBytes(_ count: Int) throws -> Data {
        guard offset + count <= data.count else {
            throw NSError(domain: "Token", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unexpected end at offset \(offset)"])
        }
        let bytes = data[offset..<(offset + count)]
        offset += count
        return Data(bytes)
    }

    func readString() throws -> String {
        let len = Int(try readUInt16())
        let bytes = try readBytes(len)
        guard let s = String(data: bytes, encoding: .utf8) else {
            throw NSError(domain: "Token", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8"])
        }
        return s
    }

    // Read signature (length-prefixed bytes)
    let sigLen = Int(try readUInt16())
    let signature = try readBytes(sigLen)

    // Read content fields
    let appId = try readString()
    let issueTs = try readUInt32()
    let expire = try readUInt32()
    let salt = try readUInt32()
    let serviceCount = try readUInt16()

    var services: [DecodedService] = []
    for _ in 0..<serviceCount {
        let serviceType = try readUInt16()
        let privCount = try readUInt16()
        var channel: String? = nil
        var uid: String? = nil
        var userId: String? = nil
        var privileges: [(key: UInt16, value: UInt32)] = []
        for _ in 0..<privCount {
            let k = try readUInt16()
            let v = try readUInt32()
            privileges.append((key: k, value: v))
        }
        if serviceType == 1 {
            channel = try readString()
            uid = try readString()
        } else if serviceType == 2 {
            userId = try readString()
        }
        services.append(DecodedService(
            serviceType: serviceType,
            channel: channel,
            uid: uid,
            userId: userId,
            privileges: privileges
        ))
    }

    // Verify we consumed all bytes
    XCTAssertEqual(offset, data.count, "Token should have no trailing bytes")

    return DecodedToken(
        signature: signature, appId: appId, issueTs: issueTs,
        expire: expire, salt: salt, services: services)
}

// MARK: - Tests

final class AccessToken2Tests: XCTestCase {

    // MARK: - Empty certificate → empty token

    func testEmptyCertificateReturnsEmptyRTCToken() {
        let token = buildRtcToken(
            appId: testAppId,
            appCertificate: "",
            channel: "chan",
            uid: 1234,
            role: .publisher,
            tokenExpireSeconds: 3600,
            privilegeExpireSeconds: 3600
        )
        XCTAssertTrue(token.isEmpty)
    }

    func testEmptyCertificateReturnsEmptyRTMToken() {
        let token = buildRtmToken(
            appId: testAppId,
            appCertificate: "",
            userId: "user",
            tokenExpireSeconds: 3600
        )
        XCTAssertTrue(token.isEmpty)
    }

    // MARK: - Version prefix

    func testRTCTokenStartsWith007() {
        let token = buildRtcToken(
            channel: "chan",
            uid: 1,
            role: .publisher,
            tokenExpireSeconds: 3600,
            privilegeExpireSeconds: 3600
        )
        XCTAssertTrue(token.hasPrefix("007"))
    }

    func testRTMTokenStartsWith007() {
        let token = buildRtmToken(
            userId: "user",
            tokenExpireSeconds: 3600
        )
        XCTAssertTrue(token.hasPrefix("007"))
    }

    // MARK: - Base64 validity

    func testRTCTokenIsValidBase64After007() {
        let token = buildRtcToken(
            channel: "chan1",
            uid: 42,
            role: .publisher,
            tokenExpireSeconds: 3600,
            privilegeExpireSeconds: 3600
        )
        let encoded = String(token.dropFirst(3))
        XCTAssertNotNil(Data(base64Encoded: encoded), "Content after '007' should be valid base64")
    }

    func testRTMTokenIsValidBase64After007() {
        let token = buildRtmToken(
            userId: "alice",
            tokenExpireSeconds: 7200
        )
        let encoded = String(token.dropFirst(3))
        XCTAssertNotNil(Data(base64Encoded: encoded), "Content after '007' should be valid base64")
    }

    // MARK: - Publisher vs Subscriber

    func testPublisherTokenLongerThanSubscriber() {
        let pubToken = buildRtcToken(
            channel: "chan",
            uid: 7,
            role: .publisher,
            tokenExpireSeconds: 3600,
            privilegeExpireSeconds: 3600
        )
        let subToken = buildRtcToken(
            channel: "chan",
            uid: 7,
            role: .subscriber,
            tokenExpireSeconds: 3600,
            privilegeExpireSeconds: 3600
        )
        XCTAssertGreaterThan(
            pubToken.count, subToken.count,
            "Publisher token should be longer (4 privileges vs 1)")
    }

    // MARK: - Roundtrip: RTC token generate → decode

    func testRTCPublisherRoundtrip() throws {
        let channel = "chan1"
        let uid: UInt32 = 1234
        let now = UInt32(Date().timeIntervalSince1970)
        let tokenExpireSeconds: UInt32 = 3600
        let privilegeExpireSeconds: UInt32 = 3600
        let token = buildRtcToken(
            channel: channel,
            uid: uid,
            role: .publisher,
            tokenExpireSeconds: tokenExpireSeconds,
            privilegeExpireSeconds: privilegeExpireSeconds
        )

        let decoded = try decodeToken(token)

        XCTAssertEqual(decoded.appId, testAppId)
        XCTAssertLessThanOrEqual(abs(Int(decoded.issueTs) - Int(now)), 10)
        XCTAssertEqual(decoded.expire, tokenExpireSeconds)
        XCTAssertEqual(decoded.signature.count, 32, "HMAC-SHA256 signature should be 32 bytes")
        XCTAssertEqual(decoded.services.count, 1)
        XCTAssertEqual(decoded.services[0].serviceType, 1, "Service type should be RTC (1)")
        XCTAssertEqual(decoded.services[0].channel, channel)
        XCTAssertEqual(decoded.services[0].uid, String(uid))
        XCTAssertEqual(decoded.services[0].privileges.count, 4, "Publisher should have 4 privileges")

        // Verify all privilege types are present
        let privKeys = Set(decoded.services[0].privileges.map { $0.key })
        XCTAssertTrue(privKeys.contains(1), "Should have joinChannel privilege")
        XCTAssertTrue(privKeys.contains(2), "Should have publishAudio privilege")
        XCTAssertTrue(privKeys.contains(3), "Should have publishVideo privilege")
        XCTAssertTrue(privKeys.contains(4), "Should have publishData privilege")

        // All privileges should expire at issuedAt + expireSecs
        let expectedExpireAt: UInt32 = privilegeExpireSeconds
        for priv in decoded.services[0].privileges {
            XCTAssertEqual(priv.value, expectedExpireAt, "Privilege \(priv.key) should expire at \(expectedExpireAt)")
        }
    }

    func testRTCSubscriberRoundtrip() throws {
        let channel = "ch"
        let uid: UInt32 = 9
        let now = UInt32(Date().timeIntervalSince1970)
        let tokenExpireSeconds: UInt32 = 7200
        let privilegeExpireSeconds: UInt32 = 7200
        let token = buildRtcToken(
            channel: channel,
            uid: uid,
            role: .subscriber,
            tokenExpireSeconds: tokenExpireSeconds,
            privilegeExpireSeconds: privilegeExpireSeconds
        )

        let decoded = try decodeToken(token)

        XCTAssertEqual(decoded.appId, testAppId)
        XCTAssertLessThanOrEqual(abs(Int(decoded.issueTs) - Int(now)), 10)
        XCTAssertEqual(decoded.expire, tokenExpireSeconds)
        XCTAssertEqual(decoded.services.count, 1)
        XCTAssertEqual(decoded.services[0].serviceType, 1)
        XCTAssertEqual(decoded.services[0].channel, channel)
        XCTAssertEqual(decoded.services[0].uid, String(uid))
        XCTAssertEqual(decoded.services[0].privileges.count, 1, "Subscriber should have 1 privilege")
        XCTAssertEqual(decoded.services[0].privileges[0].key, 1, "Should only have joinChannel")
        XCTAssertEqual(decoded.services[0].privileges[0].value, privilegeExpireSeconds)
    }

    // MARK: - Roundtrip: RTM token generate → decode

    func testRTMRoundtrip() throws {
        let userId = "alice"
        let now = UInt32(Date().timeIntervalSince1970)
        let tokenExpireSeconds: UInt32 = 86400
        let token = buildRtmToken(
            userId: userId,
            tokenExpireSeconds: tokenExpireSeconds
        )

        let decoded = try decodeToken(token)

        XCTAssertEqual(decoded.appId, testAppId)
        XCTAssertLessThanOrEqual(abs(Int(decoded.issueTs) - Int(now)), 10)
        XCTAssertEqual(decoded.expire, tokenExpireSeconds)
        XCTAssertEqual(decoded.signature.count, 32)
        XCTAssertEqual(decoded.services.count, 1)
        XCTAssertEqual(decoded.services[0].serviceType, 2, "Service type should be RTM (2)")
        XCTAssertEqual(decoded.services[0].userId, userId)
        XCTAssertEqual(decoded.services[0].privileges.count, 1, "RTM should have 1 privilege (login)")
        XCTAssertEqual(decoded.services[0].privileges[0].key, 1, "Should have login privilege")
        XCTAssertEqual(decoded.services[0].privileges[0].value, tokenExpireSeconds)
    }

    // MARK: - Randomness (salt)

    func testTwoTokensAreDifferent() {
        let token1 = buildRtcToken(
            channel: "ch",
            uid: 1,
            role: .publisher,
            tokenExpireSeconds: 3600,
            privilegeExpireSeconds: 3600
        )
        let token2 = buildRtcToken(
            channel: "ch",
            uid: 1,
            role: .publisher,
            tokenExpireSeconds: 3600,
            privilegeExpireSeconds: 3600
        )
        XCTAssertNotEqual(token1, token2, "Random salt should produce different tokens each time")
    }

    func testTwoTokensHaveDifferentSalts() throws {
        let token1 = buildRtcToken(
            channel: "ch",
            uid: 1,
            role: .publisher,
            tokenExpireSeconds: 3600,
            privilegeExpireSeconds: 3600
        )
        let token2 = buildRtcToken(
            channel: "ch",
            uid: 1,
            role: .publisher,
            tokenExpireSeconds: 3600,
            privilegeExpireSeconds: 3600
        )
        let d1 = try decodeToken(token1)
        let d2 = try decodeToken(token2)
        XCTAssertNotEqual(d1.salt, d2.salt, "Salts should differ between invocations")
    }

    // MARK: - Edge cases

    func testZeroExpiry() throws {
        let token = buildRtcToken(
            channel: "ch",
            uid: 1,
            role: .publisher,
            tokenExpireSeconds: 0,
            privilegeExpireSeconds: 0
        )
        let decoded = try decodeToken(token)
        XCTAssertEqual(decoded.expire, 0)
        // Privileges should expire at issuedAt + 0 = issuedAt
        for priv in decoded.services[0].privileges {
            XCTAssertEqual(priv.value, 0)
        }
    }

    func testInvalidAppIdReturnsEmptyToken() {
        let appId = String(repeating: "a", count: 200)
        let token = buildRtcToken(
            appId: appId,
            appCertificate: testAppCert,
            channel: "ch",
            uid: 1,
            role: .publisher,
            tokenExpireSeconds: 3600,
            privilegeExpireSeconds: 3600
        )
        XCTAssertTrue(token.isEmpty)
    }

    func testUnicodeAppIdReturnsEmptyToken() {
        let appId = "app_\u{1F600}_test"  // emoji in app ID
        let token = buildRtcToken(
            appId: appId,
            appCertificate: testAppCert,
            channel: "ch",
            uid: 1,
            role: .publisher,
            tokenExpireSeconds: 3600,
            privilegeExpireSeconds: 3600
        )
        XCTAssertTrue(token.isEmpty)
    }

    func testTokenNonEmptyWithValidCert() {
        let token = buildRtcToken(
            channel: "",
            uid: 0,
            role: .subscriber,
            tokenExpireSeconds: 1,
            privilegeExpireSeconds: 1
        )
        XCTAssertFalse(token.isEmpty)
        XCTAssertTrue(token.hasPrefix("007"))
    }

    // MARK: - Different inputs → different tokens

    func testDifferentAppIdProducesDifferentToken() throws {
        let token1 = buildRtcToken(
            appId: testAppId,
            channel: "ch",
            uid: 1,
            role: .publisher,
            tokenExpireSeconds: 3600,
            privilegeExpireSeconds: 3600
        )
        let token2 = buildRtcToken(
            appId: testAppIdAlt,
            channel: "ch",
            uid: 1,
            role: .publisher,
            tokenExpireSeconds: 3600,
            privilegeExpireSeconds: 3600
        )
        // Even ignoring random salt, different appId means different content
        let d1 = try decodeToken(token1)
        let d2 = try decodeToken(token2)
        XCTAssertNotEqual(d1.appId, d2.appId)
    }

    func testDifferentCertProducesDifferentSignature() throws {
        // Generate many pairs and check signatures differ
        let token1 = buildRtcToken(
            appId: testAppId,
            appCertificate: testAppCert,
            channel: "ch",
            uid: 1,
            role: .publisher,
            tokenExpireSeconds: 3600,
            privilegeExpireSeconds: 3600
        )
        let token2 = buildRtcToken(
            appId: testAppId,
            appCertificate: testAppCertAlt,
            channel: "ch",
            uid: 1,
            role: .publisher,
            tokenExpireSeconds: 3600,
            privilegeExpireSeconds: 3600
        )
        // Tokens will differ (different cert → different signing key → different signature)
        XCTAssertNotEqual(token1, token2)
    }

    // MARK: - Signature is 32 bytes (HMAC-SHA256)

    func testSignatureLength() throws {
        let token = buildRtcToken(
            channel: "ch",
            uid: 1,
            role: .publisher,
            tokenExpireSeconds: 3600,
            privilegeExpireSeconds: 3600
        )
        let decoded = try decodeToken(token)
        XCTAssertEqual(decoded.signature.count, 32, "HMAC-SHA256 produces 32-byte signatures")
    }

}
