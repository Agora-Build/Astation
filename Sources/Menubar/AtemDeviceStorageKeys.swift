import CryptoKit
import Foundation

struct AtemHeldStorageKey: Codable, Equatable {
    let kid: String
    let key: Data
    var isValid: Bool { AtemStatementReader.validKid(kid) && key.count == 32 }
}

struct AtemPendingStorageKey: Codable, Equatable {
    let held: AtemHeldStorageKey
    let rotateStatement: Data
    let ack: AtemSignedWire
}

struct AtemDeviceStorageKeys: Codable, Equatable {
    let account: String
    let deviceId: String
    let devicePub: Data
    var current: AtemHeldStorageKey?
    var pending: AtemPendingStorageKey?
    var acked: Set<String> = []
    var lastUnlock: UInt64?

    static func binding(deviceId: String, devicePub: Data) throws -> String {
        let encoded = try AtemE2ECrypto.encode([Data(deviceId.utf8), devicePub])
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    func validate(signingPublicKey: Data) throws {
        guard !account.isEmpty, account.utf8.count <= 256,
              !deviceId.isEmpty, deviceId.utf8.count <= 256, devicePub.count == 32,
              acked.allSatisfy(AtemStatementReader.validKid) else { throw AtemIdentityError.invalidStoredIdentity }
        if let current {
            guard current.isValid, acked.contains(current.kid) else { throw AtemIdentityError.invalidStoredIdentity }
        }
        if let pending {
            let rotate = try AtemStorageRotate(statement: pending.rotateStatement)
            let statement = try AtemStatements.storageAck(account: account, deviceId: deviceId, kid: pending.held.kid)
            guard pending.held.isValid, acked.contains(pending.held.kid), current?.kid != pending.held.kid,
                  rotate.account == account, rotate.deviceId == deviceId, rotate.newKid == pending.held.kid,
                  rotate.oldKid == (current?.kid ?? ""), pending.ack.statement == statement,
                  AtemE2ECrypto.verifyP256Signature(pending.ack.signature, message: statement, publicKey: signingPublicKey) else {
                throw AtemIdentityError.invalidStoredIdentity
            }
        }
    }

    func held(kid: String) -> AtemHeldStorageKey? {
        if current?.kid == kid { return current }
        if pending?.held.kid == kid { return pending?.held }
        return nil
    }

    mutating func promotePending() {
        guard let pending else { return }
        current = pending.held
        self.pending = nil
    }
}

struct AtemUnlockAuthorization {
    let wire: AtemUnlockRequestWire
    let request: AtemUnlockRequest
    let pin: AtemDevicePin
    let signingPublicKey: Data
    let lastUnlock: UInt64?
}

struct AtemStorageKeyStatus: Equatable {
    let currentKid: String?
    let pendingKid: String?
    let lastUnlock: UInt64?
}
