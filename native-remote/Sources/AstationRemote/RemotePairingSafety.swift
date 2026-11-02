import AtemClient
import CryptoKit
import Foundation

/// Required r9 reveal fields. The older ceremony fields are base64; the channel key is base64url.
public struct RemotePairingReveal: Equatable, Sendable {
    public let devicePublicKey: Data
    public let deviceSigningPublicKey: Data
    public let unlockAuthPublicKey: Data
    public let hostChannelPublicKey: Data
    public let nonce: Data

    public init(originalJSON: Data) throws {
        guard originalJSON.count <= 65_536, let raw = String(data: originalJSON, encoding: .utf8) else {
            throw RemoteChannelError.invalidInput
        }
        // The shared reader rejects duplicate keys before Foundation touches the object.
        let canonical = try canonicalJson(json: raw)
        guard let object = try JSONSerialization.jsonObject(with: Data(canonical.utf8)) as? [String: Any],
              object["type"] as? String == "verifyReveal", let fields = object["data"] as? [String: Any],
              Set(fields.keys) == ["device_pub", "device_sign_pub", "unlock_auth_pub", "host_channel_pub", "nonce"],
              let host = fields["host_channel_pub"] as? String,
              let hostKey = RemoteRecoveryKit.decodeBase64URL(host, count: 32) else { throw RemoteChannelError.invalidInput }
        devicePublicKey = try Self.base64(fields["device_pub"])
        deviceSigningPublicKey = try Self.base64(fields["device_sign_pub"])
        unlockAuthPublicKey = try Self.base64(fields["unlock_auth_pub"])
        hostChannelPublicKey = hostKey
        nonce = try Self.base64(fields["nonce"])
        try checkPublicKey(key: PublicKeyData(alg: .x25519, raw: devicePublicKey))
        _ = try Curve25519.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: devicePublicKey))
        for key in [deviceSigningPublicKey, unlockAuthPublicKey, hostChannelPublicKey] {
            try checkPublicKey(key: PublicKeyData(alg: .ed25519, raw: key))
        }
    }

    public func commitment() throws -> Data {
        try Self.hash([Data("atem-verify-commit-v1".utf8), devicePublicKey, deviceSigningPublicKey,
            unlockAuthPublicKey, hostChannelPublicKey, nonce])
    }

    public func safetyCode(keys: RemotePairingKeys) throws -> String {
        let digest = try Self.hash([Data("atem-safety-code-v2".utf8), devicePublicKey, deviceSigningPublicKey,
            unlockAuthPublicKey, hostChannelPublicKey, keys.signingPublicKey, keys.encryptionPublicKey,
            keys.recoverySigningPublicKey, Data(hexHash: keys.genesisHash), nonce, keys.nonce])
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var accumulator: UInt32 = 0
        var bits = 0
        var code = ""
        for byte in digest {
            accumulator = (accumulator << 8) | UInt32(byte)
            bits += 8
            while bits >= 5, code.count < 12 {
                bits -= 5
                code.append(alphabet[Int((accumulator >> bits) & 31)])
            }
            if code.count == 12 { break }
        }
        let raw = Array(code)
        return stride(from: 0, to: 12, by: 4).map { String(raw[$0..<$0 + 4]) }.joined(separator: "-")
    }

    public func transcript(keys: RemotePairingKeys) throws -> Data {
        try Self.hash([Data("atem-verify-transcript-v1".utf8), commitment(), nonce, keys.nonce])
    }

    private static func base64(_ value: Any?) throws -> Data {
        guard let text = value as? String, let data = Data(base64Encoded: text), data.count == 32,
              data.base64EncodedString() == text else { throw RemoteChannelError.invalidInput }
        return data
    }

    private static func hash(_ fields: [Data]) throws -> Data {
        var encoded = Data()
        for field in fields {
            guard let length = UInt32(exactly: field.count) else { throw RemoteChannelError.invalidInput }
            var value = length.bigEndian
            withUnsafeBytes(of: &value) { encoded.append(contentsOf: $0) }
            encoded.append(field)
        }
        return Data(SHA256.hash(data: encoded))
    }
}

public struct RemotePairingKeys: Equatable, Sendable {
    public let signingPublicKey: Data
    public let encryptionPublicKey: Data
    public let recoverySigningPublicKey: Data
    public let genesisHash: String
    public let nonce: Data

    public init(signingPublicKey: Data, encryptionPublicKey: Data, recoverySigningPublicKey: Data,
        genesisHash: String, nonce: Data) throws {
        guard RemoteRecoveryKit.validHash(genesisHash), nonce.count == 32 else { throw RemoteChannelError.invalidInput }
        try checkPublicKey(key: PublicKeyData(alg: .p256, raw: signingPublicKey))
        try checkPublicKey(key: PublicKeyData(alg: .x25519, raw: encryptionPublicKey))
        _ = try Curve25519.KeyAgreement.PrivateKey().sharedSecretFromKeyAgreement(
            with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: encryptionPublicKey))
        try checkPublicKey(key: PublicKeyData(alg: .ed25519, raw: recoverySigningPublicKey))
        self.signingPublicKey = signingPublicKey
        self.encryptionPublicKey = encryptionPublicKey
        self.recoverySigningPublicKey = recoverySigningPublicKey
        self.genesisHash = genesisHash
        self.nonce = nonce
    }

    public func wireJSON() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "verifyKeys", "data": [
            "sign_pub": signingPublicKey.base64EncodedString(), "enc_pub": encryptionPublicKey.base64EncodedString(),
            "recovery_sign_pub": recoverySigningPublicKey.base64EncodedString(), "genesis_hash": genesisHash,
            "nonce": nonce.base64EncodedString()]])
    }

    /// The final chain must end at this attempt's exact host entry, signed by this manager.
    public func membershipEntries(log: MembershipLog, managerID: String, commit: RemotePairingCommit,
        reveal: RemotePairingReveal) throws -> [String] {
        guard commit.context.accountID == log.accountId(), log.genesisHash() == genesisHash,
              log.frozen() == nil, let manager = log.member(deviceId: managerID), manager.status == .active,
              manager.authKey == PublicKeyData(alg: .p256, raw: signingPublicKey), manager.roles.contains("manage"),
              manager.encKey == PublicKeyData(alg: .x25519, raw: encryptionPublicKey),
              log.recoveryKey() == PublicKeyData(alg: .ed25519, raw: recoverySigningPublicKey),
              let host = log.host(hostId: commit.context.hostID), host.hostTrustGen == commit.hostTrustGeneration,
              host.hostKey == PublicKeyData(alg: .ed25519, raw: reveal.hostChannelPublicKey),
              try reveal.commitment() == commit.commitment, let last = log.entries().last else {
            throw RemoteChannelError.invalidInput
        }
        let info = try signedObjectInfo(json: last)
        let body = try JSONSerialization.jsonObject(with: Data(info.bodyJcs.utf8)) as? [String: Any]
        let entryHost = body?["host"] as? [String: Any]
        guard body?["action"] as? String == "add_host", body?["signer"] as? String == managerID,
              entryHost?["host_id"] as? String == commit.context.hostID else { throw RemoteChannelError.invalidInput }
        return log.entries()
    }
}

private extension Data {
    init(hexHash: String) {
        self.init(stride(from: 0, to: hexHash.count, by: 2).map { offset in
            let start = hexHash.index(hexHash.startIndex, offsetBy: offset)
            return UInt8(hexHash[start..<hexHash.index(start, offsetBy: 2)], radix: 16)!
        })
    }
}
