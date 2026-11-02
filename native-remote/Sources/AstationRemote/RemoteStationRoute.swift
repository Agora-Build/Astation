import AtemClient
import Foundation

public enum RemoteStationRoute {
    public static let maximumBytes = 4096
    public static let changed = Data(#"{"type":"stationRoute","data":{"v":1,"op":"changed"}}"#.utf8)

    public struct Host: Decodable, Equatable, Sendable {
        public let astation_id: String
        public let atem_id: String
        public let binding_id: String
        public let host_trust_gen: UInt64
        public let session_id: String
        public let host_device_id: String?
        public let account_id: String?
        public let genesis_hash: String?
    }

    public struct Request: Decodable, Equatable, Sendable {
        public let id: String
        public let context: Host
        public let route_revision: UInt64
        public let policy_revision: UInt64
    }

    public struct Anchor: Equatable, Sendable {
        public let account: String
        public let genesis: String
        public let host: String
        public let trust: UInt64

        public init(account: String, genesis: String, host: String, trust: UInt64) {
            self.account = account; self.genesis = genesis; self.host = host; self.trust = trust
        }
    }

    /// Captured app state, independent of any peer-supplied endpoint or permission.
    public struct Context: Equatable, Sendable {
        public let client: String
        public let connection: String
        public let transport: String
        public let accountGeneration: UUID
        public let account: String
        public let astation: String
        public let atem: String
        public let session: String
        public let station: String
        public let relayOnly: Bool
        public let direct: Bool
        public let anchor: Anchor?

        public init(client: String, connection: String, transport: String, accountGeneration: UUID,
                    account: String, astation: String, atem: String, session: String, station: String,
                    relayOnly: Bool, direct: Bool, anchor: Anchor?) {
            self.client = client; self.connection = connection; self.transport = transport
            self.accountGeneration = accountGeneration; self.account = account; self.astation = astation
            self.atem = atem; self.session = session; self.station = station
            self.relayOnly = relayOnly; self.direct = direct; self.anchor = anchor
        }

        func accepts(_ host: Host) -> Bool {
            guard host.astation_id == astation, host.atem_id == atem, host.session_id == session else { return false }
            if let anchor {
                return host.account_id == anchor.account && host.genesis_hash == anchor.genesis
                    && host.host_device_id == anchor.host && host.host_trust_gen == anchor.trust
            }
            return (host.account_id == nil || host.account_id == account)
                && (host.host_device_id == nil || host.host_device_id == atem)
        }
    }

    /// The shared binding owns strict validation, normalization and all MAC bytes.
    public struct Codec {
        public let offer: (String, String, Bool, String) throws -> String
        public let verify: (String, String, String) throws -> UInt64

        public init(offer: @escaping (String, String, Bool, String) throws -> String,
                    verify: @escaping (String, String, String) throws -> UInt64) {
            self.offer = offer; self.verify = verify
        }

        public static var shared: Codec {
            Codec(offer: { request, relay, relayOnly, token in
                try stationRouteOffer(requestJson: request, relayUrl: relay, relayOnly: relayOnly, sessionToken: token)
            }, verify: { offer, accepted, token in
                try stationRouteVerifyAccepted(offerJson: offer, acceptedJson: accepted, sessionToken: token)
            })
        }
    }

    public struct Acceptance: Equatable, Sendable {
        public let revision: UInt64
        public let policyRevision: UInt64
        public let directBlocked: Bool
        public let relayOnly: Bool
    }

    public static func isEnvelope(_ data: Data) -> Bool {
        guard data.count <= maximumBytes else { return false }
        return (try? RawFields.read(data).string("type")) == "stationRoute"
    }

    static func fields(_ data: Data) throws -> RawFields {
        guard data.count <= maximumBytes else { throw RemoteChannelError.invalidInput }
        let envelope = try RawFields.read(data)
        guard envelope.values.count == 2, envelope.string("type") == "stationRoute",
              let payload = envelope.values["data"] else { throw RemoteChannelError.invalidInput }
        let fields = try RawFields.read(payload)
        guard fields.values["v"] == Data("1".utf8) else { throw RemoteChannelError.invalidInput }
        return fields
    }
}

/// Keeps routing acknowledgments separate from encrypted-channel authorization.
@MainActor
public final class RemoteStationRouteController {
    public typealias Context = RemoteStationRoute.Context
    public typealias Acceptance = RemoteStationRoute.Acceptance
    private struct Pending {
        let context: Context
        let request: RemoteStationRoute.Request
        let offer: String
        let relayOnly: Bool
        let deadline: TimeInterval
    }
    private struct Staged {
        let context: Context
        let acceptance: Acceptance
    }
    private let codec: RemoteStationRoute.Codec
    private let current: (Context) -> Bool
    private let token: (Context) -> String?
    private let send: (Data, Context) -> Void
    private let accepted: (Context, Acceptance) -> Void
    private let now: () -> TimeInterval
    private var pending: [String: Pending] = [:]
    private var staged: [String: Staged] = [:]
    private var fallback: [String: Context] = [:]
    private var seen: [String: TimeInterval] = [:]

