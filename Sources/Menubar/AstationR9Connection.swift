import AtemClient
import AstationRemote
import Foundation

/// One verified host link, with no older-protocol transport path.
@MainActor
final class AstationR9Connection {
    let context: AtemSessionContext
    private(set) var hostPolicyBinding: AtemHostPolicyBinding?
    let generation: UUID
    var isClosed: Bool { closed }
    var isCurrent: Bool { !closed && current() }
    private var router: RemoteChannelRouter!
    private var queue: RemoteSocketQueue!
    private var channel: RemoteAgentChannel?
    private(set) var membershipHead: LogHead?
    private var membershipLog: MembershipLog?
    private var preparation: Task<Void, Never>?
    private var closed = false
    private let current: () -> Bool
    private let welcomed: (AtemSessionMessage) -> Void
    private let receiveMessage: (AstationMessage) -> Void
    private let failed: (String, Bool) -> Void
    private let refreshMembership: (LogHead) -> Void
    private let handshakeStarted: () -> Void
    private let policyWelcomed: () -> Void
    private let policyEvent: (ClientEvent, Bool) -> Void

    deinit { preparation?.cancel() }

    init(context: AtemSessionContext, current: @escaping () -> Bool,
         write: @escaping (Data, @escaping (Error?) -> Void) -> Void,
         welcomed: @escaping (AtemSessionMessage) -> Void,
         receive: @escaping (AstationMessage) -> Void,
         failed: @escaping (String, Bool) -> Void,
         refreshMembership: @escaping (LogHead) -> Void,
         handshakeStarted: @escaping () -> Void = {},
         policyWelcomed: @escaping () -> Void = {}, policyEvent: @escaping (ClientEvent, Bool) -> Void = { _, _ in },
         generation: UUID = UUID()) {
        self.context = context
        self.generation = generation
        self.current = current
        self.welcomed = welcomed
        receiveMessage = receive
        self.failed = failed
        self.refreshMembership = refreshMembership
        self.handshakeStarted = handshakeStarted
        self.policyWelcomed = policyWelcomed
        self.policyEvent = policyEvent
        queue = RemoteSocketQueue(write: write, failed: { [weak self] _ in
            self?.finish("The r9 connection was interrupted. Reconnect to query pending requests.")
        })
        router = RemoteChannelRouter(generation: generation,
            transport: context.route.clientId.hasPrefix("relay-") ? .relay : .direct) { [weak self] bytes in
                guard let self, !self.closed, self.current() else { throw RemoteChannelError.staleLink }
                try self.queue.enqueue(bytes)
            }
    }

    func start(identity: ClientIdentity, log: MembershipLog, signer: AstationChannelSigner) throws {
        guard preparation == nil, channel == nil, !closed, current() else { throw RemoteChannelError.staleLink }
        membershipHead = log.head()
        membershipLog = log.snapshot()
        preparation = Task { [weak self] in
            do {
                try await signer.prepare(isCurrent: { self?.current() == true && self?.closed == false })
                guard let self, !Task.isCancelled, !closed, current() else { return }
                preparation = nil
                handshakeStarted()
                guard !closed, current() else { return }
                Log.info("[R9] Opening encrypted channel to \(context.device) with membership seq \(log.head().seq)")
                channel = try router.open(hostID: context.device, identity: identity, log: log,
                    sign: { [weak self] request in
                        try await signer.sign(request, isCurrent: { self?.current() == true && self?.closed == false })
                    }, observe: { [weak self] event in self?.observe(event) })
            } catch {
                guard let self, !closed, current() else { return }
                preparation = nil
                if let failure = error as? RemoteOwnerAuthenticationError {
                    Log.warn("[R9] Owner authentication stopped before channel init: \(failure.rawValue)")
                }
                finish(Self.connectionFailureMessage(error))
            }
        }
    }

    func receive(_ bytes: Data) {
        guard !closed, current() else { return }
        router.receive(bytes, generation: generation)
    }

    func send(_ message: AstationMessage) -> Bool {
        guard !closed, current(), let channel, channel.phase == .ready, message.isPrivateAgentTraffic,
              let bytes = try? JSONEncoder().encode(message), let json = String(data: bytes, encoding: .utf8) else { return false }
        do { try channel.perform(.message(json)); return true }
        catch { return false }
    }

    func sendPolicy(_ operation: RemoteAgentOperation) -> String? {
        guard !closed, current(), let channel, channel.phase == .ready else { return nil }
        switch operation {
        case .hostPolicyGet, .hostPolicyRetry: return try? channel.perform(operation)
        default: return nil
        }
    }

    func disconnect(sendClose: Bool = true) {
        guard !closed else { return }
        closed = true
        preparation?.cancel(); preparation = nil
        hostPolicyBinding = nil
        if !sendClose { queue.drain() }
        else if current(), let channel { queue.finish(with: RemoteChannelEnvelope.close(route: channel.route)) }
        else { queue.disconnect() }
        router.linkLost()
        channel = nil
    }

