import AtemClient
import Foundation

/// The shared reader owns clock, recovery-decision and signature validation.
/// Callers commit the returned state immediately, before using its effects.
public enum RemoteMembershipCheckpoint {
    public static func load(accountID: String, genesisHash: String, entries: [String],
        storedJSON: String?, now: HostClock) throws -> MembershipLog {
        guard let storedJSON else {
            return try MembershipLog.verify(accountId: accountID, genesisHash: genesisHash, entries: entries, now: now)
        }
        let log = try MembershipLog.fromStored(accountId: accountID, genesisHash: genesisHash,
            storedJson: storedJSON, now: now)
        guard log.entries() == entries else { throw RemoteRecoveryError.invalidCheckpoint }
        return log
    }
}
