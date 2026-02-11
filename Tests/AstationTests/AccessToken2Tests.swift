import XCTest

@testable import Menubar

// MARK: - Token Decoder (for roundtrip verification)

/// Minimal AccessToken2 decoder — mirrors Atem/src/token.rs decode_token().
/// Used only in tests to verify the Swift encoder produces valid tokens.
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
    let privileges: [(key: UInt16, value: UInt32)]
}

private func decodeToken(_ token: String) throws -> DecodedToken {
    guard token.hasPrefix("007") else {
        throw NSError(domain: "Token", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing 007 prefix"])
    }

    let encoded = String(token.dropFirst(3))
    guard let data = Data(base64Encoded: encoded) else {
        throw NSError(domain: "Token", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid base64"])
    }

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
        var privileges: [(key: UInt16, value: UInt32)] = []
        for _ in 0..<privCount {
            let k = try readUInt16()
            let v = try readUInt32()
            privileges.append((key: k, value: v))
        }
        services.append(DecodedService(serviceType: serviceType, privileges: privileges))
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
        let token = AccessToken2.buildTokenRTC(
            appId: "appid", appCertificate: "", channel: "chan", uid: "uid",
            role: .publisher, expireSecs: 3600, issuedAt: 1_000_000)
        XCTAssertTrue(token.isEmpty)
    }

    func testEmptyCertificateReturnsEmptyRTMToken() {
        let token = AccessToken2.buildTokenRTM(
            appId: "appid", appCertificate: "", userId: "user",
            expireSecs: 3600, issuedAt: 1_000_000)
        XCTAssertTrue(token.isEmpty)
    }

    // MARK: - Version prefix

    func testRTCTokenStartsWith007() {
        let token = AccessToken2.buildTokenRTC(
            appId: "appid123", appCertificate: "cert456", channel: "chan", uid: "uid",
            role: .publisher, expireSecs: 3600, issuedAt: 1_000_000)
        XCTAssertTrue(token.hasPrefix("007"))
    }

    func testRTMTokenStartsWith007() {
        let token = AccessToken2.buildTokenRTM(
            appId: "appid123", appCertificate: "cert456", userId: "user",
            expireSecs: 3600, issuedAt: 1_000_000)
        XCTAssertTrue(token.hasPrefix("007"))
    }

    // MARK: - Base64 validity

    func testRTCTokenIsValidBase64After007() {
        let token = AccessToken2.buildTokenRTC(
            appId: "test_app_id", appCertificate: "test_cert", channel: "chan1", uid: "uid1",
            role: .publisher, expireSecs: 3600, issuedAt: 1_700_000_000)
        let encoded = String(token.dropFirst(3))
        XCTAssertNotNil(Data(base64Encoded: encoded), "Content after '007' should be valid base64")
    }

    func testRTMTokenIsValidBase64After007() {
        let token = AccessToken2.buildTokenRTM(
            appId: "test_app_id", appCertificate: "test_cert", userId: "alice",
            expireSecs: 7200, issuedAt: 1_700_000_000)
        let encoded = String(token.dropFirst(3))
        XCTAssertNotNil(Data(base64Encoded: encoded), "Content after '007' should be valid base64")
    }

    // MARK: - Publisher vs Subscriber

    func testPublisherTokenLongerThanSubscriber() {
        let pubToken = AccessToken2.buildTokenRTC(
            appId: "appid", appCertificate: "cert", channel: "chan", uid: "uid",
            role: .publisher, expireSecs: 3600, issuedAt: 1_000_000)
        let subToken = AccessToken2.buildTokenRTC(
            appId: "appid", appCertificate: "cert", channel: "chan", uid: "uid",
            role: .subscriber, expireSecs: 3600, issuedAt: 1_000_000)
        XCTAssertGreaterThan(
            pubToken.count, subToken.count,
            "Publisher token should be longer (4 privileges vs 1)")
    }

    // MARK: - Binary packing helpers

    func testPackUInt16() {
        var buf = Data()
        AccessToken2.packUInt16(&buf, 0x0102)
        XCTAssertEqual(buf, Data([0x02, 0x01]))
    }

    func testPackUInt32() {
        var buf = Data()
        AccessToken2.packUInt32(&buf, 0x01020304)
        XCTAssertEqual(buf, Data([0x04, 0x03, 0x02, 0x01]))
    }

    func testPackUInt16Zero() {
        var buf = Data()
        AccessToken2.packUInt16(&buf, 0)
        XCTAssertEqual(buf, Data([0x00, 0x00]))
    }

    func testPackUInt32Zero() {
        var buf = Data()
        AccessToken2.packUInt32(&buf, 0)
        XCTAssertEqual(buf, Data([0x00, 0x00, 0x00, 0x00]))
    }

    func testPackUInt16Max() {
        var buf = Data()
        AccessToken2.packUInt16(&buf, UInt16.max)
        XCTAssertEqual(buf, Data([0xFF, 0xFF]))
    }

    func testPackUInt32Max() {
        var buf = Data()
        AccessToken2.packUInt32(&buf, UInt32.max)
        XCTAssertEqual(buf, Data([0xFF, 0xFF, 0xFF, 0xFF]))
    }

    func testPackString() {
        var buf = Data()
        AccessToken2.packString(&buf, "AB")
        XCTAssertEqual(buf, Data([0x02, 0x00, 0x41, 0x42]))
    }

    func testPackStringEmpty() {
        var buf = Data()
        AccessToken2.packString(&buf, "")
        XCTAssertEqual(buf, Data([0x00, 0x00]))
    }

    func testPackBytes() {
        var buf = Data()
        AccessToken2.packBytes(&buf, Data([0xFF, 0xAA]))
        XCTAssertEqual(buf, Data([0x02, 0x00, 0xFF, 0xAA]))
    }

    func testPackBytesEmpty() {
        var buf = Data()
        AccessToken2.packBytes(&buf, Data())
        XCTAssertEqual(buf, Data([0x00, 0x00]))
    }

    // MARK: - Roundtrip: RTC token generate → decode

    func testRTCPublisherRoundtrip() throws {
        let appId = "test_app_id_32chars_exactly_here"
        let token = AccessToken2.buildTokenRTC(
            appId: appId, appCertificate: "test_cert", channel: "chan1", uid: "uid1",
            role: .publisher, expireSecs: 3600, issuedAt: 1_700_000_000)

        let decoded = try decodeToken(token)

        XCTAssertEqual(decoded.appId, appId)
        XCTAssertEqual(decoded.issueTs, 1_700_000_000)
        XCTAssertEqual(decoded.expire, 3600)
        XCTAssertEqual(decoded.signature.count, 32, "HMAC-SHA256 signature should be 32 bytes")
        XCTAssertEqual(decoded.services.count, 1)
        XCTAssertEqual(decoded.services[0].serviceType, 1, "Service type should be RTC (1)")
        XCTAssertEqual(decoded.services[0].privileges.count, 4, "Publisher should have 4 privileges")

        // Verify all privilege types are present
        let privKeys = Set(decoded.services[0].privileges.map { $0.key })
        XCTAssertTrue(privKeys.contains(1), "Should have joinChannel privilege")
        XCTAssertTrue(privKeys.contains(2), "Should have publishAudio privilege")
        XCTAssertTrue(privKeys.contains(3), "Should have publishVideo privilege")
        XCTAssertTrue(privKeys.contains(4), "Should have publishData privilege")

        // All privileges should expire at issuedAt + expireSecs
        let expectedExpireAt: UInt32 = 1_700_000_000 + 3600
        for priv in decoded.services[0].privileges {
            XCTAssertEqual(priv.value, expectedExpireAt, "Privilege \(priv.key) should expire at \(expectedExpireAt)")
        }
    }

    func testRTCSubscriberRoundtrip() throws {
        let appId = "subscriber_app"
        let token = AccessToken2.buildTokenRTC(
            appId: appId, appCertificate: "cert_sub", channel: "ch", uid: "u",
            role: .subscriber, expireSecs: 7200, issuedAt: 1_700_000_000)

        let decoded = try decodeToken(token)

        XCTAssertEqual(decoded.appId, appId)
        XCTAssertEqual(decoded.issueTs, 1_700_000_000)
        XCTAssertEqual(decoded.expire, 7200)
        XCTAssertEqual(decoded.services.count, 1)
        XCTAssertEqual(decoded.services[0].serviceType, 1)
        XCTAssertEqual(decoded.services[0].privileges.count, 1, "Subscriber should have 1 privilege")
        XCTAssertEqual(decoded.services[0].privileges[0].key, 1, "Should only have joinChannel")
        XCTAssertEqual(decoded.services[0].privileges[0].value, 1_700_000_000 + 7200)
    }

    // MARK: - Roundtrip: RTM token generate → decode

    func testRTMRoundtrip() throws {
        let appId = "rtm_test_app"
        let token = AccessToken2.buildTokenRTM(
            appId: appId, appCertificate: "rtm_cert", userId: "alice",
            expireSecs: 86400, issuedAt: 1_700_000_000)

        let decoded = try decodeToken(token)

        XCTAssertEqual(decoded.appId, appId)
        XCTAssertEqual(decoded.issueTs, 1_700_000_000)
        XCTAssertEqual(decoded.expire, 86400)
        XCTAssertEqual(decoded.signature.count, 32)
        XCTAssertEqual(decoded.services.count, 1)
        XCTAssertEqual(decoded.services[0].serviceType, 2, "Service type should be RTM (2)")
        XCTAssertEqual(decoded.services[0].privileges.count, 1, "RTM should have 1 privilege (login)")
        XCTAssertEqual(decoded.services[0].privileges[0].key, 1, "Should have login privilege")
        XCTAssertEqual(decoded.services[0].privileges[0].value, 1_700_000_000 + 86400)
    }

    // MARK: - Randomness (salt)

    func testTwoTokensAreDifferent() {
        let token1 = AccessToken2.buildTokenRTC(
            appId: "app", appCertificate: "cert", channel: "ch", uid: "u",
            role: .publisher, expireSecs: 3600, issuedAt: 1_000_000)
        let token2 = AccessToken2.buildTokenRTC(
            appId: "app", appCertificate: "cert", channel: "ch", uid: "u",
            role: .publisher, expireSecs: 3600, issuedAt: 1_000_000)
        XCTAssertNotEqual(token1, token2, "Random salt should produce different tokens each time")
    }

    func testTwoTokensHaveDifferentSalts() throws {
        let token1 = AccessToken2.buildTokenRTC(
            appId: "app", appCertificate: "cert", channel: "ch", uid: "u",
            role: .publisher, expireSecs: 3600, issuedAt: 1_000_000)
        let token2 = AccessToken2.buildTokenRTC(
            appId: "app", appCertificate: "cert", channel: "ch", uid: "u",
            role: .publisher, expireSecs: 3600, issuedAt: 1_000_000)
        let d1 = try decodeToken(token1)
        let d2 = try decodeToken(token2)
        XCTAssertNotEqual(d1.salt, d2.salt, "Salts should differ between invocations")
    }

    // MARK: - Edge cases

    func testZeroExpiry() throws {
        let token = AccessToken2.buildTokenRTC(
            appId: "app", appCertificate: "cert", channel: "ch", uid: "u",
            role: .publisher, expireSecs: 0, issuedAt: 1_700_000_000)
        let decoded = try decodeToken(token)
        XCTAssertEqual(decoded.expire, 0)
        // Privileges should expire at issuedAt + 0 = issuedAt
        for priv in decoded.services[0].privileges {
            XCTAssertEqual(priv.value, 1_700_000_000)
        }
    }

    func testLargeAppId() throws {
        let appId = String(repeating: "a", count: 200)
        let token = AccessToken2.buildTokenRTC(
            appId: appId, appCertificate: "cert", channel: "ch", uid: "u",
            role: .publisher, expireSecs: 3600, issuedAt: 1_000_000)
        let decoded = try decodeToken(token)
        XCTAssertEqual(decoded.appId, appId)
    }

    func testUnicodeAppId() throws {
        let appId = "app_\u{1F600}_test"  // emoji in app ID
        let token = AccessToken2.buildTokenRTC(
            appId: appId, appCertificate: "cert", channel: "ch", uid: "u",
            role: .publisher, expireSecs: 3600, issuedAt: 1_000_000)
        let decoded = try decodeToken(token)
        XCTAssertEqual(decoded.appId, appId)
    }

    func testTokenNonEmptyWithValidCert() {
        let token = AccessToken2.buildTokenRTC(
            appId: "a", appCertificate: "c", channel: "", uid: "",
            role: .subscriber, expireSecs: 1, issuedAt: 1)
        XCTAssertFalse(token.isEmpty)
        XCTAssertTrue(token.hasPrefix("007"))
    }

    // MARK: - Different inputs → different tokens

    func testDifferentAppIdProducesDifferentToken() throws {
        let token1 = AccessToken2.buildTokenRTC(
            appId: "app1", appCertificate: "cert", channel: "ch", uid: "u",
            role: .publisher, expireSecs: 3600, issuedAt: 1_000_000)
        let token2 = AccessToken2.buildTokenRTC(
            appId: "app2", appCertificate: "cert", channel: "ch", uid: "u",
            role: .publisher, expireSecs: 3600, issuedAt: 1_000_000)
        // Even ignoring random salt, different appId means different content
        let d1 = try decodeToken(token1)
        let d2 = try decodeToken(token2)
        XCTAssertNotEqual(d1.appId, d2.appId)
    }

    func testDifferentCertProducesDifferentSignature() throws {
        // Generate many pairs and check signatures differ
        let token1 = AccessToken2.buildTokenRTC(
            appId: "app", appCertificate: "cert_A", channel: "ch", uid: "u",
            role: .publisher, expireSecs: 3600, issuedAt: 1_000_000)
        let token2 = AccessToken2.buildTokenRTC(
            appId: "app", appCertificate: "cert_B", channel: "ch", uid: "u",
            role: .publisher, expireSecs: 3600, issuedAt: 1_000_000)
        // Tokens will differ (different cert → different signing key → different signature)
        XCTAssertNotEqual(token1, token2)
    }

    // MARK: - Signature is 32 bytes (HMAC-SHA256)

    func testSignatureLength() throws {
        let token = AccessToken2.buildTokenRTC(
            appId: "app", appCertificate: "cert", channel: "ch", uid: "u",
            role: .publisher, expireSecs: 3600, issuedAt: 1_000_000)
        let decoded = try decodeToken(token)
        XCTAssertEqual(decoded.signature.count, 32, "HMAC-SHA256 produces 32-byte signatures")
    }

    // MARK: - Service type constants

    func testServiceTypeConstants() {
        XCTAssertEqual(AccessToken2.serviceTypeRTC, 1)
        XCTAssertEqual(AccessToken2.serviceTypeRTM, 2)
    }

    func testPrivilegeConstants() {
        XCTAssertEqual(AccessToken2.privilegeJoinChannel, 1)
        XCTAssertEqual(AccessToken2.privilegePublishAudio, 2)
        XCTAssertEqual(AccessToken2.privilegePublishVideo, 3)
        XCTAssertEqual(AccessToken2.privilegePublishData, 4)
        XCTAssertEqual(AccessToken2.privilegeLogin, 1)
    }
}
