import AtemClient
import Foundation

/// A fresh owner approval authorizes one exact membership body, never a later draft.
public final class RemoteConfirmedSigner: AppKeyProvider, @unchecked Sendable {
    public let request: SignRequest
    private let provider: AppKeyProvider
    private let publicKeyValue: PublicKeyData
    private let lock = NSLock()
    private let now: @Sendable () -> UInt64
    private let deadline: UInt64
    private let confirmedAt: UInt64
    private var consumed = false

    public init(provider: AppKeyProvider, request: SignRequest, confirmedAt: UInt64,
        now: @escaping @Sendable () -> UInt64) throws {
        guard request.freshConfirmation, let body = request.bodyJson,
              confirmedAt <= UInt64.max - 30_000, now() >= confirmedAt,
              now() < confirmedAt + 30_000 else { throw RemoteRecoveryError.confirmationRequired }
        let checked = try Self.membershipRequest(bodyJSON: body, keyID: request.keyId)
        guard request == checked else { throw RemoteChannelError.invalidInput }
        self.request = request
        self.provider = provider
        publicKeyValue = try provider.publicKey(keyId: request.keyId)
        self.now = now
        self.confirmedAt = confirmedAt
        deadline = confirmedAt + 30_000
    }

    public static func membershipRequest(bodyJSON: String, keyID: String) throws -> SignRequest {
        let body = try canonicalJson(json: bodyJSON)
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8))
        guard let fields = object as? [String: Any], let action = fields["action"] as? String else {
            throw RemoteChannelError.invalidInput
        }
        let purpose: SigningPurpose
        switch action {
        case "genesis": purpose = .genesis
        case "add": purpose = .enroll
        case "remove": purpose = .remove
        case "set_roles": purpose = .roles
        case "add_host", "remove_host": purpose = .host
        case "recovery_add", "recovery_approve", "recovery_veto": purpose = .recovery
        case "set_recovery_key": purpose = .kit
        case "k_backup": purpose = .keyBackup
        default: throw RemoteChannelError.invalidInput
        }
        let envelope = try JSONSerialization.data(withJSONObject: ["body": object,
            "sig": RemoteRecoveryKit.base64URL(Data(repeating: 0, count: 64))])
        let info = try signedObjectInfo(json: String(decoding: envelope, as: UTF8.self))
        guard info.bodyType == "atem-membership-entry", info.entryHash != nil else {
            throw RemoteChannelError.invalidInput
        }
        return SignRequest(keyId: keyID, purpose: purpose, freshConfirmation: true,
            label: "atem-membership-entry-v1", input: info.signingInput, bodyJson: info.bodyJcs)
    }

    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        consumed = true
    }

    public func publicKey(keyId: String) throws -> PublicKeyData {
        guard keyId == request.keyId else { throw RemoteChannelError.invalidInput }
        return publicKeyValue
    }

    public func sign(request: SignRequest) throws -> Data {
        lock.lock()
        let time = now()
        guard !consumed, time >= confirmedAt, time < deadline, request == self.request else {
            lock.unlock()
            throw RemoteRecoveryError.confirmationRequired
        }
        consumed = true
        lock.unlock()
        guard try provider.publicKey(keyId: request.keyId) == publicKeyValue else {
            throw RemoteChannelError.invalidInput
        }
        return try provider.sign(request: request)
    }

    public func x25519(keyId: String, peer: Data) throws -> Data { throw RemoteChannelError.invalidInput }
    public func hpkeOpen(keyId: String, enc: Data, ct: Data, info: Data, aad: Data) throws -> Data {
        throw RemoteChannelError.invalidInput
    }
}