    private func observe(_ event: RemoteAgentChannel.Event) {
        guard !closed, current() else { return }
        switch event {
        case .ready(let info):
            guard info.revision == 9, info.clientKind == "native", info.accountId == context.account,
                  info.atemDeviceId == context.device else { finish("Upgrade Atem to a supported r9 build.", unsupported: true); return }
            if let membershipHead, info.head.seq > membershipHead.seq {
                refresh(head: info.head); return
            }
            guard let membershipLog else { finish("Account membership is unavailable."); return }
            Log.info("[R9] Encrypted channel to \(context.device) ready; local membership seq \(membershipLog.head().seq), host seq \(info.head.seq)")
            hostPolicyBinding = AtemHostPolicyBinding(genesis: membershipLog.genesisHash(), manager: AstationIdentity.shared.id,
                trust: info.hostTrustGen, channel: info.channelId, attachment: info.attachmentGen,
                supported: info.features.contains("host.policy"))
            var welcome = AtemSessionMessage(op: "welcome")
            welcome.revision = info.revision; welcome.features = info.features
            welcome.account_id = info.accountId; welcome.atem_device_id = info.atemDeviceId
            welcome.host_trust_gen = info.hostTrustGen; welcome.runtime_gen = info.runtimeGen
            welcome.controller_session = info.controllerSession; welcome.attachment_gen = info.attachmentGen
            welcome.client_kind = info.clientKind; welcome.permissions = info.permissions
            welcome.authorization_ms_left = info.authorizationMsLeft; welcome.server_time = info.serverTime
            welcomed(welcome)
            policyWelcomed()
        case .update(let update):
            switch update {
            case .hostPolicy(_, _, _, _, _, _, let observed, let json),
                 .hostPolicyChanged(_, _, _, let observed, let json):
                guard observed != "foreign", acceptPolicyHead(json) else { return }
                policyEvent(update, channel?.hostPolicyReady == true)
            case .session(_, _, _, let json), .family(_, _, let json), .error(_, _, _, let json):
                if case .error = update { policyEvent(update, false) }
                guard let message = try? AstationMessage.decodePacket(Data(json.utf8)) else {
                    finish("Atem sent an invalid r9 application message."); return
                }
                receiveMessage(message)
            case .fenced:
                finish("Atem revoked or reset this channel. Reconnect to verify current membership.")
            case .membershipHead(_, let head, _):
                if let relation = try? membershipLog?.relation(head: head), relation == .same || relation == .hostBehind { return }
                if head != membershipHead { refresh(head: head) }
            default: break
            }
        case .closed(let error):
            let unsupported: Bool
            if let error = error as? AtemError, case .Refused(let code, _, _, _) = error { unsupported = code == "unsupported_version" }
            else { unsupported = false }
            finish(unsupported ? "Upgrade Atem to a supported r9 build."
                : Self.connectionFailureMessage(error), unsupported: unsupported, sendClose: false)
        default: break
        }
    }

    static func connectionFailureMessage(_ error: Error?) -> String {
        if let error = error as? RemoteOwnerAuthenticationError {
            switch error {
            case .notForeground:
                return "Bring Astation to the foreground, then retry. The encrypted connection has not started."
            case .denied:
                return "Touch ID or password confirmation was not completed. Retry to confirm access."
            case .expired:
                return "Your owner confirmation expired. Retry to confirm access."
            case .cancelled, .invalidated, .staleContext:
                return "Connection confirmation was interrupted. Retry to confirm access."
            }
        }
        if error as? RemoteRecoveryError == .confirmationRequired {
            return "Open Astation and confirm with Touch ID or your password, then retry the connection."
        }
        if error as? RemoteChannelError == .deadlineExceeded {
            return "The encrypted r9 connection timed out. Retry the connection."
        }
        return "The encrypted r9 channel closed. Retry the connection to verify current account access."
    }

    private func acceptPolicyHead(_ json: String) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let data = root["data"] as? [String: Any], let head = data["head"] as? [String: Any],
              let seq = head["seq"] as? UInt64, let hash = head["hash"] as? String else {
            finish("Atem sent an invalid policy membership head."); return false
        }
        let received = LogHead(seq: seq, hash: hash)
        guard received == membershipHead else { refresh(head: received); return false }
        return true
    }

    private func refresh(head: LogHead) {
        finish("Account membership changed. Verifying the signed update before reconnecting.")
        refreshMembership(head)
    }

    private func finish(_ message: String, unsupported: Bool = false, sendClose: Bool = true) {
        guard !closed else { return }
        disconnect(sendClose: sendClose)
        failed(message, unsupported)
    }
}
