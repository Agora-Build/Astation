import AtemClient
import Foundation

/// Selected-Station reports are display information, never signing or dispatch authority.
public enum RemoteControlApplicationState: String, Sendable {
    case unknown
    case awaitingApplication = "awaiting_application"
    case effectsReported = "effects_reported"
}

public protocol RemoteControlStatusTransport: Sendable {
    func controlStatus(genesisHash: String, recordIDs: [String], expected: LogHead) async throws -> [String: RemoteControlApplicationState]
}

public struct RemoteControlActivity: Equatable, Sendable {
    public let body: ControlRecordBody
    public let signed: Bool
    public let stationStored: Bool
    public let portalPending: Bool
    public let managerReviewRequired: Bool
    public let replacementRecordID: String?
    public let application: RemoteControlApplicationState?
    public let additionalStations: [String: Bool]

    /// Application evidence is selected-Station only. Additional storage receipts
    /// cannot settle a removed signer's stop on those Stations' receiving hosts.
    public var requiresManagerReview: Bool {
        managerReviewRequired && (application != .effectsReported || !additionalStations.isEmpty)
    }

    public var summary: String {
        if !signed { return "Saved review - confirmation required" }
        if let replacementRecordID { return "Fresh manager copy saved: " + replacementRecordID }
        if requiresManagerReview { return "Fresh manager review needed - the original signer no longer manages this account" }
        if application == .effectsReported { return "This Station reports all covered effects in force" }
        switch application {
        case .unknown: return "This Station has no matching stored stop"
        case .awaitingApplication: return "Waiting for covered hosts to confirm application"
        default: return stationStored ? "Stored at Station - host application not checked" : "Saved - Station delivery pending"
        }
    }
}
