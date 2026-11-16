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

    public var summary: String {
        if !signed { return "Saved review - confirmation required" }
        if application == .effectsReported { return "Selected Station reports all covered effects in force" }
        if let replacementRecordID { return "Fresh manager copy saved: " + replacementRecordID }
        if managerReviewRequired { return "Fresh manager review needed - the original signer no longer manages this account" }
        switch application {
        case .unknown: return "Selected Station has no matching stored stop"
        case .awaitingApplication: return "Waiting for covered hosts to confirm application"
        default: return stationStored ? "Stored at Station - host application not checked" : "Saved - Station delivery pending"
        }
    }
}
