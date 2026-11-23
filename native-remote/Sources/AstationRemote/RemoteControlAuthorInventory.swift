import AtemClient
import Foundation

/// A read of one member key's retained evidence for one Station. It grants no
/// authority to issue a signer report or publish a replacement feed.
public struct RemoteControlAuthorInventory {
    private struct Row {
        let bodyJSON: String
        let signedRecord: String?
        let possiblySigned: Bool
        let hasUnsignedDraft: Bool
    }

    let origin: String
    let account: String
    let genesis: String
    let member: String
    let key: PublicKeyData
    private var rows: [String: Row] = [:]
    private var otherOriginIDs = Set<String>()

    init(origin: String, account: String, genesis: String, member: String, key: PublicKeyData) {
        self.origin = origin
        self.account = account
        self.genesis = genesis
        self.member = member
        self.key = key
    }

    public var signedRecords: [String] {
        rows.keys.sorted().compactMap { rows[$0]?.signedRecord }
    }
    public var unsignedDraftBodies: [String] {
        rows.keys.sorted().compactMap { id in
            guard let row = rows[id], row.signedRecord == nil, !row.possiblySigned else { return nil }
            return row.bodyJSON
        }
    }
    public var missingSignatureBodies: [String] {
        rows.keys.sorted().compactMap { id in
            guard let row = rows[id], row.signedRecord == nil, row.possiblySigned else { return nil }
            return row.bodyJSON
        }
    }

    // An outbox can retain an unsigned draft even when another retained source
    // proves the same body was signed. The SDK commits both sets independently.
    var reportRecordBodies: [String] {
        rows.keys.sorted().compactMap { id in
            guard let row = rows[id], row.possiblySigned || row.signedRecord != nil else { return nil }
            return row.bodyJSON
        }
    }

    var reportDraftBodies: [String] {
        rows.keys.sorted().compactMap { id in
            guard let row = rows[id], row.hasUnsignedDraft else { return nil }
            return row.bodyJSON
        }
    }

    public var reportDraftCount: Int { reportDraftBodies.count }

    // Each source validates its own saved key, canonical body and signature.
    mutating func retain(body: ControlRecordBody, json: String, key sourceKey: PublicKeyData,
                         record: String?, possiblySigned: Bool, unsignedDraft: Bool = false) throws {
        guard body.accountId == account, body.genesisHash == genesis else {
            throw RemoteControlPublicationError.invalidCheckpoint
        }
        guard body.signer == "member:" + member else { return }
        if body.principal.hasPrefix("host:") {
            guard body.action == "interrupt_running", body.origin == nil else {
                throw RemoteControlPublicationError.invalidRecord
            }
        } else {
            guard body.principal.hasPrefix("service:"), ["revoke", "interrupt_running"].contains(body.action) else {
                throw RemoteControlPublicationError.invalidRecord
            }
            guard body.origin == origin else {
                guard rows[body.recordId] == nil else { throw RemoteControlPublicationError.requiresReview }
                otherOriginIDs.insert(body.recordId)
                return
            }
        }
        let prior = rows[body.recordId]
        guard sourceKey == key, !otherOriginIDs.contains(body.recordId) else { throw RemoteControlPublicationError.requiresReview }
        if let prior, prior.bodyJSON != json {
            throw RemoteControlPublicationError.requiresReview
        }
        rows[body.recordId] = Row(bodyJSON: json, signedRecord: prior?.signedRecord ?? record,
            possiblySigned: possiblySigned || prior?.possiblySigned == true,
            hasUnsignedDraft: unsignedDraft || prior?.hasUnsignedDraft == true)
    }
}
