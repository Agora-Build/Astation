import AtemClient
import Foundation

public enum RemoteChannelError: Error, Equatable {
    case invalidInput
    case staleLink
    case notReady
    case alreadyStarted
    case deadlineExceeded
}

public struct RemoteChannelRoute: Equatable, Sendable {
    public let linkGeneration: UUID
    public let handle: String

    public init(linkGeneration: UUID, handle: String) throws {
        guard Self.isValidHandle(handle) else { throw RemoteChannelError.invalidInput }
        self.linkGeneration = linkGeneration
        self.handle = handle
    }

    static func isValidHandle(_ handle: String) -> Bool {
        (1...64).contains(handle.utf8.count) && handle.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) ||
            (48...57).contains($0) || $0 == 45 || $0 == 95
        })
    }
}

public enum RemoteAgentOperation: Equatable, Sendable {
    /// Validated session/terminal/chat messages built by a platform presentation adapter.
    case message(String)
    case list
    case chatOpen(session: String, conversation: String)
    case terminalSubscribe(session: String)
    case acquire(session: String, takeover: Bool)
    case renew(session: String)
    case release(session: String)
    case prompt(session: String, request: String, text: String)
    case interrupt(session: String, request: String)
    case stop(session: String, request: String)
    case approval(session: String, request: String, approval: String, decision: ApprovalChoice, rule: String?, message: String?)
    case revokeRule(session: String, request: String, rule: String)
    case approvalSeen(session: String, approval: String)
    case receipts(session: String, requests: [String])
}

/// The router supplies inner frames only. Closing here closes one virtual channel, never its host socket.
@MainActor
public final class RemoteAgentChannel {
    public enum Phase: Equatable { case new, awaitingAccept, signing, awaitingWelcome, ready, closed }
    public enum Event {
        case phase(Phase)
        case ready(WelcomeInfo)
        case update(ClientEvent)
        case closed(Error?)
    }

    public let route: RemoteChannelRoute
    public private(set) var phase = Phase.new
    private let core: RemoteChannelCore
    private let clock: () -> UInt64
    private let sign: (SignRequest) async throws -> Data
    private let send: (RemoteChannelRoute, Data) throws -> Void
    private let closeTransport: (RemoteChannelRoute) -> Void
    private let observe: (Event) -> Void
    private var deadline: UInt64?
    private var timer: Task<Void, Never>?
    private var signer: Task<Void, Never>?
    private let automaticTimer: Bool

    public convenience init(
        route: RemoteChannelRoute, hostID: String, identity: ClientIdentity, log: MembershipLog,
        needBefore: UInt64? = nil,
        clock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds / 1_000_000 },
        sign: @escaping (SignRequest) async throws -> Data,
        send: @escaping (RemoteChannelRoute, Data) throws -> Void,
        close: @escaping (RemoteChannelRoute) -> Void,
        observe: @escaping (Event) -> Void
    ) throws {
        let core = try SharedRemoteChannelCore(hostID: hostID, identity: identity, log: log, needBefore: needBefore)
        self.init(route: route, core: core, clock: clock, sign: sign, send: send, close: close, observe: observe)
    }

    init(
        route: RemoteChannelRoute, core: RemoteChannelCore, clock: @escaping () -> UInt64,
        automaticTimer: Bool = true, sign: @escaping (SignRequest) async throws -> Data,
        send: @escaping (RemoteChannelRoute, Data) throws -> Void,
        close: @escaping (RemoteChannelRoute) -> Void, observe: @escaping (Event) -> Void
    ) {
        self.route = route
        self.core = core
        self.clock = clock
        self.automaticTimer = automaticTimer
        self.sign = sign
        self.send = send
        closeTransport = close
        self.observe = observe
    }

    deinit { timer?.cancel(); signer?.cancel() }

    public func start() throws {
        guard phase == .new else { throw RemoteChannelError.alreadyStarted }
        do {
            let frame = try core.start(now: clock())
            deadline = core.acceptDeadline
            transition(.awaitingAccept)
            try transmit(frame)
            if automaticTimer && phase != .closed {
                timer = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                        guard let self, self.phase != .closed else { return }
                        self.checkDeadline()
                    }
                }
            }
        } catch { finish(error); throw error }
    }

    public func receive(_ frame: Data, from route: RemoteChannelRoute) {
        guard route == self.route, phase != .closed else { return }
        checkDeadline()
        guard phase != .closed else { return }
        do {
            switch phase {
            case .awaitingAccept:
                let request = try core.accept(frame, now: clock())
                deadline = try addingDeadline(10_000)
                transition(.signing)
                guard phase == .signing else { return }
                signer = Task { [weak self, sign] in
                    do {
                        let signature = try await sign(request)
                        guard let self, !Task.isCancelled, self.phase == .signing else { return }
                        self.checkDeadline()
                        guard self.phase == .signing else { return }
                        let finish = try self.core.finish(signature, now: self.clock())
                        self.transition(.awaitingWelcome)
                        try self.transmit(finish)
                    } catch {
                        guard let self, self.phase != .closed else { return }
                        self.finish(error)
                    }
                }
            case .awaitingWelcome:
                let welcome = try core.welcome(frame, now: clock())
                guard welcome.authorizationMsLeft > 0 else { throw RemoteChannelError.deadlineExceeded }
                deadline = try addingDeadline(welcome.authorizationMsLeft)
                transition(.ready)
                if phase == .ready { observe(.ready(welcome)) }
            case .ready:
                for event in try core.receive(frame, now: clock()) {
                    guard phase == .ready else { break }
                    switch event {
                    case .outgoing(let outgoing): try transmit(outgoing)
                    case .fenced:
                        observe(.update(event))
                        finish(nil)
                    default: observe(.update(event))
                    }
                }
            default: throw RemoteChannelError.notReady
            }
        } catch { finish(error) }
    }

    /// Caller retains request IDs durably before submitting; this adapter never retries a command.
    @discardableResult
    public func perform(_ operation: RemoteAgentOperation) throws -> String {
        checkDeadline()
        guard phase == .ready else { throw RemoteChannelError.notReady }
        let outgoing: Outgoing
        do { outgoing = try core.perform(operation, now: clock()) }
        catch {
            if core.isClosed { finish(error) }
            throw error
        }
        do { try transmit(outgoing.frame) }
        catch { finish(error); throw error }
        return outgoing.id
    }

    public func linkLost(generation: UUID) {
        guard generation == route.linkGeneration else { return }
        finish(RemoteChannelError.staleLink)
    }

    public func disconnect() { finish(nil) }

    func checkDeadline() {
        if let deadline, clock() >= deadline { finish(RemoteChannelError.deadlineExceeded) }
    }

    private func addingDeadline(_ interval: UInt64) throws -> UInt64 {
        let (result, overflow) = clock().addingReportingOverflow(interval)
        guard !overflow else { throw RemoteChannelError.deadlineExceeded }
        return result
    }

    private func transmit(_ frame: Data) throws {
        guard phase != .closed else { throw RemoteChannelError.notReady }
        try send(route, frame)
    }

    private func transition(_ phase: Phase) {
        self.phase = phase
        observe(.phase(phase))
    }

    private func finish(_ error: Error?) {
        guard phase != .closed else { return }
        phase = .closed
        timer?.cancel(); timer = nil
        signer?.cancel(); signer = nil
        core.disconnect()
        deadline = nil
        closeTransport(route)
        observe(.phase(.closed))
        observe(.closed(error))
    }
}

