import XCTest

@testable import Menubar

final class RTCJoinOptionsTests: XCTestCase {
    func testManualJoinDefaultsUseAes256Gcm2AndNoFence() {
        XCTAssertEqual(RTCEncryptionMode.manualJoinDefault, .aes256Gcm2)
        XCTAssertEqual(RTCGeoFence.manualJoinDefault, .noFence)
    }

    func testManualGeoFencePickerMatchesExpectedDocLabels() {
        XCTAssertEqual(
            RTCGeoFence.manualJoinPickerOptions,
            [.noFence, .northAmerica, .asia, .mainlandChina, .europe, .japan, .india]
        )
        XCTAssertEqual(RTCGeoFence.noFence.title, "Global (Default)")
        XCTAssertEqual(RTCGeoFence.asia.title, "Asia Pacific")
        XCTAssertEqual(RTCGeoFence.mainlandChina.title, "Mainland China")
    }

    func testGeneratedSaltHexParsesTo32Bytes() throws {
        let saltHex = RTCEncryptionConfiguration.generateSaltHex()

        XCTAssertEqual(saltHex.count, 64)

        let config = try XCTUnwrap(
            RTCEncryptionConfiguration.make(
                mode: .aes256Gcm2,
                key: "shared-secret",
                salt: saltHex
            )
        )
        XCTAssertEqual(config.saltBytes.count, 32)
    }

    func testSaltParsingAcceptsUppercaseAndSeparators() throws {
        let saltHex = "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99-" +
            "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"

        let config = try XCTUnwrap(
            RTCEncryptionConfiguration.make(
                mode: .aes128Gcm2,
                key: "shared-secret",
                salt: saltHex
            )
        )

        XCTAssertEqual(config.saltBytes.count, 32)
        XCTAssertEqual(config.saltBytes[0], 0xAA)
        XCTAssertEqual(config.saltBytes[31], 0x99)
    }

    func testBase64SaltWithSlashParsesTo32Bytes() throws {
        let saltData = Data(repeating: 0xFF, count: 32)
        let saltBase64 = saltData.base64EncodedString()
        XCTAssertTrue(saltBase64.contains("/"))

        let config = try XCTUnwrap(
            RTCEncryptionConfiguration.make(
                mode: .aes256Gcm2,
                key: "shared-secret",
                salt: saltBase64
            )
        )

        XCTAssertEqual(config.saltBytes, Array(saltData))
    }

    func testNonSaltModeIgnoresSalt() throws {
        let config = try XCTUnwrap(
            RTCEncryptionConfiguration.make(
                mode: .aes256Gcm,
                key: "shared-secret",
                salt: ""
            )
        )

        XCTAssertTrue(config.saltBytes.isEmpty)
    }

    func testEncryptionRequiresKey() {
        XCTAssertThrowsError(
            try RTCEncryptionConfiguration.make(
                mode: .aes256Gcm2,
                key: "   ",
                salt: RTCEncryptionConfiguration.generateSaltHex()
            )
        ) { error in
            XCTAssertEqual(error as? RTCEncryptionValidationError, .keyRequired)
        }
    }

    func testGcm2Requires32ByteSalt() {
        XCTAssertThrowsError(
            try RTCEncryptionConfiguration.make(
                mode: .aes256Gcm2,
                key: "shared-secret",
                salt: "abcd"
            )
        ) { error in
            XCTAssertEqual(error as? RTCEncryptionValidationError, .saltMustBe32Bytes)
        }
    }

    func testGcm2RejectsNonHexSalt() {
        let invalidSalt = String(repeating: "zz", count: 32)

        XCTAssertThrowsError(
            try RTCEncryptionConfiguration.make(
                mode: .aes128Gcm2,
                key: "shared-secret",
                salt: invalidSalt
            )
        ) { error in
            XCTAssertEqual(error as? RTCEncryptionValidationError, .saltInvalidFormat)
        }
    }
}
