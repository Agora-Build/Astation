import AtemClient
import Foundation

/// One durable manager invitation. Carrier retries return the same request and
/// ciphertext; an invitation cannot be rebound to a second set of device keys.
@MainActor
public final class RemoteDeviceEnrollmentSession {
    private struct Saved: Codable {
        let version: Int
        let invitation: RemoteDeviceEnrollmentInvitation
        var request: String?
        var response: String?
        var cancelled = false
    }
    private var saved: Saved
    private let persist: (Data) throws -> Void
    private var writing = false
    public private(set) var storageUncertain = false
    public var invitation: RemoteDeviceEnrollmentInvitation { saved.invitation }

    public init(invitation: RemoteDeviceEnrollmentInvitation, now: HostClock, persist: @escaping (Data) throws -> Void) throws {
        try invitation.validate(issuer: invitation.issuer, owner: invitation.owner, station: invitation.station, now: now)
        saved = Saved(version: 1, invitation: invitation)
        self.persist = persist
        try write(saved)
    }

    public init(checkpoint: Data, issuer: String, owner: String, station: String, now: HostClock,
        persist: @escaping (Data) throws -> Void) throws {
        guard checkpoint.count <= 65_536 else { throw RemoteRecoveryError.invalidCheckpoint }
        saved = try PropertyListDecoder().decode(Saved.self, from: checkpoint)
        self.persist = persist
        guard saved.version == 1, saved.response == nil || saved.request != nil else { throw RemoteRecoveryError.invalidCheckpoint }
        // Closed/expired invitations remain tombstones, never fresh invitations.
        let validationTime = HostClock(wallMs: saved.invitation.created, monoMs: now.monoMs, bootId: now.bootId)
        try invitation.validate(issuer: issuer, owner: owner, station: station, now: validationTime)
        if let request = saved.request {
            let parsed = try RemoteDeviceEnrollmentRequest(json: request, invitation: invitation, now: validationTime)
            if let response = saved.response {
                _ = try RemoteDeviceEnrollmentHandoff(json: response, invitation: invitation, request: parsed, now: validationTime)
            }
        }
    }

    public func qrJSON(now: HostClock) throws -> String {
        try available(now: now)
        return try invitation.qrJSON()
    }

    @discardableResult
    public func bind(requestJSON: String, now: HostClock) throws -> RemoteDeviceEnrollmentRequest {
        try available(now: now)
        let request = try RemoteDeviceEnrollmentRequest(json: requestJSON, invitation: invitation, now: now)
        let canonical = try request.json()
        if let previous = saved.request {
            guard previous == canonical else { throw RemoteDeviceEnrollmentError.alreadyUsed }
        } else {
            var next = saved
            next.request = canonical
            try write(next)
        }
        return request
    }

    public func review(log: MembershipLog, now: HostClock) throws -> RemoteNativeEnrollment {
        let request = try boundRequest(now: now)
        try invitation.checkManager(log: log, now: now)
        return try RemoteNativeEnrollment(requestID: invitation.id, stationOrigin: invitation.station,
            deviceID: request.deviceID, authKey: request.authKey, encryptionKey: request.encryptionKey,
            roles: request.roles, expiresAt: invitation.expires, log: log, managerID: invitation.manager, now: now)
    }

    public func handoff(committedLog: MembershipLog, keys: [AccountKey], now: HostClock) throws -> String {
        let request = try boundRequest(now: now)
        _ = try RemoteDeviceEnrollmentHandoff.acceptedEntry(invitation: invitation, request: request, log: committedLog, now: now)
        if let response = saved.response { return response }
        let response = try RemoteDeviceEnrollmentHandoff.seal(invitation: invitation, request: request,
            committedLog: committedLog, keys: keys, now: now).json()
        var next = saved
        next.response = response
        try write(next)
        return response
    }

    public func matchesHandoff(_ response: RemoteDeviceEnrollmentHandoff, now: HostClock) throws -> Bool {
        try available(now: now)
        return saved.response == (try response.json())
    }

    public func cancel() throws {
        guard !storageUncertain, !writing else { throw RemoteRecoveryError.storageUncertain }
        var next = saved
        next.cancelled = true
        try write(next)
    }

    private func boundRequest(now: HostClock) throws -> RemoteDeviceEnrollmentRequest {
        try available(now: now)
        guard let request = saved.request else { throw RemoteRecoveryError.notCommitted }
        return try RemoteDeviceEnrollmentRequest(json: request, invitation: invitation, now: now)
    }

    private func available(now: HostClock) throws {
        guard !storageUncertain else { throw RemoteRecoveryError.storageUncertain }
        guard !writing else { throw RemoteRecoveryError.busy }
        guard !saved.cancelled else { throw RemoteDeviceEnrollmentError.cancelled }
        try invitation.validate(issuer: invitation.issuer, owner: invitation.owner, station: invitation.station, now: now)
    }

    private func write(_ next: Saved) throws {
        guard !storageUncertain else { throw RemoteRecoveryError.storageUncertain }
        guard !writing else { throw RemoteRecoveryError.busy }
        writing = true
        defer { writing = false }
        do {
            try persist(PropertyListEncoder().encode(next))
            saved = next
        } catch { storageUncertain = true; throw error }
    }
}
