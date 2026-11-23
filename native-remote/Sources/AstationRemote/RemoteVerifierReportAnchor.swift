import AtemClient

/// Capture from the native account's independently anchored membership, never a
/// challenge or Station response. The protocol account is distinct from an OAuth subject.
public struct RemoteVerifierReportAnchor: Sendable {
    public let accountID: String
    public let genesisHash: String

    public init(log: MembershipLog) throws {
        guard log.frozen() == nil else { throw RemoteVerifierGateError.staleMembership }
        accountID = log.accountId(); genesisHash = log.genesisHash()
    }

    public func require(_ log: MembershipLog) throws {
        guard log.accountId() == accountID, log.genesisHash() == genesisHash, log.frozen() == nil else {
            throw RemoteVerifierGateError.staleMembership
        }
    }
}
