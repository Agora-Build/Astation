import AtemClient
import Foundation

/// Publishes an already anchored chain after an explicit Station selection and
/// owner confirmation. It never creates trust, re-signs entries or accepts a fork.
@MainActor
public enum RemoteRecoveryLogReplication {
    public static func publish(log: MembershipLog, transport: RemoteRecoveryTransport,
        current: () -> Bool) async throws {
        let entries = log.entries()
        guard !entries.isEmpty, entries.count <= 8_192, log.frozen() == nil else {
            throw RemoteRecoveryError.requiresReview
        }
        let hashes = try entries.map { entry -> String in
            guard let hash = try signedObjectInfo(json: entry).entryHash else {
                throw RemoteRecoveryError.invalidCheckpoint
            }
            return hash
        }
        func check() throws {
            try Task.checkCancellation()
            guard current() else { throw RemoteChannelError.staleLink }
        }
        func prefix() async throws -> Int {
            var after = 0
            var head: LogHead?
            for _ in 0..<128 {
                try check()
                let page: RemoteRecoveryLogPage
                do { page = try await transport.entries(genesisHash: log.genesisHash(), after: UInt64(after)) }
                catch RemoteRecoveryTransportError.recordNotFound where after == 0 { return 0 }
                try check()
                guard page.head.seq > 0, page.head.seq <= UInt64(entries.count),
                      page.head.hash == hashes[Int(page.head.seq) - 1],
                      head == nil || head == page.head else { throw RemoteRecoveryError.requiresReview }
                head = page.head
                guard page.entries.count <= 64, after + page.entries.count <= Int(page.head.seq) else {
                    throw RemoteRecoveryTransportError.invalidResponse
                }
                for entry in page.entries {
                    guard try signedObjectInfo(json: entry).entryHash == hashes[after] else {
                        throw RemoteRecoveryError.requiresReview
                    }
                    after += 1
                }
                if !page.more {
                    guard UInt64(after) == page.head.seq else { throw RemoteRecoveryTransportError.invalidResponse }
                    return after
                }
                guard !page.entries.isEmpty, UInt64(after) < page.head.seq else {
                    throw RemoteRecoveryTransportError.invalidResponse
                }
            }
            throw RemoteRecoveryTransportError.invalidResponse
        }

        let stored = try await prefix()
        for index in stored..<entries.count {
            try check()
            let request = AppendRequest(entryJson: entries[index], entryHash: hashes[index],
                expected: LogHead(seq: UInt64(index), hash: index == 0 ? String(repeating: "0", count: 64) : hashes[index - 1]))
            switch try await transport.append(genesisHash: log.genesisHash(), request: request) {
            case .stored: break
            case .conflict: throw RemoteRecoveryError.requiresReview
            }
            try check()
        }
        // An acknowledgement cannot prove that the selected Station retained the chain.
        guard try await prefix() == entries.count else { throw RemoteRecoveryTransportError.invalidResponse }
        try check()
    }
}
