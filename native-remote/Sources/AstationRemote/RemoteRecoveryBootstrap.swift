import AtemClient
import Foundation

/// One durable genesis operation. The owner-confirmed provider signs only its stored body.
@MainActor
public final class RemoteRecoveryBootstrap {
    private struct Checkpoint: Codable {
        var version = 1
        let accountID: String
        let managerID: String
        let keyID: String
        let relayURL: String
        let secret: Data
        let body: String
        var entry: String?
        var committed = false
        var kitSaved = false
    }

    private var saved: Checkpoint
    private let persist: (Data) throws -> Void
    private var operating = false
    public private(set) var storageUncertain = false
    public var accountID: String { saved.accountID }
    public var genesisHash: String { get throws { try info().entryHash! } }
    public var recoveryIsSaved: Bool { saved.committed && saved.kitSaved && !storageUncertain }

    public func signingRequest() throws -> SignRequest {
        try available()
        guard !saved.committed, saved.entry == nil else { throw RemoteChannelError.notReady }
        return try RemoteConfirmedSigner.membershipRequest(bodyJSON: saved.body, keyID: saved.keyID)
    }

    public init(accountID: String, managerID: String, keyID: String, authKey: PublicKeyData,
        encryptionKey: PublicKeyData, recoverySecret: Data, relayURL: String, signedAt: UInt64,
        persist: @escaping (Data) throws -> Void) throws {
        guard RemoteRecoveryKit.validID(accountID), RemoteRecoveryKit.validID(managerID), managerID != "recovery",
              !keyID.isEmpty, authKey.alg == .p256 || authKey.alg == .ed25519,
              encryptionKey.alg == .x25519 else { throw RemoteRecoveryError.invalidCheckpoint }
        try checkPublicKey(key: authKey)
        try checkPublicKey(key: encryptionKey)
        let preliminary = try RecoveryKitHandle.make(r: recoverySecret, accountId: accountID,
            genesisHash: String(repeating: "0", count: 64))
        let member: [String: Any] = ["device_id": managerID, "kind": "native",
            "roles": ["control", "manage", "view"], "auth_key": Self.keyObject(authKey),
            "enc_key": Self.keyObject(encryptionKey)]
        let body: [String: Any] = ["type": "atem-membership-entry", "v": 1, "account_id": accountID,
            "seq": 1, "prev_hash": String(repeating: "0", count: 64), "action": "genesis",
            "signer": managerID, "signed_at": signedAt, "member": member,
            "recovery_key": Self.keyObject(preliminary.recoveryKey())]
        let bodyJSON = try canonicalJson(json: Self.json(body))
        saved = Checkpoint(accountID: accountID, managerID: managerID, keyID: keyID,
            relayURL: try RemoteRecoveryKit.checkedRelayURL(relayURL), secret: recoverySecret, body: bodyJSON)
        self.persist = persist
        _ = try info()
        try write(saved)
    }

    public init(checkpoint: Data, accountID: String, now: HostClock, persist: @escaping (Data) throws -> Void) throws {
        guard checkpoint.count <= 65_536 else { throw RemoteRecoveryError.invalidCheckpoint }
        saved = try PropertyListDecoder().decode(Checkpoint.self, from: checkpoint)
        self.persist = persist
        guard saved.version == 1, saved.accountID == accountID,
              saved.secret.count == 32, !saved.kitSaved || saved.committed,
              saved.relayURL == (try RemoteRecoveryKit.checkedRelayURL(saved.relayURL)) else {
            throw RemoteRecoveryError.invalidCheckpoint
        }
        let info = try info()
        guard let hash = info.entryHash else { throw RemoteRecoveryError.invalidCheckpoint }
        let body = try JSONSerialization.jsonObject(with: Data(info.bodyJcs.utf8)) as? [String: Any]
        guard body?["account_id"] as? String == accountID, body?["signer"] as? String == saved.managerID,
              body?["action"] as? String == "genesis" else { throw RemoteRecoveryError.invalidCheckpoint }
        let kit = try RecoveryKitHandle.make(r: saved.secret, accountId: accountID, genesisHash: hash)
        let key = try Self.json(Self.keyObject(kit.recoveryKey()))
        guard try canonicalJson(json: Self.json(body?["recovery_key"] as Any)) == canonicalJson(json: key) else {
            throw RemoteRecoveryError.invalidCheckpoint
        }
        if let entry = saved.entry {
            let log = try MembershipLog.verify(accountId: accountID, genesisHash: hash, entries: [entry], now: now)
            guard log.head().seq == 1, try signedObjectInfo(json: entry).bodyJcs == saved.body else {
                throw RemoteRecoveryError.invalidCheckpoint
            }
        } else if saved.committed { throw RemoteRecoveryError.invalidCheckpoint }
    }

