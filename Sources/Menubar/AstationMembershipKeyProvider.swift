import AtemClient
import Foundation

/// Account signatures use the existing Enclave key. The caller wraps this
/// provider in RemoteConfirmedSigner after confirming its exact stored request.
final class AstationMembershipKeyProvider: AppKeyProvider, @unchecked Sendable {
    let identity: AtemE2EIdentity
    let keyID: String
    let expectedPublicKey: Data
    private let controlRecordsAllowed: Bool
    private let authorizeNewMembership: ((SignRequest) throws -> Void)?

    init(identity: AtemE2EIdentity, keyID: String, publicKey: Data, controlRecordsAllowed: Bool = false,
        authorizeNewMembership: ((SignRequest) throws -> Void)? = nil) {
        self.identity = identity
        self.keyID = keyID
        expectedPublicKey = publicKey
        self.controlRecordsAllowed = controlRecordsAllowed
        self.authorizeNewMembership = authorizeNewMembership
    }

    func publicKey(keyId: String) throws -> PublicKeyData {
        guard keyId == keyID, try identity.remotePublicKeys().signing == expectedPublicKey else {
            throw AtemIdentityError.identityChanged
        }
        return PublicKeyData(alg: .p256, raw: expectedPublicKey)
    }

    func sign(request: SignRequest) throws -> Data {
        guard request.keyId == keyID else { throw AtemIdentityError.identityChanged }
        if request.purpose == .controlRecord {
            guard controlRecordsAllowed else { throw AtemIdentityError.invalidState }
            return try identity.signControlRecord(request, expectedPublicKey: expectedPublicKey)
        }
        return try identity.signMembership(request, expectedPublicKey: expectedPublicKey,
            authorizeNewMembership: authorizeNewMembership)
    }

    func x25519(keyId: String, peer: Data) throws -> Data { throw AtemIdentityError.invalidState }
    func hpkeOpen(keyId: String, enc: Data, ct: Data, info: Data, aad: Data) throws -> Data {
        throw AtemIdentityError.invalidState
    }
}
