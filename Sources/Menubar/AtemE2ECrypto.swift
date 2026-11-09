import AstationRemote
import CryptoKit
import Foundation

enum AtemE2ECryptoError: Error {
    case invalidFieldLength
    case invalidSignatureScalar
}

struct AtemHPKESealedKey: Equatable {
    let encapsulatedKey: Data
    let ciphertext: Data
}

enum AtemE2ECrypto {
    static func base32(_ data: Data) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var result = ""
        var accumulator: UInt32 = 0
        var bits = 0
        for byte in data {
            accumulator = (accumulator << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                result.append(alphabet[Int((accumulator >> bits) & 31)])
            }
        }
        if bits > 0 { result.append(alphabet[Int((accumulator << (5 - bits)) & 31)]) }
        return result
    }

    static func encode(_ fields: [Data]) throws -> Data {
        var result = Data()
        for field in fields {
            guard let length = UInt32(exactly: field.count) else {
                throw AtemE2ECryptoError.invalidFieldLength
            }
            result.append(contentsOf: [
                UInt8(truncatingIfNeeded: length >> 24),
                UInt8(truncatingIfNeeded: length >> 16),
                UInt8(truncatingIfNeeded: length >> 8),
                UInt8(truncatingIfNeeded: length),
            ])
            result.append(field)
        }
        return result
    }

    static func decode(_ bytes: Data, maximumFields: Int) throws -> [Data] {
        let raw = Array(bytes)
        var offset = 0
        var fields: [Data] = []
        while offset < raw.count {
            guard fields.count < maximumFields, raw.count - offset >= 4 else {
                throw AtemE2ECryptoError.invalidFieldLength
            }
            let length = raw[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard length <= raw.count - offset else { throw AtemE2ECryptoError.invalidFieldLength }
            fields.append(Data(raw[offset..<offset + length]))
            offset += length
        }
        return fields
    }

    static func commitment(
        devicePublicKey: Data,
        deviceSigningPublicKey: Data,
        unlockAuthPublicKey: Data,
        nonce: Data
    ) throws -> Data {
        try require32([devicePublicKey, deviceSigningPublicKey, unlockAuthPublicKey, nonce])
        return Data(SHA256.hash(data: try encode([
            Data("atem-verify-commit-v1".utf8), devicePublicKey,
            deviceSigningPublicKey, unlockAuthPublicKey, nonce,
        ])))
    }

    static func transcript(commitment: Data, nonceA: Data, nonceS: Data) throws -> Data {
        try require32([commitment, nonceA, nonceS])
        return Data(SHA256.hash(data: try encode([
            Data("atem-verify-transcript-v1".utf8), commitment, nonceA, nonceS,
        ])))
    }

    static func safetyDigest(
        devicePublicKey: Data,
        deviceSigningPublicKey: Data,
        unlockAuthPublicKey: Data,
        astationSigningPublicKey: Data,
        astationEncryptionPublicKey: Data,
        recoverySigningPublicKey: Data,
        nonceA: Data,
        nonceS: Data
    ) throws -> Data {
        try require32([
            devicePublicKey, deviceSigningPublicKey, unlockAuthPublicKey,
            astationEncryptionPublicKey, recoverySigningPublicKey, nonceA, nonceS,
        ])
        guard astationSigningPublicKey.count == 65 else {
            throw AtemE2ECryptoError.invalidFieldLength
        }
        _ = try P256.Signing.PublicKey(x963Representation: astationSigningPublicKey)
        return Data(SHA256.hash(data: try encode([
            Data("atem-safety-code-v1".utf8), devicePublicKey, deviceSigningPublicKey,
            unlockAuthPublicKey, astationSigningPublicKey, astationEncryptionPublicKey,
            recoverySigningPublicKey, nonceA, nonceS,
        ])))
    }

    static func normalizedP256Signature(_ raw: Data) throws -> Data {
        do { return try RemoteP256Signature.normalize(raw) }
        catch RemoteP256SignatureError.invalidLength { throw AtemE2ECryptoError.invalidFieldLength }
        catch { throw AtemE2ECryptoError.invalidSignatureScalar }
    }

    static func verifyP256Signature(_ raw: Data, message: Data, publicKey: Data) -> Bool {
        guard publicKey.count == 65,
              let normalized = try? normalizedP256Signature(raw), normalized == raw,
              let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else {
            return false
        }
        return key.isValidSignature(signature, for: message)
    }

    static func recoverySigningKey(secret: Data) throws -> Curve25519.Signing.PrivateKey {
        try require32([secret])
        let seed = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data(),
            info: Data("atem-recovery-sign-v1".utf8),
            outputByteCount: 32
        )
        return try seed.withUnsafeBytes {
            try Curve25519.Signing.PrivateKey(rawRepresentation: Data($0))
        }
    }

    static func sealKey(_ key: Data, to recipientPublicKey: Data, info: Data) throws -> AtemHPKESealedKey {
        try require32([key, recipientPublicKey])
        guard !info.isEmpty else { throw AtemE2ECryptoError.invalidFieldLength }
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey)
        var sender = try HPKE.Sender(
            recipientKey: recipient,
            ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: info
        )
        return AtemHPKESealedKey(
            encapsulatedKey: sender.encapsulatedKey,
            ciphertext: try sender.seal(key, authenticating: Data())
        )
    }

    static func sealedKeyDigest(_ sealed: AtemHPKESealedKey) throws -> Data {
        guard sealed.encapsulatedKey.count == 32, sealed.ciphertext.count == 48 else {
            throw AtemE2ECryptoError.invalidFieldLength
        }
        return Data(SHA256.hash(data: try encode([sealed.encapsulatedKey, sealed.ciphertext])))
    }

    private static func require32(_ fields: [Data]) throws {
        guard fields.allSatisfy({ $0.count == 32 }) else {
            throw AtemE2ECryptoError.invalidFieldLength
        }
    }
}
