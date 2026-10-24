import AtemClient
import Foundation
import XCTest
@testable import AstationRemote

@MainActor
private final class FakeCore: RemoteChannelCore {
    var acceptDeadline: UInt64? = 5_000
    var isClosed = false
    var disconnects = 0
    var finishCalls = 0
    var received = 0
    var operations: [RemoteAgentOperation] = []
    var events: [ClientEvent] = []
    var operationError: Error?
    var closeOnOperationError = false
    var receiveError: Error?
    var authorization: UInt64 = 1_000

    func start(now: UInt64) throws -> Data { Data("init".utf8) }
    func accept(_ frame: Data, now: UInt64) throws -> SignRequest {
        SignRequest(keyId: "device-key", purpose: .channel, freshConfirmation: false, label: "atem-ch1-client", input: Data("proof".utf8), bodyJson: nil)
    }
    func finish(_ signature: Data, now: UInt64) throws -> Data {
        finishCalls += 1
        return Data("finish".utf8)
    }
    func welcome(_ frame: Data, now: UInt64) throws -> WelcomeInfo {
        WelcomeInfo(principal: "device-a", clientKind: "native", permissions: ["view", "control"], revision: 9,
                    features: [], accountId: "account-a", atemDeviceId: "host-a", hostTrustGen: 3,
                    attachmentGen: "attachment-a", controllerSession: "controller-a", runtimeGen: "runtime-a",
                    authorizationMsLeft: authorization, serverTime: 0, head: LogHead(seq: 1, hash: "head"),
                    pendingRecovery: [], channelId: "channel-a", scopeJson: nil, json: "{}")
    }
    func receive(_ frame: Data, now: UInt64) throws -> [ClientEvent] {
        received += 1
        if let receiveError { throw receiveError }
        return events
    }
    func perform(_ operation: RemoteAgentOperation, now: UInt64) throws -> Outgoing {
        operations.append(operation)
        if let operationError { isClosed = closeOnOperationError; throw operationError }
        return Outgoing(id: "request-\(operations.count)", frame: Data("operation".utf8))
    }
    func disconnect() { disconnects += 1; isClosed = true }
}

@MainActor
private final class Harness {
    let route = try! RemoteChannelRoute(linkGeneration: UUID(), handle: "channel_1")
    let core = FakeCore()
    var now: UInt64 = 100
    var sent: [Data] = []
    var closed: [RemoteChannelRoute] = []
    var updates: [ClientEvent] = []
    var readyCount = 0
    var sendError: Error?
    var onPhase: ((RemoteAgentChannel.Phase) -> Void)?
    var signing: ((SignRequest) async throws -> Data)?
    lazy var channel = RemoteAgentChannel(route: route, core: core, clock: { [unowned self] in now },
        automaticTimer: false, sign: { [unowned self] request in
            if let signing { return try await signing(request) }
            return Data("signature".utf8)
        }, send: { [unowned self] target, frame in
            XCTAssertEqual(target, route)
            if let sendError { throw sendError }
            sent.append(frame)
        }, close: { [unowned self] in closed.append($0) }, observe: { [unowned self] in
            switch $0 {
            case .phase(let phase): onPhase?(phase)
            case .update(let event): updates.append(event)
            case .ready: readyCount += 1
            default: break
            }
        })

    func welcome() async throws {
        try channel.start()
        channel.receive(Data(), from: route)
        await drainSigner()
        XCTAssertEqual(channel.phase, .awaitingWelcome)
        channel.receive(Data(), from: route)
        XCTAssertEqual(channel.phase, .ready)
    }

    func drainSigner() async {
        for _ in 0..<10 { await Task.yield() }
    }
}

