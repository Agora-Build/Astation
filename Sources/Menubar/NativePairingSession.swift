import Foundation

/// Pairing-room messages convey routing hints, never account credentials or trust.
enum PairingIntroductionFrame: Equatable {
    struct Route: Equatable {
        let device: String
        let connection: String

        func matches(device: String) -> Bool { self.device.utf8.elementsEqual(device.utf8) }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.matches(device: rhs.device) && lhs.connection == rhs.connection
        }

        func wrap(_ payload: AtemSessionJSON) -> AtemSessionJSON {
            .object(["atem_id": .string(device), "connection_id": .string(connection), "payload": payload])
        }
    }
    case hello(String, Route)
    case error(String, String, Route)
    case relayNotice

    enum Invalid: Error { case message, unsupportedVersion }
    static let errors: Set<String> = ["unsupported_version", "invalid_request", "not_signed_in", "pairing_cancelled", "pairing_expired"]

    static func parse(_ bytes: Data) throws -> Self {
        var root = try AtemSessionJSON.parse(bytes, limit: 4096)
        if let type = root["type"]?.string, ["relayAuthChallenge", "relayAuthResult"].contains(type) { return .relayNotice }
        guard case .object(let wrapper) = root,
              let device = root["atem_id"]?.string, DeviceAuthentication.isValidAtemId(device),
              let connection = root["connection_id"]?.string, DeviceAuthentication.isValidRelayConnectionId(connection) else {
            throw Invalid.message
        }
        if let event = root["relay_event"]?.string, ["connected", "disconnected"].contains(event) {
            guard Set(wrapper.keys) == ["atem_id", "connection_id", "relay_event"] else { throw Invalid.message }
            return .relayNotice
        }
        guard Set(wrapper.keys) == ["atem_id", "connection_id", "payload"], let payload = root["payload"] else {
            throw Invalid.message
        }
        let route = Route(device: device, connection: connection)
        root = payload
        guard root["type"]?.string == "pairing" else { throw Invalid.unsupportedVersion }
        guard case .object(let envelope) = root, Set(envelope.keys) == ["type", "data"],
              case .object(let fields) = root["data"],
              let id = fields["id"]?.string, id.utf8.count == 36, UUID(uuidString: id) != nil else { throw Invalid.message }
        guard fields["v"] == .integer(1) else { throw Invalid.unsupportedVersion }
        switch fields["op"]?.string {
        case "hello":
            guard Set(fields.keys) == ["v", "op", "id"] else { throw Invalid.message }
            return .hello(id, route)
        case "error":
            guard Set(fields.keys) == ["v", "op", "id", "code"],
                  let code = fields["code"]?.string, errors.contains(code) else { throw Invalid.message }
            return .error(id, code, route)
        default: throw Invalid.unsupportedVersion
        }
    }

    static func introduction(id: String, astationID: String) throws -> AtemSessionJSON {
        guard id.utf8.count == 36, UUID(uuidString: id) != nil,
              (1...128).contains(astationID.utf8.count), astationID.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 58, 95].contains($0)
              }) else { throw Invalid.message }
        return .object(["type": .string("pairing"), "data": .object([
            "v": .integer(1), "op": .string("introduction"), "id": .string(id), "astation_id": .string(astationID)
        ])])
    }
}

struct NativePairingContext: Equatable {
    let accountGeneration: UUID
    let account: String
    let station: String
    let astationID: String
}

enum NativePairingState: Equatable {
    case idle, preparing, connecting, waitingForHost, waitingForVerification, confirmingPairing, verifying, verified
    case failed(String), cancelled

    var active: Bool {
        switch self {
        case .preparing, .connecting, .waitingForHost, .waitingForVerification, .confirmingPairing, .verifying: return true
        default: return false
        }
    }
    var message: String {
        switch self {
        case .idle: return "Enter the code shown by Atem. Service credentials are not required."
        case .preparing: return "Checking your Agora.Build account and selected Station..."
        case .connecting: return "Connecting to the selected Station..."
        case .waitingForHost: return "Waiting for Atem's pairing introduction..."
        case .waitingForVerification: return "Connected to Atem. Follow the pairing and safety-code prompts on both devices."
        case .confirmingPairing: return "Confirm the Atem pairing request on this Mac."
        case .verifying: return "Compare the safety codes, then confirm with Touch ID or your password."
        case .verified: return "Atem is verified and ready for permitted agent operations."
        case .failed(let message): return message
        case .cancelled: return "Pairing cancelled. No service credentials were shared."
        }
    }
}

