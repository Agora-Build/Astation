import CryptoKit
import Foundation

enum AtemMigrationError: LocalizedError {
    case invalidCompletion, staleMigration, revokedDevice, keyUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidCompletion: return "The encryption migration completion is unsigned, invalid, or incomplete. Update Atem and retry migration."
        case .staleMigration: return "This completion belongs to a different encryption migration. Retry with Astation's current signed state."
        case .revokedDevice: return "The reporting device was revoked or verified again. A verified Atem must retry migration."
        case .keyUnavailable: return "The approved encryption key is unavailable. Unlock this Mac and retry."
        }
    }
}

struct AtemMigrationCompletion {
    let account: String
    let deviceId: String
    let target: String
    let kid: String
    let stateEpoch: UInt64
    let proofInput: Data
    let keyProof: Data

    init(_ signed: AtemSignedWire) throws {
        let fields = try AtemStatementReader.fields(signed.statement, label: "atem-migration-complete-v1", count: 10)
        account = try AtemStatementReader.text(fields[1])
        deviceId = try AtemStatementReader.text(fields[3])
        target = try AtemStatementReader.text(fields[4])
        kid = try AtemStatementReader.text(fields[5])
        stateEpoch = try AtemStatementReader.number(fields[6])
        guard try AtemStatementReader.number(fields[2]) == 1,
              ["on", "off"].contains(target), AtemStatementReader.validKid(kid),
              try AtemStatementReader.number(fields[7]) == 7,
              try AtemStatementReader.number(fields[8]) == 0, fields[9].count == 32 else {
            throw AtemMigrationError.invalidCompletion
        }
        proofInput = try AtemE2ECrypto.encode(Array(fields.prefix(9)))
        keyProof = fields[9]
    }

    func verifyKey(_ key: AccountDataKey?) throws {
        guard let key, key.kid == kid, key.key.count == 32 else {
            throw AtemMigrationError.keyUnavailable
        }
        let proofKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key.key),
            salt: Data(), info: Data("atem-migration-proof-v1".utf8), outputByteCount: 32)
        guard HMAC<SHA256>.isValidAuthenticationCode(keyProof, authenticating: proofInput, using: proofKey) else {
            throw AtemMigrationError.invalidCompletion
        }
    }
}

struct AtemAcceptedMigration: Codable, Equatable {
    let completion: AtemSignedWire
    let pin: AtemDevicePin
    let verificationEpoch: UInt64
    let signingPublicKey: Data
    let route: AtemVerificationRoute
}

struct AtemEncryptionMigration: Codable, Equatable {
    let target: String
    let kid: String
    let startEpoch: UInt64
    var accepted: AtemAcceptedMigration?
    var finalState: AtemSignedWire?

    init(state: AtemAccountState) {
        target = state.mode == "enabling" ? "on" : "off"
        kid = state.kid ?? ""
        startEpoch = state.epoch
    }

    func validate(account: String, state: AtemAccountState, signingPublicKey: Data) throws {
        guard ["on", "off"].contains(target), AtemStatementReader.validKid(kid), startEpoch <= state.epoch else {
            throw AtemIdentityError.invalidStoredIdentity
        }
        if let finalState {
            let fields = try AtemStatementReader.fields(finalState.statement, label: "atem-account-state-v1", count: 6)
            guard state.mode == target, state.kid == (target == "off" ? nil : kid),
                  fields[1] == Data(account.utf8), try AtemStatementReader.number(fields[2]) == 1,
                  fields[3] == Data(target.utf8), fields[4] == Data((target == "off" ? "" : kid).utf8),
                  try AtemStatementReader.number(fields[5]) >= startEpoch,
                  try AtemStatementReader.number(fields[5]) <= state.epoch,
                  AtemE2ECrypto.verifyP256Signature(finalState.signature, message: finalState.statement, publicKey: signingPublicKey) else {
                throw AtemIdentityError.invalidStoredIdentity
            }
        } else if state.mode != (target == "on" ? "enabling" : "disabling") || state.kid != kid {
            throw AtemIdentityError.invalidStoredIdentity
        }
        if let accepted {
            let report = try AtemMigrationCompletion(accepted.completion)
            guard accepted.pin.account == account, report.account == account,
                  report.deviceId == accepted.route.deviceId, report.kid == kid, report.target == target,
                  report.stateEpoch >= startEpoch, report.stateEpoch >= accepted.verificationEpoch,
                  report.stateEpoch <= state.epoch else {
                throw AtemIdentityError.invalidStoredIdentity
            }
            try AtemStatementReader.verify(accepted.completion, publicKey: accepted.pin.deviceSignPub)
        }
    }
}

struct AtemMigrationCommit {
    let account: String
    let target: String
    let kid: String
    let signedState: AtemSignedWire
}
