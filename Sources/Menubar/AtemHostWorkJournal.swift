import AstationRemote
import Darwin
import Foundation

/// Launch identities survive socket and app restarts independently of session
/// receipts, because a launch can be accepted before a session exists.
final class AtemHostWorkJournal {
    private let url: URL
    private var records: [RemoteLaunchRecord]?
    private var failed = false

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Astation/remote-host-launches.json")
    }

    func load(account: String, device: String) throws -> [RemoteLaunchRecord] {
        guard !failed else { throw AtemSessionJSON.Invalid.json }
        if records == nil {
            let loaded: [RemoteLaunchRecord]
            if FileManager.default.fileExists(atPath: url.path) {
                let bytes = try Data(contentsOf: url)
                _ = try AtemSessionJSON.parse(bytes, limit: 4_194_304)
                loaded = try JSONDecoder().decode([RemoteLaunchRecord].self, from: bytes)
            } else { loaded = [] }
            guard loaded.count <= 4096, Set(loaded.map(\.requestID)).count == loaded.count,
                  loaded.allSatisfy({ ($0.status == nil || $0.status?.request_id == $0.requestID)
                      && ($0.status == nil || $0.refusal == nil) }) else { throw AtemSessionJSON.Invalid.json }
            records = loaded
        }
        guard let records else { throw AtemSessionJSON.Invalid.json }
        return records.filter { $0.host.account_id == account && $0.host.atem_device_id == device }
    }

    func save(_ incoming: [RemoteLaunchRecord]) throws {
        guard !failed, let records else { throw AtemSessionJSON.Invalid.json }
        var merged = Dictionary(uniqueKeysWithValues: records.map { ($0.requestID, $0) })
        guard Set(incoming.map(\.requestID)).count == incoming.count else { throw AtemSessionJSON.Invalid.json }
        for record in incoming {
            guard record.status == nil || record.status?.request_id == record.requestID,
                  record.status == nil || record.refusal == nil else { throw AtemSessionJSON.Invalid.json }
            guard var previous = merged[record.requestID] else {
                merged[record.requestID] = record
                continue
            }
            guard previous.host == record.host, previous.profile == record.profile,
                  previous.expiresAt == record.expiresAt else { throw AtemSessionJSON.Invalid.json }
            if let status = record.status {
                guard previous.refusal == nil else { throw AtemSessionJSON.Invalid.json }
                if let known = previous.status {
                    guard known.session_id == status.session_id, known.process_gen == status.process_gen,
                          known.state == .starting || status.state == .starting || known == status else {
                        throw AtemSessionJSON.Invalid.json
                    }
                    // A second view may save an older snapshot after this view learned the outcome.
                    if known.state == .starting { previous.status = status }
                } else { previous.status = status }
            }
            if let refusal = record.refusal {
                guard previous.status == nil, previous.refusal == nil || previous.refusal == refusal else {
                    throw AtemSessionJSON.Invalid.json
                }
                previous.refusal = refusal
            }
            merged[record.requestID] = previous
        }
        let next = merged.values.sorted { $0.requestID < $1.requestID }
        guard next.count <= 4096 else { throw AtemSessionJSON.Invalid.limit }
        let bytes = try JSONEncoder().encode(next)
        guard bytes.count <= 4_194_304 else { throw AtemSessionJSON.Invalid.limit }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try RecoveryKit.save(String(decoding: bytes, as: UTF8.self), to: url)
            let descriptor = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            defer { Darwin.close(descriptor) }
            guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
        } catch { failed = true; throw error }
        self.records = next
    }
}