    /// No request escapes before its exact signature is committed locally.
    public func sign(provider: AppKeyProvider, now: HostClock) throws -> AppendRequest {
        try available()
        guard !saved.committed else { throw RemoteRecoveryError.notCommitted }
        if let request = try outstanding() { return request }
        operating = true
        defer { operating = false }
        let info = try info()
        let key = try provider.publicKey(keyId: saved.keyID)
        let body = try JSONSerialization.jsonObject(with: Data(saved.body.utf8)) as? [String: Any]
        let member = body?["member"] as? [String: Any]
        guard try canonicalJson(json: Self.json(member?["auth_key"] as Any)) ==
            canonicalJson(json: Self.json(Self.keyObject(key))) else { throw RemoteRecoveryError.invalidCheckpoint }
        let request = SignRequest(keyId: saved.keyID, purpose: .genesis, freshConfirmation: true,
            label: "atem-membership-entry-v1", input: info.signingInput, bodyJson: saved.body)
        let signature = try provider.sign(request: request)
        let entry = try canonicalJson(json: Self.json(["body": body as Any,
            "sig": RemoteRecoveryKit.base64URL(signature)]))
        _ = try MembershipLog.verify(accountId: saved.accountID, genesisHash: genesisHash, entries: [entry], now: now)
        var next = saved
        next.entry = entry
        try write(next)
        return try outstandingUnchecked()!
    }

    public func outstanding() throws -> AppendRequest? {
        try available()
        return try outstandingUnchecked()
    }

    /// The transport calls this only for a reply bound to this exact genesis append.
    public func relayStored(now: HostClock) throws {
        try available()
        operating = true
        defer { operating = false }
        guard let entry = saved.entry else { throw RemoteRecoveryError.notCommitted }
        _ = try MembershipLog.verify(accountId: saved.accountID, genesisHash: genesisHash, entries: [entry], now: now)
        var next = saved
        next.committed = true
        try write(next)
    }

    public func committedLog(now: HostClock) throws -> MembershipLog {
        try available()
        guard saved.committed, let entry = saved.entry else { throw RemoteRecoveryError.notCommitted }
        return try MembershipLog.verify(accountId: saved.accountID, genesisHash: genesisHash, entries: [entry], now: now)
    }

    public func kit(now: HostClock) throws -> RemoteRecoveryKit {
        try RemoteRecoveryKit(secret: saved.secret, committedLog: committedLog(now: now), relayURL: saved.relayURL)
    }

    public func markKitSaved(_ kit: RemoteRecoveryKit, now: HostClock) throws {
        try available()
        guard try kit == self.kit(now: now) else { throw RemoteRecoveryError.invalidKit }
        operating = true
        defer { operating = false }
        var next = saved
        next.kitSaved = true
        try write(next)
    }

    private func info() throws -> SignedObjectInfo {
        let body = try JSONSerialization.jsonObject(with: Data(saved.body.utf8))
        let object = try Self.json(["body": body, "sig": RemoteRecoveryKit.base64URL(Data(repeating: 0, count: 64))])
        let info = try signedObjectInfo(json: object)
        guard info.bodyType == "atem-membership-entry", info.entryHash != nil else { throw RemoteRecoveryError.invalidCheckpoint }
        return info
    }

    private func outstandingUnchecked() throws -> AppendRequest? {
        guard !saved.committed, let entry = saved.entry else { return nil }
        return try AppendRequest(entryJson: entry, entryHash: genesisHash,
            expected: LogHead(seq: 0, hash: String(repeating: "0", count: 64)))
    }

    private func available() throws {
        guard !storageUncertain else { throw RemoteRecoveryError.storageUncertain }
        guard !operating else { throw RemoteRecoveryError.busy }
    }

    private func write(_ checkpoint: Checkpoint) throws {
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try persist(encoder.encode(checkpoint))
            saved = checkpoint
        } catch { storageUncertain = true; throw error }
    }

    private static func keyObject(_ key: PublicKeyData) -> [String: String] {
        let alg: String
        switch key.alg { case .p256: alg = "p256"; case .ed25519: alg = "ed25519"; case .x25519: alg = "x25519" }
        return ["alg": alg, "pub": RemoteRecoveryKit.base64URL(key.raw)]
    }

    private static func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]), as: UTF8.self)
    }
}
