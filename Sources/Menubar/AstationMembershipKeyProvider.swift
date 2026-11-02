import AtemClient
import Foundation

/// Membership signatures use the existing Enclave key. The caller wraps this
/// provider in RemoteConfirmedSigner after confirming its exact stored request.
final class AstationMembershipKeyProvider: AppKeyProvider, @unchecked Sendable {
    let identity: AtemE2EIdentity
    let keyID: String
    let expectedPublicKey: Data

    init(identity: AtemE2EIdentity, keyID: String, publicKey: Data) {
        self.identity = identity
        self.keyID = keyID
        expectedPublicKey = publicKey
    }

    func publicKey(keyId: String) throws -> PublicKeyData {
        guard keyId == keyID, try identity.remotePublicKeys().signing == expectedPublicKey else {
            throw AtemIdentityError.identityChanged
        }
        return PublicKeyData(alg: .p256, raw: expectedPublicKey)
    }

    func sign(request: SignRequest) throws -> Data {
        guard request.keyId == keyID else { throw AtemIdentityError.identityChanged }
        return try identity.signMembership(request, expectedPublicKey: expectedPublicKey)
    }

    func x25519(keyId: String, peer: Data) throws -> Data { throw AtemIdentityError.invalidState }
    func hpkeOpen(keyId: String, enc: Data, ct: Data, info: Data, aad: Data) throws -> Data {
        throw AtemIdentityError.invalidState
    }
}
