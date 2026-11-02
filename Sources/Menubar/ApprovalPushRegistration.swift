import Foundation
import AtemClient

enum ApprovalPushPlatform: String, Codable {
    case apnsSandbox = "apns_sandbox"
    case apnsProduction = "apns_production"

    init?(entitlement: String) {
        switch entitlement {
        case "development": self = .apnsSandbox
        case "production": self = .apnsProduction
        default: return nil
        }
    }
}

struct ApprovalPushRegistration: Codable, Equatable {
    let platform: ApprovalPushPlatform
    let token: String

    init?(deviceToken: Data, platform: ApprovalPushPlatform) {
        guard (16...256).contains(deviceToken.count) else { return nil }
        self.platform = platform
        token = deviceToken.map { String(format: "%02x", $0) }.joined()
    }

    var registerMessage: String? {
        guard let registration = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self)),
              let data = try? JSONSerialization.data(withJSONObject: ["type": "relayPushRegister", "registration": registration]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func unregisterMessage(platform: ApprovalPushPlatform) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "relayPushUnregister", "platform": platform.rawValue]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Notification metadata selects a catch-up request; it never grants authority
/// or supplies the process/rule/decision for an approval submission.
struct ApprovalPushHint: Codable, Equatable {
    enum Kind: String, Codable { case approval, resolved }
    let kind: Kind
    let approvalID: String
    let atemDeviceID: String
    let sessionID: String?
    let scope: String?

    var cacheKey: String { scope ?? atemDeviceID + "\u{0}" + approvalID }

    init(verified approval: ApprovalRef, resolved: Bool) {
        kind = resolved ? .resolved : .approval
        approvalID = approval.approvalId
        atemDeviceID = approval.hostId
        sessionID = approval.sessionId
        let fields = [approval.accountId, approval.genesisHash, approval.hostId, String(approval.hostTrustGen),
                      approval.sessionId, approval.processGen, approval.approvalId]
        scope = String(decoding: try! JSONEncoder().encode(fields), as: UTF8.self)
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let kind = (userInfo["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let approval = userInfo["approval_id"] as? String, approval.utf8.count == 36, UUID(uuidString: approval) != nil,
              let host = userInfo["atem_device_id"] as? String, Self.opaque(host) else { return nil }
        let session = userInfo["session_id"] as? String
        if kind == .approval { guard session.map(Self.opaque) == true else { return nil } }
        self.kind = kind
        approvalID = approval
        atemDeviceID = host
        sessionID = session
        scope = nil
    }

    private static func opaque(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy { (33...126).contains($0) }
    }
}

/// Suppress a delayed transport alert after its resolution. These tombstones
/// apply only to notifications: authoritative catch-up must still ask Atem.
struct ApprovalPushReconciliation {
    struct Resolution: Codable, Equatable {
        let host: String
        let approval: String
        let receivedAt: Date
        let scope: String?
    }
    private(set) var resolutions: [Resolution]

    init(saved: Data? = nil) {
        resolutions = saved.flatMap { try? JSONDecoder().decode([Resolution].self, from: $0) } ?? []
        if resolutions.count > 512 { resolutions = Array(resolutions.suffix(512)) }
    }

    mutating func receive(_ hint: ApprovalPushHint, now: Date) -> Bool {
        resolutions.removeAll { now.timeIntervalSince($0.receivedAt) >= 86_400 }
        if hint.kind == .resolved {
            resolutions.removeAll { $0.host == hint.atemDeviceID && $0.approval == hint.approvalID && $0.scope == hint.scope }
            resolutions.append(Resolution(host: hint.atemDeviceID, approval: hint.approvalID, receivedAt: now, scope: hint.scope))
            if resolutions.count > 512 { resolutions.removeFirst(resolutions.count - 512) }
        }
        return resolutions.contains { $0.host == hint.atemDeviceID && $0.approval == hint.approvalID && $0.scope == hint.scope }
    }

    var saved: Data? { try? JSONEncoder().encode(resolutions) }
}
