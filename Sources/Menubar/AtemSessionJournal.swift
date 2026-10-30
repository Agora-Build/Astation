import Darwin
import Foundation

struct AtemSessionRequestRecord: Codable, Equatable {
    let requestId: String
    let target: AtemSessionTarget
    let kind: String
    let digest: String
    var approvalID: String?
    var receipt: AtemSessionReceipt?
    var refusal: AtemSessionRefusal?
}

struct AtemSessionRefusal: Codable, Equatable {
    let code: String
    var controller: AtemSessionController?
    var valid: Bool { AtemSessionWire.diagnosticErrorCode(code) != "unknown_error" && controller?.valid != false }
}

struct AtemSessionHostFence: Codable, Equatable {
    let account: String
    let device: String
    var trust: UInt64
    var runtimeEpoch: UInt64?
    var runtimeGeneration: String?
}

/// Client recovery metadata contains no prompt, terminal bytes, credentials,
/// or authority. Only the authenticated host can supply a receipt outcome.
final class AtemSessionJournal {
    struct Snapshot: Codable, Equatable {
        // Older readers must not discard pending host-policy mutation identities.
        var version = 3
        var requests: [AtemSessionRequestRecord] = []
        var hosts: [AtemSessionHostFence] = []
        var transportPolicies: [AtemTransportPolicyRecord]?
        var hostPolicies: [AtemHostPolicyCheckpoint]?
    }

    private(set) var snapshot: Snapshot
    private(set) var loadFailed = false
    private let persist: (Snapshot) throws -> Void

    init(load: () throws -> Snapshot = { Snapshot() }, save: @escaping (Snapshot) throws -> Void = { _ in }) {
        self.persist = save
        do {
            let loaded = try load()
            guard (loaded.version == 1 && loaded.transportPolicies == nil && loaded.hostPolicies == nil
                   || loaded.version == 2 && loaded.hostPolicies == nil || loaded.version == 3),
                  loaded.requests.count <= 4096, loaded.hosts.count <= 128,
                  Set(loaded.requests.map(\.requestId)).count == loaded.requests.count,
                  loaded.requests.allSatisfy({ AtemSessionWire.uuid($0.requestId) && $0.target.valid
                      && $0.digest.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
                      && AtemSessionWire.submissionKinds.contains($0.kind) && $0.receipt?.valid != false && $0.refusal?.valid != false
                      && ($0.kind == "approval" ? $0.approvalID.map(AtemSessionWire.uuid) == true : $0.approvalID == nil)
                      && ($0.receipt == nil || ($0.receipt?.target == $0.target && $0.receipt?.request_id == $0.requestId && $0.receipt?.kind == $0.kind)) }),
                  Set(loaded.hosts.map { $0.account + "\u{0}" + $0.device }).count == loaded.hosts.count,
                  (loaded.transportPolicies ?? []).count <= 128,
                  Set((loaded.transportPolicies ?? []).map { $0.issuer + "\u{0}" + $0.account }).count == (loaded.transportPolicies ?? []).count,
                  (loaded.transportPolicies ?? []).allSatisfy(\.valid),
                  (loaded.hostPolicies ?? []).count <= 1024,
                  (loaded.hostPolicies ?? []).allSatisfy(\.valid),
                  Set((loaded.hostPolicies ?? []).map { $0.issuer + "\u{0}" + $0.account + "\u{0}" + $0.station + "\u{0}" + $0.host }).count == (loaded.hostPolicies ?? []).count,
                  loaded.hosts.allSatisfy({ AtemSessionWire.opaque($0.account) && AtemSessionWire.opaque($0.device)
                      && $0.trust <= AtemSessionWire.maximumCounter
                      && ($0.runtimeEpoch == nil) == ($0.runtimeGeneration == nil)
                      && $0.runtimeEpoch.map { $0 <= AtemSessionWire.maximumCounter } != false
                      && $0.runtimeGeneration.map(AtemSessionWire.uuid) != false }) else { throw AtemSessionJSON.Invalid.json }
            snapshot = loaded
            snapshot.version = 3
        } catch { snapshot = Snapshot(); loadFailed = true }
    }

    static func persistent(at file: URL? = nil) -> AtemSessionJournal {
        let url = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Astation", isDirectory: true).appendingPathComponent("remote-session-receipts.json")
        let directory = url.deletingLastPathComponent()
        return AtemSessionJournal(load: {
            guard FileManager.default.fileExists(atPath: url.path) else { return Snapshot() }
            let data = try Data(contentsOf: url)
            guard data.count <= 4_194_304 else { throw AtemSessionJSON.Invalid.limit }
            _ = try AtemSessionJSON.parse(data, limit: 4_194_304)
            return try JSONDecoder().decode(Snapshot.self, from: data)
        }, save: { state in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            guard data.count <= 4_194_304 else { throw AtemSessionJSON.Invalid.limit }
            // RecoveryKit.save uses a restricted temporary file, fsync, and rename.
            try RecoveryKit.save(String(decoding: data, as: UTF8.self), to: url)
            let descriptor = Darwin.open(directory.path, O_RDONLY)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            defer { Darwin.close(descriptor) }
            guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
        })
    }

    func update(_ mutation: (inout Snapshot) throws -> Void) throws {
        guard !loadFailed else { throw AtemSessionJSON.Invalid.json }
        var next = snapshot
        try mutation(&next)
        guard next.requests.count <= 4096, next.hosts.count <= 128 else { throw AtemSessionJSON.Invalid.limit }
        // Reply identifiers can enlarge final receipts. Evict old final
        // metadata before the file limit blocks new durable submissions.
        var bytes = try JSONEncoder().encode(next).count
        while bytes > 4_194_304 {
            guard let index = next.requests.firstIndex(where: { $0.receipt?.state.final == true }) else {
                throw AtemSessionJSON.Invalid.limit
            }
            bytes -= try JSONEncoder().encode(next.requests[index]).count + 1
            next.requests.remove(at: index)
        }
        do { try persist(next) }
        catch {
            // Rename may have succeeded before a directory fsync failed. Stop
            // further writes until reload so an older in-memory fence cannot win.
            loadFailed = true
            throw error
        }
        snapshot = next
    }
}