@MainActor
final class NativePairingSession {
    struct Peer: Equatable {
        let device: String
        let session: String
        let connection: String
    }
    private(set) var state = NativePairingState.idle { didSet { changed(state) } }
    private(set) var code = ""
    private var captured: NativePairingContext?
    private var generation = UUID()
    private var helloID: String?
    private var route: PairingIntroductionFrame.Route?
    private var peer: Peer?
    private var identityConnection: String?
    private var socket: IdentityRelaySocket?
    private var preparation: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var introductionTimeout: Task<Void, Never>?
    private var noticeCount = 0
    private var helloCount = 0
    private let context: () -> NativePairingContext?
    private let authorize: () async throws -> Void
    private let makeSocket: (URL) -> IdentityRelaySocket
    private let changed: (NativePairingState) -> Void
    private let cancelPeer: (Peer) -> Void
    private let deadline: UInt64
    private let introductionDeadline: UInt64

    init(context: @escaping () -> NativePairingContext?, authorize: @escaping () async throws -> Void,
         makeSocket: @escaping (URL) -> IdentityRelaySocket, deadline: UInt64 = 600_000_000_000,
         introductionDeadline: UInt64 = 20_000_000_000,
         changed: @escaping (NativePairingState) -> Void, cancelPeer: @escaping (Peer) -> Void = { _ in }) {
        self.context = context; self.authorize = authorize; self.makeSocket = makeSocket
        self.deadline = deadline; self.changed = changed; self.cancelPeer = cancelPeer
        self.introductionDeadline = introductionDeadline
    }

