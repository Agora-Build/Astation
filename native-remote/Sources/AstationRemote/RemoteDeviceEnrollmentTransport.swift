import Foundation

public enum RemoteDeviceEnrollmentTransportError: Error, Equatable {
    case notFound, closed, conflict, limit
}

public struct RemoteDeviceEnrollmentMailbox: Sendable {
    public let expires: UInt64
    public let request: RemoteDeviceEnrollmentRequest?
    public let response: RemoteDeviceEnrollmentHandoff?

    public init(expires: UInt64, request: RemoteDeviceEnrollmentRequest?, response: RemoteDeviceEnrollmentHandoff?) {
        self.expires = expires; self.request = request; self.response = response
    }
}

/// The invitation secret stays in native storage; only its random ID and expiry
/// locate a mailbox. Clients independently authenticate every carried message.
public protocol RemoteDeviceEnrollmentTransport: Sendable {
    func createEnrollment(_ invitation: RemoteDeviceEnrollmentInvitation, now: UInt64) async throws -> RemoteDeviceEnrollmentMailbox
    func readEnrollment(_ invitation: RemoteDeviceEnrollmentInvitation, now: UInt64) async throws -> RemoteDeviceEnrollmentMailbox
    func submitEnrollment(_ request: RemoteDeviceEnrollmentRequest, invitation: RemoteDeviceEnrollmentInvitation, now: UInt64) async throws -> RemoteDeviceEnrollmentMailbox
    func publishEnrollment(_ response: RemoteDeviceEnrollmentHandoff, request: RemoteDeviceEnrollmentRequest,
        invitation: RemoteDeviceEnrollmentInvitation, now: UInt64) async throws -> RemoteDeviceEnrollmentMailbox
    func cancelEnrollment(_ invitation: RemoteDeviceEnrollmentInvitation) async throws
}
