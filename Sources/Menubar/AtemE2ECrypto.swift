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
        guard raw.count == 64 else { throw AtemE2ECryptoError.invalidFieldLength }
        let r = Array(raw.prefix(32))
        let s = Array(raw.suffix(32))
        guard validScalar(r), validScalar(s) else {
            throw AtemE2ECryptoError.invalidSignatureScalar
        }
        var result = Data(r)
        result.append(contentsOf: halfOrder.lexicographicallyPrecedes(s) ? subtract(order, s) : s)
        return result
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

    private static func validScalar(_ scalar: [UInt8]) -> Bool {
        scalar.contains(where: { $0 != 0 }) && scalar.lexicographicallyPrecedes(order)
    }

    // P-256 scalars are unsigned big-endian values; high-S becomes n - S.
    private static func subtract(_ left: [UInt8], _ right: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 32)
        var borrow = 0
        for index in (0..<32).reversed() {
            let difference = Int(left[index]) - Int(right[index]) - borrow
            result[index] = UInt8(truncatingIfNeeded: difference)
            borrow = difference < 0 ? 1 : 0
        }
        return result
    }

    private static let order: [UInt8] = [
        0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84,
        0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51,
    ]

    private static let halfOrder: [UInt8] = [
        0x7f, 0xff, 0xff, 0xff, 0x80, 0x00, 0x00, 0x00,
        0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xde, 0x73, 0x7d, 0x56, 0xd3, 0x8b, 0xcf, 0x42,
        0x79, 0xdc, 0xe5, 0x61, 0x7e, 0x31, 0x92, 0xa8,
    ]
}
