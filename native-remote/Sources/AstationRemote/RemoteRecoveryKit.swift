import AtemClient
import Foundation

public enum RemoteRecoveryError: LocalizedError, Equatable {
    case invalidKit
    case unsupportedVersion
    case kitNotCurrent
    case notCommitted
    case invalidCheckpoint
    case storageUncertain
    case busy
    case confirmationRequired
    case requiresReview
    case enrollmentPending

    public var errorDescription: String? {
        switch self {
        case .invalidKit: return "This Recovery Kit is damaged or mistyped. Check the complete kit and try again."
        case .unsupportedVersion: return "This Recovery Kit needs a newer Astation version. Update Astation and try again."
        case .kitNotCurrent: return "This Recovery Kit was replaced. Use the current kit."
        case .notCommitted: return "The recovery setup has not finished saving. Reconnect and retry."
        case .invalidCheckpoint: return "The saved recovery operation could not be read. Its data was retained."
        case .storageUncertain: return "Recovery is paused because its saved state could not be confirmed. Reload the protected state before retrying."
        case .busy: return "Another recovery operation is in progress."
        case .confirmationRequired: return "Confirm this recovery operation with Touch ID or your device password."
        case .requiresReview: return "Recovery stopped because signed membership history could not be reconciled. A trusted manager must review it. The saved operation was retained."
        case .enrollmentPending: return "This device's recovery request is still pending. A trusted manager can approve it now; otherwise the recovery waiting period must finish before pairing or account changes."
        }
    }
}

/// Presentation only: all recovery derivation and integrity checking use the accepted shared core.
public struct RemoteRecoveryKit: Equatable, Sendable {
    public var recoveryKey: PublicKeyData { handle.recoveryKey() }

    public func openBackup(_ envelopeJSON: String) throws -> [AccountKey] {
        try openKBackup(envelopeJson: envelopeJSON, kit: handle)
    }

    public static let title = "Astation Recovery Kit v2"
    public static let integrityCheckLabel = "Recovery Kit Integrity Check"
    public static let integrityCheckHelp = "Confirms that your recovery secret, account, and original trust record belong together."
    public static let maximumTextBytes = 16_384

    public let relayURL: String
    let handle: RecoveryKitHandle

    public var accountID: String { handle.accountId() }
    public var genesisHash: String { handle.genesisHash() }

    /// The caller must supply its durably committed log, never a relay-selected root.
    public init(secret: Data, committedLog: MembershipLog, relayURL: String) throws {
        let kit = try RecoveryKitHandle.make(r: secret, accountId: committedLog.accountId(),
            genesisHash: committedLog.genesisHash())
        guard committedLog.frozen() == nil, committedLog.recoveryKey() == kit.recoveryKey() else {
            throw RemoteRecoveryError.kitNotCurrent
        }
        self.relayURL = try Self.checkedRelayURL(relayURL)
        handle = kit
    }

    public init(text: String) throws {
        guard text.utf8.count <= Self.maximumTextBytes else { throw RemoteRecoveryError.invalidKit }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let title = lines.first else { throw RemoteRecoveryError.invalidKit }
        guard title == Self.title else {
            if title.hasPrefix("Astation Recovery Kit v") { throw RemoteRecoveryError.unsupportedVersion }
            throw RemoteRecoveryError.invalidKit
        }
        let labels: Set<String> = ["Account ID", "Relay", "Recovery Secret", "Genesis Fingerprint", Self.integrityCheckLabel]
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw RemoteRecoveryError.invalidKit }
            let name = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard labels.contains(name), fields[name] == nil, !value.isEmpty else { throw RemoteRecoveryError.invalidKit }
            fields[name] = value
        }
        guard fields.count == labels.count,
              let account = fields["Account ID"], Self.validID(account),
              let genesis = fields["Genesis Fingerprint"], Self.validHash(genesis),
              let r = Self.decodeBase64URL(fields["Recovery Secret"]!, count: 32),
              let tag = Self.decodeBase64URL(fields[Self.integrityCheckLabel]!, count: 16) else {
            throw RemoteRecoveryError.invalidKit
        }
        relayURL = try Self.checkedRelayURL(fields["Relay"]!)
        do {
            handle = try RecoveryKitHandle.read(r: r, accountId: account, genesisHash: genesis, kitTag: tag)
        } catch { throw RemoteRecoveryError.invalidKit }
    }

    public func text() -> String {
        """
        \(Self.title)
        Account ID: \(accountID)
        Relay: \(relayURL)
        Recovery Secret: \(Self.base64URL(handle.secretR()))
        Genesis Fingerprint: \(genesisHash)
        \(Self.integrityCheckLabel): \(Self.base64URL(handle.kitTag()))
        """
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.relayURL == rhs.relayURL && lhs.accountID == rhs.accountID && lhs.genesisHash == rhs.genesisHash &&
            lhs.handle.kitTag() == rhs.handle.kitTag() && lhs.handle.secretR() == rhs.handle.secretR()
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ value: String, count: Int) -> Data? {
        guard value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
            (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        let padded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") +
            String(repeating: "=", count: (4 - value.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: padded), data.count == count, base64URL(data) == value else { return nil }
        return data
    }

    static func validID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) ||
            $0 == 46 || $0 == 95 || $0 == 58 || $0 == 45
        }
    }

    static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func checkedRelayURL(_ value: String) throws -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URLComponents(string: value), let host = url.host, !host.isEmpty,
              ["https", "wss", "http", "ws"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !value.contains(where: { $0.isNewline }), url.url != nil else { throw RemoteRecoveryError.invalidKit }
        return value
    }
}