final class RemoteAgentChannelTests: XCTestCase {
    @MainActor
    func testHandshakeGatesOperationsAndForwardsTypedRequestsWithoutRetry() async throws {
        let h = Harness()
        XCTAssertThrowsError(try h.channel.perform(.list))
        try h.channel.start()
        XCTAssertThrowsError(try h.channel.start())
        XCTAssertThrowsError(try h.channel.perform(.list))
        h.channel.receive(Data(), from: h.route)
        XCTAssertEqual(h.channel.phase, .signing)
        XCTAssertThrowsError(try h.channel.perform(.list))
        await h.drainSigner()
        XCTAssertEqual(h.channel.phase, .awaitingWelcome)
        XCTAssertThrowsError(try h.channel.perform(.list))
        h.channel.receive(Data(), from: h.route)
        XCTAssertEqual(h.readyCount, 1)
        let operations: [RemoteAgentOperation] = [
            .prompt(session: "session", request: "durable-id", text: "test"),
            .approval(session: "session", request: "answer", approval: "approval", decision: .deny, rule: nil, message: "no"),
            .receipts(session: "session", requests: ["durable-id"])
        ]
        for (index, operation) in operations.enumerated() {
            XCTAssertEqual(try h.channel.perform(operation), "request-\(index + 1)")
        }
        XCTAssertEqual(h.core.operations, operations)
        h.channel.disconnect()
        XCTAssertThrowsError(try h.channel.perform(.list))
        XCTAssertThrowsError(try h.channel.start())
        XCTAssertEqual(h.core.operations, operations)
    }

    @MainActor
    func testDelayedSignatureCannotFinishAfterDisconnectOrMatchingLinkLoss() async throws {
        for linkLoss in [false, true] {
            let h = Harness()
            var pending: CheckedContinuation<Data, Error>?
            h.signing = { _ in try await withCheckedThrowingContinuation { pending = $0 } }
            try h.channel.start()
            h.channel.receive(Data(), from: h.route)
            await h.drainSigner()
            XCTAssertNotNil(pending)
            if linkLoss { h.channel.linkLost(generation: h.route.linkGeneration) }
            else { h.channel.disconnect() }
            pending?.resume(returning: Data("late signature".utf8))
            await h.drainSigner()
            XCTAssertEqual(h.core.finishCalls, 0)
            XCTAssertEqual(h.sent, [Data("init".utf8)])
            XCTAssertEqual(h.closed, [h.route])
            h.channel.disconnect()
            XCTAssertEqual(h.core.disconnects, 1)
        }
    }

    @MainActor
    func testOldRoutesCannotAdvanceOrCloseReplacementChannel() async throws {
        let h = Harness()
        try h.channel.start()
        let oldRoute = try RemoteChannelRoute(linkGeneration: UUID(), handle: h.route.handle)
        let otherChannel = try RemoteChannelRoute(linkGeneration: h.route.linkGeneration, handle: "other")
        h.channel.receive(Data(), from: oldRoute)
        h.channel.receive(Data(), from: otherChannel)
        h.channel.linkLost(generation: oldRoute.linkGeneration)
        XCTAssertEqual(h.channel.phase, .awaitingAccept)
        XCTAssertTrue(h.closed.isEmpty)
        h.channel.disconnect()
        XCTAssertEqual(h.closed, [h.route])
    }

    @MainActor
    func testDeadlinesIncludeSigningWelcomeAndAuthorizationAndExpireAtEquality() async throws {
        for phase in [RemoteAgentChannel.Phase.awaitingAccept, .signing, .awaitingWelcome, .ready] {
            let h = Harness()
            var pending: CheckedContinuation<Data, Error>?
            if phase == .signing { h.signing = { _ in try await withCheckedThrowingContinuation { pending = $0 } } }
            try h.channel.start()
            if phase != .awaitingAccept { h.channel.receive(Data(), from: h.route); await h.drainSigner() }
            if phase == .ready { h.channel.receive(Data(), from: h.route) }
            XCTAssertEqual(h.channel.phase, phase)
            let deadline: UInt64 = phase == .awaitingAccept ? 5_000 : (phase == .ready ? 1_100 : 10_100)
            h.now = deadline - 1
            h.channel.checkDeadline()
            XCTAssertEqual(h.channel.phase, phase)
            h.now = deadline
            h.channel.checkDeadline()
            XCTAssertEqual(h.channel.phase, .closed)
            pending?.resume(returning: Data())
            await h.drainSigner()
            XCTAssertEqual(h.core.finishCalls, phase == .awaitingWelcome || phase == .ready ? 1 : 0)
            XCTAssertEqual(h.closed.count, 1)
        }
    }

