import AtemClient
import CryptoKit
import Foundation
import Security

public enum RemoteDeviceIdentityError: Error, Equatable {
    case invalidIdentity
    case secureHardwareUnavailable
    case storageUncertain
}

public struct RemoteDevicePublicIdentity: Equatable, Sendable {
    public let deviceID: String
    public let authKey: PublicKeyData
    public let encryptionKey: PublicKeyData
}

struct RemoteAppleIdentityMaterial: Codable {
    let signingHandle: Data
    let wrappingHandle: Data
    let wrappingPublicKey: Data
    let sealedEncryptionKey: Data
    let encryptionPublicKey: Data
}

protocol RemoteAppleIdentityCryptography {
    func create() throws -> RemoteAppleIdentityMaterial
    func validate(_ material: RemoteAppleIdentityMaterial) throws -> (auth: Data, encryption: Data)
    func sign(_ input: Data, material: RemoteAppleIdentityMaterial) throws -> Data
    func sharedSecret(_ peer: Data, material: RemoteAppleIdentityMaterial) throws -> Data
    func open(enc: Data, ct: Data, info: Data, aad: Data, material: RemoteAppleIdentityMaterial) throws -> Data
}

private struct EnclaveDeviceCryptography: RemoteAppleIdentityCryptography {
    let scope: String

    func create() throws -> RemoteAppleIdentityMaterial {
        guard SecureEnclave.isAvailable else { throw RemoteDeviceIdentityError.secureHardwareUnavailable }
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, nil) else {
            throw RemoteDeviceIdentityError.invalidIdentity
        }
        let signing = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
        let wrapping = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let encryption = Curve25519.KeyAgreement.PrivateKey()
        let key = wrappingKey(try ephemeral.sharedSecretFromKeyAgreement(with: wrapping.publicKey))
        let sealed = try AES.GCM.seal(encryption.rawRepresentation, using: key)
        guard let combined = sealed.combined else { throw RemoteDeviceIdentityError.invalidIdentity }
        return RemoteAppleIdentityMaterial(signingHandle: signing.dataRepresentation, wrappingHandle: wrapping.dataRepresentation,
            wrappingPublicKey: ephemeral.publicKey.x963Representation, sealedEncryptionKey: combined,
            encryptionPublicKey: encryption.publicKey.rawRepresentation)
    }

    func validate(_ material: RemoteAppleIdentityMaterial) throws -> (auth: Data, encryption: Data) {
        let auth = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: material.signingHandle).publicKey.x963Representation
        return (auth, try encryptionKey(material).publicKey.rawRepresentation)
    }

    func sign(_ input: Data, material: RemoteAppleIdentityMaterial) throws -> Data {
        try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: material.signingHandle).signature(for: input).rawRepresentation
    }

    func sharedSecret(_ peer: Data, material: RemoteAppleIdentityMaterial) throws -> Data {
        let key = try encryptionKey(material)
        let secret = try key.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer))
        return secret.withUnsafeBytes { Data($0) }
    }

    func open(enc: Data, ct: Data, info: Data, aad: Data, material: RemoteAppleIdentityMaterial) throws -> Data {
        var recipient = try HPKE.Recipient(privateKey: encryptionKey(material), ciphersuite: .Curve25519_SHA256_ChachaPoly,
            info: info, encapsulatedKey: enc)
        return try recipient.open(ct, authenticating: aad)
    }

    private func encryptionKey(_ material: RemoteAppleIdentityMaterial) throws -> Curve25519.KeyAgreement.PrivateKey {
        let wrapping = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: material.wrappingHandle)
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: material.wrappingPublicKey)
        let key = wrappingKey(try wrapping.sharedSecretFromKeyAgreement(with: peer))
        let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: material.sealedEncryptionKey), using: key)
        let encryption = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        guard encryption.publicKey.rawRepresentation == material.encryptionPublicKey else {
            throw RemoteDeviceIdentityError.invalidIdentity
        }
        return encryption
    }

    private func wrappingKey(_ shared: SharedSecret) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(),
            sharedInfo: encodeFields(fields: [Data("astation-native-device-key-v1".utf8), Data(scope.utf8)]), outputByteCount: 32)
    }
}

/// Native-only immutable device identity. Creation grants no membership or account access.
/// There is no software signing fallback when Secure Enclave is unavailable.
@MainActor
public final class RemoteAppleDeviceIdentity {
    private struct Stored: Codable {
        let version: Int
        let issuer: String
        let accountID: String
        let deviceID: String
        let authPublicKey: Data
        let material: RemoteAppleIdentityMaterial
    }

    public let publicIdentity: RemoteDevicePublicIdentity
    private let issuer: String
    private let accountID: String
    private let material: RemoteAppleIdentityMaterial
    private let crypto: RemoteAppleIdentityCryptography
    private let read: () throws -> Data?
    private let saved: Data
    public private(set) var storageUncertain = false

    public convenience init(issuer: String, accountID: String) throws {
        let scope = try Self.scope(issuer: issuer, accountID: accountID)
        let store = try RemoteRecoveryStore(accountID: scope, operation: "device-identity")
        try self.init(issuer: issuer, accountID: accountID, crypto: EnclaveDeviceCryptography(scope: scope),
            read: { try store.read() }, write: { try store.write($0) })
    }