    public init(codec: RemoteStationRoute.Codec, current: @escaping (Context) -> Bool,
                token: @escaping (Context) -> String?, send: @escaping (Data, Context) -> Void,
                accepted: @escaping (Context, Acceptance) -> Void,
                now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.codec = codec; self.current = current; self.token = token
        self.send = send; self.accepted = accepted; self.now = now
    }

    public func receive(_ bytes: Data, context: Context) {
        prune()
        guard current(context), let fields = try? RemoteStationRoute.fields(bytes),
              let json = String(data: bytes, encoding: .utf8) else { return }
        switch fields.string("op") {
        case "request":
            guard fields.values.count == 3, let raw = fields.values["request"],
                  let request = try? JSONDecoder().decode(RemoteStationRoute.Request.self, from: raw),
                  context.accepts(request.context), seen[request.id] == nil,
                  seen.count < 128, pending.count < 64,
                  let secret = token(context), !secret.isEmpty, current(context) else { return }
            let relayOnly = context.relayOnly && (!context.direct || fallback[context.client] == context)
            guard let offer = try? codec.offer(json, context.station, relayOnly, secret),
                  offer.utf8.count <= RemoteStationRoute.maximumBytes,
                  current(context), token(context) == secret else { return }
            seen[request.id] = now() + 30
            pending[context.client] = Pending(context: context, request: request, offer: offer,
                relayOnly: relayOnly, deadline: now() + 30)
            send(Data(offer.utf8), context)
        case "accepted":
            guard let attempt = pending[context.client], attempt.context == context,
                  now() < attempt.deadline, let secret = token(context), current(context),
                  let revision = try? codec.verify(attempt.offer, json, secret),
                  let raw = fields.values["accepted"], let values = try? RawFields.read(raw),
                  let rawBlocked = values.values["direct_blocked"],
                  let blocked = try? JSONDecoder().decode(Bool.self, from: rawBlocked),
                  current(context), token(context) == secret else { return }
            let result = Acceptance(revision: revision, policyRevision: attempt.request.policy_revision,
                directBlocked: blocked, relayOnly: attempt.relayOnly)
            pending.removeValue(forKey: context.client)
            staged[context.client] = Staged(context: context, acceptance: result)
            accepted(context, result)
        default: break
        }
    }

    public func selectionChanged(_ context: Context) {
        prune()
        pending.removeValue(forKey: context.client)
        if current(context) { send(RemoteStationRoute.changed, context) }
    }

    public func requireRelay(_ context: Context) {
        guard current(context), context.direct, context.relayOnly else { return }
        fallback[context.client] = context
        selectionChanged(context)
    }

    public func stagedSelection(_ context: Context) -> Acceptance? {
        guard current(context), let value = staged[context.client], value.context == context else { return nil }
        return value.acceptance
    }

    public func disconnected(client: String) {
        pending.removeValue(forKey: client); staged.removeValue(forKey: client); fallback.removeValue(forKey: client)
    }

    public func invalidate() {
        pending.removeAll(); staged.removeAll(); fallback.removeAll(); seen.removeAll()
    }

    private func prune() {
        pending = pending.filter { now() < $0.value.deadline && current($0.value.context) }
        staged = staged.filter { current($0.value.context) }
        fallback = fallback.filter { current($0.value) }
        seen = seen.filter { now() < $0.value }
    }
}
