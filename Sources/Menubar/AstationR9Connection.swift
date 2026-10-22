import AtemClient
import AstationRemote
import Foundation

/// One verified host link, with no older-protocol transport path.
@MainActor
final class AstationR9Connection {
    let context: AtemSessionContext
    private let generation = UUID()
    private var router: RemoteChannelRouter!
    private var queue: RemoteSocketQueue!
    private var channel: RemoteAgentChannel?
    private var membershipHead: LogHead?
    private var membershipLog: MembershipLog?
    private var closed = false
    private let current: () -> Bool
    private let welcomed: (AtemSessionMessage) -> Void
    private let receiveMessage: (AstationMessage) -> Void
    private let failed: (String, Bool) -> Void
    private let refreshMembership: (LogHead) -> Void

    init(context: AtemSessionContext, current: @escaping () -> Bool,
         write: @escaping (Data, @escaping (Error?) -> Void) -> Void,
         welcomed: @escaping (AtemSessionMessage) -> Void,
         receive: @escaping (AstationMessage) -> Void,
         failed: @escaping (String, Bool) -> Void,
         refreshMembership: @escaping (LogHead) -> Void) {
        self.context = context
        self.current = current
        self.welcomed = welcomed
        receiveMessage = receive
        self.failed = failed
        self.refreshMembership = refreshMembership
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
        membershipHead = log.head()
        membershipLog = log.snapshot()
        channel = try router.open(hostID: context.device, identity: identity, log: log,
            sign: { [weak self] request in
                try await signer.sign(request, isCurrent: { self?.current() == true && self?.closed == false })
            }, observe: { [weak self] event in self?.observe(event) })
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

    func disconnect(sendClose: Bool = true) {
        guard !closed else { return }
        closed = true
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
            var welcome = AtemSessionMessage(op: "welcome")
            welcome.revision = info.revision; welcome.features = info.features
            welcome.account_id = info.accountId; welcome.atem_device_id = info.atemDeviceId
            welcome.host_trust_gen = info.hostTrustGen; welcome.runtime_gen = info.runtimeGen
            welcome.controller_session = info.controllerSession; welcome.attachment_gen = info.attachmentGen
            welcome.client_kind = info.clientKind; welcome.permissions = info.permissions
            welcome.authorization_ms_left = info.authorizationMsLeft; welcome.server_time = info.serverTime
            welcomed(welcome)
        case .update(let update):
            switch update {
            case .session(_, _, _, let json), .family(_, _, let json), .error(_, _, _, let json):
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
                : "The encrypted r9 channel closed. Reconnect or complete r9 device verification.", unsupported: unsupported, sendClose: false)
        default: break
        }
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