    init(issuer: String, accountID: String, crypto: RemoteAppleIdentityCryptography,
        read: @escaping () throws -> Data?, write: (Data) throws -> Void) throws {
        _ = try Self.scope(issuer: issuer, accountID: accountID)
        let record: Stored
        let bytes: Data
        if let previous = try read() {
            guard previous.count <= 65_536 else { throw RemoteDeviceIdentityError.invalidIdentity }
            record = try PropertyListDecoder().decode(Stored.self, from: previous)
            bytes = previous
        } else {
            let generated = try crypto.create()
            let publicKeys = try crypto.validate(generated)
            record = Stored(version: 1, issuer: issuer, accountID: accountID, deviceID: "astation-" + UUID().uuidString,
                authPublicKey: publicKeys.auth, material: generated)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            bytes = try encoder.encode(record)
            try write(bytes)
            guard try read() == bytes else { throw RemoteDeviceIdentityError.storageUncertain }
        }
        guard record.version == 1, record.issuer == issuer, record.accountID == accountID,
              RemoteRecoveryKit.validID(record.deviceID), record.deviceID != "recovery" else {
            throw RemoteDeviceIdentityError.invalidIdentity
        }
        let keys = try crypto.validate(record.material)
        guard keys.auth == record.authPublicKey else { throw RemoteDeviceIdentityError.invalidIdentity }
        let auth = PublicKeyData(alg: .p256, raw: keys.auth)
        let encryption = PublicKeyData(alg: .x25519, raw: keys.encryption)
        try checkPublicKey(key: auth)
        try checkPublicKey(key: encryption)
        publicIdentity = RemoteDevicePublicIdentity(deviceID: record.deviceID, authKey: auth, encryptionKey: encryption)
        self.issuer = issuer
        self.accountID = accountID
        material = record.material
        self.crypto = crypto
        self.read = read
        saved = bytes
    }

    /// Uses the existing five-minute owner gate, invalidated by the caller on lock/background.
    /// Every network signature still binds the SDK's exact channel transcript.
    public func channelSigner(now: @escaping () -> UInt64, active: @escaping () -> Bool,
        waitForForeground: @escaping (RemoteOwnerAuthenticationStage) async throws -> Void = { _ in },
        confirm: @escaping () async -> Bool) -> RemoteRoutineChannelSigner {
        RemoteRoutineChannelSigner(keyID: publicIdentity.deviceID, now: now, active: active,
            waitForForeground: waitForForeground, confirm: confirm, sign: { [self] request in
                try checkStorage()
                return try RemoteP256Signature.normalize(crypto.sign(request.input, material: material))
            })
    }

    /// A fresh, separate confirmation proves these exact applicant keys. Routine
    /// channel consent cannot authorize this application-level enrollment proof.
    public func enrollmentRequest(invitation: RemoteDeviceEnrollmentInvitation, station: String, deviceName: String,
        now: () -> HostClock, current: () -> Bool, confirm: () async -> Bool,
        persist: (RemoteDeviceEnrollmentRequest) throws -> Void) async throws -> RemoteDeviceEnrollmentRequest {
        func check() throws {
            try Task.checkCancellation()
            guard current() else { throw RemoteChannelError.staleLink }
            try invitation.validate(issuer: issuer, owner: accountID, station: station, now: now())
            try checkStorage()
        }
        try check()
        guard await confirm() else { throw RemoteOwnerAuthenticationError.denied }
        try check()
        let request = try RemoteDeviceEnrollmentRequest.make(invitation: invitation, identity: publicIdentity,
            name: deviceName, now: now(), sign: { try crypto.sign($0, material: material) })
        try persist(request)
        try check()
        return request
    }

    public func sharedSecret(peer: Data) throws -> Data {
        try checkStorage()
        guard peer.count == 32 else { throw RemoteChannelError.invalidInput }
        return try crypto.sharedSecret(peer, material: material)
    }

    func validateEnrollmentContext(_ invitation: RemoteDeviceEnrollmentInvitation, now: HostClock) throws {
        try checkStorage()
        try invitation.validate(issuer: issuer, owner: accountID, station: invitation.station, now: now)
    }

    public func open(enc: Data, ciphertext: Data, info: Data, aad: Data) throws -> Data {
        try checkStorage()
        guard enc.count == 32, (16...262_144).contains(ciphertext.count), info.count <= 65_536, aad.count <= 65_536 else {
            throw RemoteChannelError.invalidInput
        }
        return try crypto.open(enc: enc, ct: ciphertext, info: info, aad: aad, material: material)
    }

    private func checkStorage() throws {
        guard !storageUncertain else { throw RemoteDeviceIdentityError.storageUncertain }
        do {
            guard try read() == saved else { throw RemoteDeviceIdentityError.storageUncertain }
        } catch {
            storageUncertain = true
            throw error
        }
    }

    private static func scope(issuer: String, accountID: String) throws -> String {
        guard PortalIntegrationRecord.validOrigin(issuer), RemoteRecoveryKit.validID(accountID) else {
            throw RemoteDeviceIdentityError.invalidIdentity
        }
        return hashFields(fields: ["astation-native-device-identity-v1", issuer, accountID].map { Data($0.utf8) })
    }
}