@MainActor
protocol RemoteChannelCore: AnyObject {
    var acceptDeadline: UInt64? { get }
    var isClosed: Bool { get }
    func start(now: UInt64) throws -> Data
    func accept(_ frame: Data, now: UInt64) throws -> SignRequest
    func finish(_ signature: Data, now: UInt64) throws -> Data
    func welcome(_ frame: Data, now: UInt64) throws -> WelcomeInfo
    func receive(_ frame: Data, now: UInt64) throws -> [ClientEvent]
    func perform(_ operation: RemoteAgentOperation, now: UInt64) throws -> Outgoing
    func disconnect()
}

@MainActor
private final class SharedRemoteChannelCore: RemoteChannelCore {
    private let connection: ClientConnection
    private let log: MembershipLog

    init(hostID: String, identity: ClientIdentity, log: MembershipLog, needBefore: UInt64?) throws {
        connection = try ClientConnection(hostId: hostID, identity: identity, needBefore: needBefore)
        self.log = log
    }

    var acceptDeadline: UInt64? { connection.acceptDeadlineMs() }
    var isClosed: Bool { connection.isClosed() }
    func start(now: UInt64) throws -> Data { try connection.start(log: log, nowMs: now) }
    func accept(_ frame: Data, now: UInt64) throws -> SignRequest {
        try connection.onAcceptDeferred(frame: frame, log: log, nowMs: now)
    }
    func finish(_ signature: Data, now: UInt64) throws -> Data {
        try connection.finishWithSignature(signature: signature, nowMs: now)
    }
    func welcome(_ frame: Data, now: UInt64) throws -> WelcomeInfo {
        try connection.onWelcome(frame: frame, log: log, nowMs: now)
    }
    func receive(_ frame: Data, now: UInt64) throws -> [ClientEvent] { try connection.onFrame(frame: frame, nowMs: now) }
    func disconnect() { connection.disconnect() }

    func perform(_ operation: RemoteAgentOperation, now: UInt64) throws -> Outgoing {
        switch operation {
        case let .message(json):
            return Outgoing(id: "", frame: try connection.sendJson(messageJson: json, nowMs: now))
        case .list: return try connection.list(nowMs: now)
        case let .chatOpen(session, conversation): return try connection.chatOpen(sessionId: session, conversationId: conversation, nowMs: now)
        case let .terminalSubscribe(session): return try connection.terminalSubscribe(sessionId: session, nowMs: now)
        case let .acquire(session, takeover): return try connection.acquire(sessionId: session, takeover: takeover, nowMs: now)
        case let .renew(session): return try connection.renew(sessionId: session, nowMs: now)
        case let .release(session): return try connection.release(sessionId: session, nowMs: now)
        case let .prompt(session, request, text): return try connection.submitPrompt(sessionId: session, requestId: request, text: text, nowMs: now)
        case let .interrupt(session, request): return try connection.submitInterrupt(sessionId: session, requestId: request, nowMs: now)
        case let .stop(session, request): return try connection.submitStop(sessionId: session, requestId: request, nowMs: now)
        case let .approval(session, request, approval, decision, rule, message):
            return try connection.submitApproval(sessionId: session, requestId: request, approvalId: approval, decision: decision, ruleId: rule, message: message, nowMs: now)
        case let .revokeRule(session, request, rule): return try connection.submitRuleRevoke(sessionId: session, requestId: request, ruleId: rule, nowMs: now)
        case let .approvalSeen(session, approval): return try connection.approvalSeen(sessionId: session, approvalId: approval, nowMs: now)
        case let .receipts(session, requests): return try connection.receiptQuery(sessionId: session, requestIds: requests, nowMs: now)
        }
    }
}
