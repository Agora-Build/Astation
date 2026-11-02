import Foundation
import AstationRemote

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
    let hostTrustGeneration: UInt64

    static let generationKey = CodingUserInfoKey(rawValue: "atemVerifiedHostTrustGeneration")!

    init(deviceId: String, commitment: Data, hostTrustGeneration: UInt64) {
        self.deviceId = deviceId
        self.commitment = commitment
        self.hostTrustGeneration = hostTrustGeneration
    }

    init(from decoder: Decoder) throws {
        guard let generation = decoder.userInfo[Self.generationKey] as? UInt64 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "Verification commits require original-packet validation"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try values.decode(String.self, forKey: .deviceId)
        commitment = try values.decode(Data.self, forKey: .commitment)
        hostTrustGeneration = generation
    }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case commitment
        case hostTrustGeneration = "host_trust_gen"
    }
}

struct AtemVerifyKeys: Codable, Equatable {
    let signPub: Data
    let encPub: Data
    let recoverySignPub: Data
    let nonce: Data
    var genesisHash: String? = nil

    func remote() throws -> RemotePairingKeys {
        guard let genesisHash else { throw AtemIdentityError.invalidState }
        return try RemotePairingKeys(signingPublicKey: signPub, encryptionPublicKey: encPub,
            recoverySigningPublicKey: recoverySignPub, genesisHash: genesisHash, nonce: nonce)
    }

    enum CodingKeys: String, CodingKey {
        case signPub = "sign_pub"
        case encPub = "enc_pub"
        case recoverySignPub = "recovery_sign_pub"
        case nonce
        case genesisHash = "genesis_hash"
    }
}

struct AtemVerifyReveal: Codable, Equatable {
    let devicePub: Data
    let deviceSignPub: Data
    let unlockAuthPub: Data
    let nonce: Data
    var hostChannelPub: Data? = nil

    init(devicePub: Data, deviceSignPub: Data, unlockAuthPub: Data, nonce: Data, hostChannelPub: Data? = nil) {
        self.devicePub = devicePub
        self.deviceSignPub = deviceSignPub
        self.unlockAuthPub = unlockAuthPub
        self.nonce = nonce
        self.hostChannelPub = hostChannelPub
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        devicePub = try values.decode(Data.self, forKey: .devicePub)
        deviceSignPub = try values.decode(Data.self, forKey: .deviceSignPub)
        unlockAuthPub = try values.decode(Data.self, forKey: .unlockAuthPub)
        nonce = try values.decode(Data.self, forKey: .nonce)
        let text = try values.decode(String.self, forKey: .hostChannelPub)
        guard let key = Data(base64Encoded: text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "=") else { throw AtemIdentityError.invalidState }
        hostChannelPub = key
        _ = try remote()
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(devicePub, forKey: .devicePub)
        try values.encode(deviceSignPub, forKey: .deviceSignPub)
        try values.encode(unlockAuthPub, forKey: .unlockAuthPub)
        try values.encode(nonce, forKey: .nonce)
        if let hostChannelPub {
            try values.encode(hostChannelPub.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""), forKey: .hostChannelPub)
        }
    }

    func remote() throws -> RemotePairingReveal {
        let data = try JSONEncoder().encode(self)
        let fields = try JSONSerialization.jsonObject(with: data)
        return try RemotePairingReveal(originalJSON: JSONSerialization.data(withJSONObject: ["type": "verifyReveal", "data": fields]))
    }

    enum CodingKeys: String, CodingKey {
        case devicePub = "device_pub"
        case deviceSignPub = "device_sign_pub"
        case unlockAuthPub = "unlock_auth_pub"
        case nonce
        case hostChannelPub = "host_channel_pub"
    }

    func commitment() throws -> Data {
        if hostChannelPub != nil { return try remote().commitment() }
        return try AtemE2ECrypto.commitment(
            devicePublicKey: devicePub, deviceSigningPublicKey: deviceSignPub,
            unlockAuthPublicKey: unlockAuthPub, nonce: nonce
        )
    }

    func safetyCode(keys: AtemVerifyKeys) throws -> String {
        if hostChannelPub != nil { return try remote().safetyCode(keys: keys.remote()) }
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
    var membership: AtemVerifiedMembership? = nil

    enum CodingKeys: String, CodingKey {
        case deviceVerified = "device_verified"
        case accountState = "account_state"
        case grants
        case membership
    }
}

struct AtemVerifiedMembership: Codable, Equatable {
    let entries: [AtemSessionJSON]

    init(entries: [String]) throws {
        self.entries = try entries.map { try AtemSessionJSON.validatePacket(Data($0.utf8)) }
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

    static func number(_ value: UInt64) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }
}
