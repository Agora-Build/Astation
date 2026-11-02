import AstationRemote
import Foundation

/// A retired relay can finish routing handoffs, but never carries agent traffic.
@MainActor
final class StationRouteRelayBridge {
    let generation: String
    let createdAt = ProcessInfo.processInfo.systemUptime
    let account: String
    let issuer: String?
    let socket: IdentityRelaySocket
    private var verified: Bool
    private var authentication: IdentityRelayAuthenticationState
    private var sessions: [String: String]
    private var allowedSessions: Set<String>
    private let store: SessionStore
    private let astation: String
    private let key: () -> RelayIdentityKey?
    private let current: () -> Bool
    private let receive: (Data, String, String, String) -> Void
    private var closed = false

    deinit {
        if !closed { socket.cancel(with: .goingAway, reason: nil) }
    }

    init(generation: String, account: String, issuer: String?, socket: IdentityRelaySocket,
         verified: Bool, authentication: IdentityRelayAuthenticationState, clients: [ConnectedClient],
         store: SessionStore, astation: String, key: @escaping () -> RelayIdentityKey?,
         current: @escaping () -> Bool, receive: @escaping (Data, String, String, String) -> Void) {
        self.generation = generation; self.account = account; self.issuer = issuer; self.socket = socket
        self.verified = verified; self.authentication = authentication; self.store = store
        self.astation = astation; self.key = key; self.current = current; self.receive = receive
        sessions = Dictionary(clients.compactMap { client in
            client.authenticationSessionId.map { (client.id, $0) }
        }, uniquingKeysWith: { _, newer in newer })
        allowedSessions = Set(store.getAllActive().map(\.id))
    }

    func handle(_ text: String) {
        guard !closed, current() else { return }
        if let frame = RelayIdentityProtocol.parseControlFrame(text) {
            switch frame {
            case .authChallenge(let challenge):
                guard let key = key(), let signature = try? key.sign(challenge: challenge, astationId: astation),
                      let reply = RelayIdentityProtocol.authMessage(astationId: astation,
                        publicKeyHex: key.publicKeyHex, signatureHex: signature) else { return }
                sendRaw(reply)
            case .authResult(let status, _):
                verified = [RelayIdentityProtocol.statusRegistered, RelayIdentityProtocol.statusVerified].contains(status)
                if verified, let reply = RelayIdentityProtocol.sessionsMessage(sessionIds: Array(allowedSessions)) { sendRaw(reply) }
                if verified { wakeHosts() }
            default: break
            }
            return
        }
        guard verified, let bytes = text.data(using: .utf8),
              let raw = try? AtemSessionJSON.validatePacket(bytes),
              let host = raw["atem_id"]?.string, DeviceAuthentication.isValidAtemId(host),
              let connection = raw["connection_id"]?.string, DeviceAuthentication.isValidRelayConnectionId(connection) else { return }
        let client = "relay-" + host
        if let event = raw["relay_event"]?.string {
            if event == "connected" {
                if authentication.connect(clientId: client, connectionId: connection) { sessions.removeValue(forKey: client) }
                challenge(host: host, connection: connection)
            } else if event == "disconnected", authentication.disconnect(clientId: client, connectionId: connection) {
                sessions.removeValue(forKey: client)
            }
            return
        }
        guard let envelope = try? RemoteRelayEnvelope(bytes) else { return }
        let payload = envelope.payload
        if let session = session(host: host, connection: connection), RemoteStationRoute.isEnvelope(payload) {
            receive(payload, host, session, connection)
            return
        }
        guard let message = try? AstationMessage.decodePacket(payload),
              case .statusUpdate(let status, let fields) = message else { return }
        if status == "hello" {
            if authentication.connect(clientId: client, connectionId: connection) { sessions.removeValue(forKey: client) }
            challenge(host: host, connection: connection)
        } else if status == "auth", let sessionID = fields["session_id"], allowedSessions.contains(sessionID),
                  fields["atem_id"] == host, let proof = fields["proof"],
                  let challenge = authentication.challenge(clientId: client, connectionId: connection),
                  let session = store.authenticate(sessionId: sessionID, atemId: host, challenge: challenge,
                    proof: proof, astationId: astation),
                  authentication.authenticate(clientId: client, atemId: host, connectionId: connection) {
            sessions[client] = session.id
            send(.statusUpdate(status: "authenticated", data: ["method": "session_proof",
                "session_id": session.id, "protocol": DeviceAuthentication.protocolVersion]), host: host, connection: connection)
            sendPayload(RemoteStationRoute.changed, host: host, connection: connection)
        }
    }

    func session(host: String, connection: String) -> String? {
        let client = "relay-" + host
        guard !closed, current(), verified, authentication.isAuthenticated(clientId: client, connectionId: connection),
              let id = sessions[client], allowedSessions.contains(id), let session = store.get(sessionId: id),
              session.atemId == host else { return nil }
        return id
    }

    func sendPayload(_ bytes: Data, host: String, connection: String) {
        guard session(host: host, connection: connection) != nil,
              RemoteStationRoute.isEnvelope(bytes),
              let envelope = try? RemoteRelayEnvelope.wrap(bytes, host: host, connection: connection),
              let text = String(data: envelope, encoding: .utf8) else { return }
        sendRaw(text)
    }

    func wakeHosts() {
        for client in authentication.authenticatedClientIds {
            guard let connection = authentication.connectionId(for: client) else { continue }
            sendPayload(RemoteStationRoute.changed, host: String(client.dropFirst(6)), connection: connection)
        }
    }

    func remove(host: String) {
        let client = "relay-" + host
        if let id = sessions.removeValue(forKey: client) { allowedSessions.remove(id) }
        allowedSessions = allowedSessions.filter { store.get(sessionId: $0)?.atemId != host }
        if let connection = authentication.connectionId(for: client) {
            _ = authentication.disconnect(clientId: client, connectionId: connection)
        }
        if allowedSessions.isEmpty { close() }
    }

    func close() {
        guard !closed else { return }
        closed = true; authentication.removeAll(); sessions.removeAll(); allowedSessions.removeAll()
        socket.cancel(with: .goingAway, reason: nil)
    }

    private func challenge(host: String, connection: String) {
        let client = "relay-" + host
        guard !authentication.isAuthenticated(clientId: client, connectionId: connection) else { return }
        let value = authentication.challenge(clientId: client, connectionId: connection) ?? DeviceAuthentication.makeChallenge()
        guard authentication.issueChallenge(clientId: client, connectionId: connection, challenge: value) else { return }
        send(.statusUpdate(status: "auth_required", data: ["astation_id": astation, "challenge": value,
            "transport": "relay", "protocol": DeviceAuthentication.protocolVersion]), host: host, connection: connection)
    }

    private func send(_ message: AstationMessage, host: String, connection: String) {
        guard let payload = try? JSONEncoder().encode(message),
              let wrapped = try? RemoteRelayEnvelope.wrap(payload, host: host, connection: connection),
              let text = String(data: wrapped, encoding: .utf8) else { return }
        sendRaw(text)
    }

    private func sendRaw(_ text: String) {
        guard !closed, current() else { return }
        socket.send(.string(text)) { _ in }
    }
}