    @MainActor
    func testOutgoingFramesAndFencesAffectOnlyTheirChannel() async throws {
        let h = Harness()
        let other = Harness()
        try await h.welcome()
        try await other.welcome()
        let update = ClientEvent.registry(outcome: "applied")
        let fence = ClientEvent.fenced(code: "unauthorized", detail: nil, json: "{}")
        h.core.events = [update, .outgoing(frame: Data("resync".utf8)), fence, update]
        h.channel.receive(Data(), from: h.route)
        XCTAssertEqual(h.updates, [update, fence])
        XCTAssertEqual(h.sent.last, Data("resync".utf8))
        XCTAssertEqual(h.channel.phase, .closed)
        XCTAssertEqual(other.channel.phase, .ready)
        XCTAssertTrue(other.closed.isEmpty)
        other.channel.disconnect()
    }

    @MainActor
    func testOperationRefusalKeepsChannelButTransportAndCoreFailuresCloseIt() async throws {
        let h = Harness()
        try await h.welcome()
        h.core.operationError = RemoteChannelError.invalidInput
        XCTAssertThrowsError(try h.channel.perform(.list))
        XCTAssertEqual(h.channel.phase, .ready)
        h.core.operationError = nil
        h.sendError = RemoteChannelError.staleLink
        XCTAssertThrowsError(try h.channel.perform(.list))
        XCTAssertEqual(h.channel.phase, .closed)
        XCTAssertEqual(h.core.operations.count, 2)

        let broken = Harness()
        try await broken.welcome()
        broken.core.operationError = RemoteChannelError.invalidInput
        broken.core.closeOnOperationError = true
        XCTAssertThrowsError(try broken.channel.perform(.list))
        XCTAssertEqual(broken.channel.phase, .closed)

        let malformed = Harness()
        try await malformed.welcome()
        malformed.core.receiveError = RemoteChannelError.invalidInput
        malformed.channel.receive(Data(), from: malformed.route)
        XCTAssertEqual(malformed.channel.phase, .closed)
    }

    @MainActor
    func testObserverCanDisconnectDuringPhaseChangeWithoutSendingFinish() async throws {
        let h = Harness()
        h.onPhase = { [unowned h] phase in if phase == .awaitingWelcome { h.channel.disconnect() } }
        try h.channel.start()
        h.channel.receive(Data(), from: h.route)
        await h.drainSigner()
        XCTAssertEqual(h.channel.phase, .closed)
        XCTAssertEqual(h.sent, [Data("init".utf8)])
        XCTAssertEqual(h.closed.count, 1)
    }

    @MainActor
    func testCancelledOwnerConfirmationAndExpiredWelcomeCannotAuthorize() async throws {
        let denied = Harness()
        denied.signing = { _ in throw CancellationError() }
        try denied.channel.start()
        denied.channel.receive(Data(), from: denied.route)
        await denied.drainSigner()
        XCTAssertEqual(denied.channel.phase, .closed)
        XCTAssertEqual(denied.core.finishCalls, 0)
        XCTAssertEqual(denied.readyCount, 0)

        let expired = Harness()
        expired.core.authorization = 0
        try expired.channel.start()
        expired.channel.receive(Data(), from: expired.route)
        await expired.drainSigner()
        expired.channel.receive(Data(), from: expired.route)
        XCTAssertEqual(expired.channel.phase, .closed)
        XCTAssertEqual(expired.readyCount, 0)
    }

    @MainActor
    func testDeadlineOverflowClosesBeforeSigning() throws {
        let h = Harness()
        h.now = UInt64.max - 100
        h.core.acceptDeadline = UInt64.max
        try h.channel.start()
        h.channel.receive(Data(), from: h.route)
        XCTAssertEqual(h.channel.phase, .closed)
        XCTAssertEqual(h.core.finishCalls, 0)
        XCTAssertEqual(h.sent.count, 1)
    }

    func testRouteHandleValidation() throws {
        for handle in ["", "has space", "a/b", "ä", String(repeating: "x", count: 65)] {
            XCTAssertThrowsError(try RemoteChannelRoute(linkGeneration: UUID(), handle: handle))
        }
        XCTAssertNoThrow(try RemoteChannelRoute(linkGeneration: UUID(), handle: "A-1_z"))
    }
}