    func start(code rawCode: String) {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if state.active && self.code == code && captured == context() { return }
        cancel()
        self.code = code
        let alphabet = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789".utf8)
        let bytes = Array(code.utf8)
        guard bytes.count == 9, bytes[4] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || alphabet.contains($0.element) }) else {
            state = .failed("Enter the eight-character pairing code shown by Atem, for example ABCD-2345."); return
        }
        guard let current = context() else {
            state = .failed("Sign in to Agora.Build before pairing Atem."); return
        }
        guard StationRelayURL.validatedBase(current.station) != nil,
              let url = StationRelayURL.webSocketURL(base: current.station, code: code) else {
            state = .failed("Choose a valid Station in Settings > General before pairing."); return
        }
        captured = current
        let epoch = generation
        state = .preparing
        timeout = Task { [weak self, deadline] in
            do { try await Task.sleep(nanoseconds: deadline) } catch { return }
            guard let self, epoch == self.generation, self.state.active else { return }
            self.fail("Pairing expired. Ask Atem for a fresh code and try again.")
        }
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.authorize()
                guard self.current(epoch) else { return }
                self.state = .connecting
                let task = self.makeSocket(url)
                self.socket = task
                task.resume()
                self.state = .waitingForHost
                self.introductionTimeout = Task { [weak self, introductionDeadline] in
                    do { try await Task.sleep(nanoseconds: introductionDeadline) } catch { return }
                    guard let self, self.current(epoch), self.helloID == nil else { return }
                    self.fail("Atem did not start token-free pairing. Upgrade Atem, check the selected Station, and ask Atem for a fresh code.")
                }
                self.receive(task, epoch: epoch)
            } catch {
                guard self.current(epoch) else { return }
                self.fail("Could not prepare pairing. \(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        let wasActive = state.active
        if let peer, wasActive { cancelPeer(peer) }
        generation = UUID()
        preparation?.cancel(); preparation = nil
        timeout?.cancel(); timeout = nil
        introductionTimeout?.cancel(); introductionTimeout = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        captured = nil; helloID = nil; route = nil; peer = nil; identityConnection = nil; noticeCount = 0; helloCount = 0
        if wasActive { state = .cancelled }
    }

    func contextChanged() {
        guard captured != nil, captured != context() else { return }
        if state.active { fail("Your account or selected Station changed. Start pairing again.") }
        else { cancel(); state = .idle }
    }

    func beginAuthentication(code: String, attemptID: String, device: String, connection: String) -> Bool {
        guard state == .waitingForVerification, self.code == code, helloID == attemptID,
              route?.matches(device: device) == true, current(generation) else { return false }
        identityConnection = connection
        state = .confirmingPairing
        return true
    }

    func canFinishAuthentication(code: String, attemptID: String, device: String, connection: String) -> Bool {
        state == .confirmingPairing && self.code == code && helloID == attemptID && route?.matches(device: device) == true
            && identityConnection == connection && current(generation)
    }

    func authenticated(_ peer: Peer, code: String, attemptID: String) {
        guard canFinishAuthentication(code: code, attemptID: attemptID, device: peer.device, connection: peer.connection) else { return }
        self.peer = peer
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        state = .verifying
    }

    func verificationCompleted(_ peer: Peer) {
        guard state == .verifying, self.peer == peer, current(generation) else { return }
        timeout?.cancel(); timeout = nil
        state = .verified
    }

    func verificationFailed(_ peer: Peer) {
        guard state == .verifying, self.peer == peer, current(generation) else { return }
        fail("Device verification stopped. Run 'atem pair verify' in Atem to try verification again.")
    }

    func identityConnectionClosed(device: String, connection: String) {
        guard state == .confirmingPairing || state == .verifying,
              route?.matches(device: device) == true, identityConnection == connection, current(generation) else { return }
        fail("Atem disconnected during pairing. If pairing was saved, run 'atem pair verify'; otherwise request a fresh code.")
    }

    func reject() { fail("Pairing was declined on this Mac. Start a new attempt when ready.") }

    private func current(_ epoch: UUID) -> Bool {
        guard epoch == generation, state.active else { return false }
        guard captured == context(), captured != nil else {
            fail("Your account or selected Station changed. Start pairing again."); return false
        }
        return true
    }

    private func fail(_ message: String) {
        cancel()
        state = .failed(message)
    }

    private func receive(_ task: IdentityRelaySocket, epoch: UUID) {
        task.receive { [weak self, weak task] result in
            Task { @MainActor in
                guard let self, let task, self.current(epoch), self.socket === task else { return }
                switch result {
                case .failure:
                    self.socket = nil
                    if self.helloID != nil {
                        // Atem switches from the pairing room to the identity connection.
                        return
                    }
                    self.fail("Could not reach Atem on the selected Station. Check the code and ask Atem to retry.")
                case .success(let message):
                    let bytes: Data
                    switch message {
                    case .string(let text): bytes = Data(text.utf8)
                    case .data(let data): bytes = data
                    @unknown default: self.fail("Invalid pairing response from Atem."); return
                    }
                    do {
                        switch try PairingIntroductionFrame.parse(bytes) {
                        case .relayNotice:
                            self.noticeCount += 1
                            guard self.noticeCount <= 12 else { throw PairingIntroductionFrame.Invalid.message }
                        case .error(let id, let code, let route):
                            guard self.helloID == nil || (self.helloID == id && self.route == route) else {
                                throw PairingIntroductionFrame.Invalid.message
                            }
                            if code == "unsupported_version" { throw PairingIntroductionFrame.Invalid.unsupportedVersion }
                            self.fail(code == "pairing_expired" ? "Pairing expired. Ask Atem for a fresh code."
                                : "Atem stopped pairing (\(code)). Start a new attempt.")
                            return
                        case .hello(let id, let route):
                            self.helloCount += 1
                            guard self.helloCount <= 8 else { throw PairingIntroductionFrame.Invalid.message }
                            guard self.helloID == nil || (self.helloID == id && self.route == route) else {
                                throw PairingIntroductionFrame.Invalid.message
                            }
                            guard let context = self.captured else { return }
                            let payload = try PairingIntroductionFrame.introduction(id: id, astationID: context.astationID)
                            let response = try route.wrap(payload).canonical()
                            self.helloID = id
                            self.route = route
                            self.introductionTimeout?.cancel(); self.introductionTimeout = nil
                            task.send(.string(response)) { [weak self, weak task] error in
                                guard error != nil else { return }
                                Task { @MainActor in
                                    guard let self, let task, self.current(epoch), self.socket === task else { return }
                                    self.fail("Could not send the pairing introduction. Try a fresh code.")
                                }
                            }
                            if self.state == .waitingForHost { self.state = .waitingForVerification }
                        }
                        self.receive(task, epoch: epoch)
                    } catch PairingIntroductionFrame.Invalid.unsupportedVersion {
                        self.fail("This Atem version does not support token-free pairing. Upgrade Atem, then try again.")
                    } catch {
                        self.fail("Invalid pairing response from Atem. Upgrade Atem or try a fresh code.")
                    }
                }
            }
        }
    }
}
