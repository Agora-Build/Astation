import Foundation

struct AtemSignedWire: Codable, Equatable {
    let statement: Data
    let signature: Data
}

struct AtemGrantWire: Codable, Equatable {
    let signed: AtemSignedWire
    let encappedKey: Data
    let ciphertext: Data

    enum CodingKeys: String, CodingKey {
        case signed, ciphertext
        case encappedKey = "encapped_key"
    }
}

struct AtemVerifyCommit: Codable, Equatable {
    let deviceId: String
    let commitment: Data

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case commitment
    }
}

struct AtemVerifyKeys: Codable, Equatable {
    let signPub: Data
    let encPub: Data
    let recoverySignPub: Data
    let nonce: Data

    enum CodingKeys: String, CodingKey {
        case signPub = "sign_pub"
        case encPub = "enc_pub"
        case recoverySignPub = "recovery_sign_pub"
        case nonce
    }
}

struct AtemVerifyReveal: Codable, Equatable {
    let devicePub: Data
    let deviceSignPub: Data
    let unlockAuthPub: Data
    let nonce: Data

    enum CodingKeys: String, CodingKey {
        case devicePub = "device_pub"
        case deviceSignPub = "device_sign_pub"
        case unlockAuthPub = "unlock_auth_pub"
        case nonce
    }

    func commitment() throws -> Data {
        try AtemE2ECrypto.commitment(
            devicePublicKey: devicePub, deviceSigningPublicKey: deviceSignPub,
            unlockAuthPublicKey: unlockAuthPub, nonce: nonce
        )
    }

    func safetyCode(keys: AtemVerifyKeys) throws -> String {
        let digest = try AtemE2ECrypto.safetyDigest(
            devicePublicKey: devicePub, deviceSigningPublicKey: deviceSignPub,
            unlockAuthPublicKey: unlockAuthPub, astationSigningPublicKey: keys.signPub,
            astationEncryptionPublicKey: keys.encPub, recoverySigningPublicKey: keys.recoverySignPub,
            nonceA: nonce, nonceS: keys.nonce
        )
        let code = Array(AtemE2ECrypto.base32(digest).prefix(12))
        return stride(from: 0, to: code.count, by: 4).map {
            String(code[$0..<min($0 + 4, code.count)])
        }.joined(separator: "-")
    }
}

struct AtemDeviceVerified: Codable, Equatable {
    let deviceVerified: AtemSignedWire
    let accountState: AtemSignedWire
    let grants: [AtemGrantWire]

    enum CodingKeys: String, CodingKey {
        case deviceVerified = "device_verified"
        case accountState = "account_state"
        case grants
    }
}

enum AtemStatements {
    static func accountState(account: String, mode: String, kid: String?, epoch: UInt64) throws -> Data {
        try AtemE2ECrypto.encode([
            Data("atem-account-state-v1".utf8), Data(account.utf8), number(1),
            Data(mode.utf8), Data((kid ?? "").utf8), number(epoch),
        ])
    }

    static func deviceVerified(
        account: String, deviceId: String, reveal: AtemVerifyReveal, transcript: Data, epoch: UInt64
    ) throws -> Data {
        try AtemE2ECrypto.encode([
            Data("atem-device-verified-v1".utf8), Data(account.utf8), number(1),
            Data(deviceId.utf8), reveal.devicePub, reveal.deviceSignPub, reveal.unlockAuthPub,
            transcript, number(epoch),
        ])
    }

    static func grantInfo(account: String, deviceId: String, devicePub: Data, kid: String) throws -> Data {
        try AtemE2ECrypto.encode([
            Data("atem-grant-info-v1".utf8), Data(account.utf8), Data("K".utf8),
            Data(deviceId.utf8), devicePub, Data(kid.utf8), Data(),
        ])
    }

    static func grant(
        account: String, deviceId: String, devicePub: Data, kid: String, sealedHash: Data
    ) throws -> Data {
        try AtemE2ECrypto.encode([
            Data("atem-grant-v1".utf8), Data(account.utf8), number(1), Data("K".utf8),
            Data(deviceId.utf8), devicePub, Data(kid.utf8), Data(), sealedHash,
        ])
    }

    private static func number(_ value: UInt64) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
}
