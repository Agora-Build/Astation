import AstationRemote
import AtemClient
import Foundation

/// One forwarding association per authenticated local socket. The shared core
/// reads control messages; signed and encrypted payloads retain their bytes.
@MainActor
final class StationLocalProxy {
    static func request(station: String, room: String, host: String, session: String,
                        generation: String, token: String) -> URLRequest? {
        guard PortalIntegrationRecord.validOrigin(station), UUID(uuidString: generation) != nil,
              !token.isEmpty, var url = URLComponents(string: station) else { return nil }
        url.scheme = url.scheme == "https" ? "wss" : "ws"
        url.path = "/ws/proxy"
        url.queryItems = [URLQueryItem(name: "room", value: room), URLQueryItem(name: "atem_id", value: host),
            URLQueryItem(name: "session_id", value: session), URLQueryItem(name: "generation", value: generation)]
        guard let endpoint = url.url else { return nil }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        return request
    }
    enum Phase { case connecting, native, proof, ready, refused, closed }
    private(set) var phase: Phase = .connecting
    private var socket: IdentityRelaySocket?
    private var channels: Set<String> = []
    private var pending: (call: String, membership: Bool, deadline: TimeInterval)?
    private var feeds: [String: String] = [:]
    private var challengeForwarded = false
    private var queue: [Data] = []
    private var queuedBytes = 0
    private var sending = false
    private var localQueue: [Data] = []
    private var localBytes = 0
    private var localSending = false
    private var attempt = UUID()
    private var retryCount = 0
    private var timer: Task<Void, Never>?
    private let current: () -> Bool
    private let connect: () async throws -> IdentityRelaySocket
    private let sign: (String) throws -> String
    private let writeLocal: (Data, @escaping (Error?) -> Void) -> Void
    private let closeLocal: (Data) -> Void
    private let now: () -> TimeInterval

    deinit { timer?.cancel(); socket?.cancel(with: .goingAway, reason: nil) }

    init(current: @escaping () -> Bool, connect: @escaping () async throws -> IdentityRelaySocket,
         sign: @escaping (String) throws -> String,
         writeLocal: @escaping (Data, @escaping (Error?) -> Void) -> Void,
         closeLocal: @escaping (Data) -> Void,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.current = current; self.connect = connect; self.sign = sign
        self.writeLocal = writeLocal; self.closeLocal = closeLocal; self.now = now
    }

    func start() {
        guard current(), phase != .closed, phase != .refused else { return }
        let generation = UUID(); attempt = generation; phase = .connecting
        Task { [weak self] in
            guard let self else { return }
            do {
                let socket = try await self.connect()
                guard self.attempt == generation, self.current(), self.phase != .closed else {
                    socket.cancel(with: .goingAway, reason: nil); return
                }
                self.socket = socket; self.phase = .native
                socket.resume(); self.read(socket)
                self.timer?.cancel()
                self.timer = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    guard !Task.isCancelled, let self, self.attempt == generation,
                          self.phase != .ready else { return }
                    self.failed()
                }
            } catch { if self.attempt == generation { self.failed() } }
        }
    }

    private func read(_ task: IdentityRelaySocket) {
        task.receive { [weak self, weak task] result in
            Task { @MainActor in
                guard let self, let task, self.socket === task, self.current() else { return }
                switch result {
                case .success(.string(let text)):
                    self.receiveStation(Data(text.utf8)); if self.socket === task { self.read(task) }
                case .success: self.failed()
                case .failure: self.failed()
                }
            }
        }
    }

    func receiveStation(_ bytes: Data) {
        guard current(), phase != .closed, phase != .refused,
              let text = String(data: bytes, encoding: .utf8) else { return }
        if let control = RelayIdentityProtocol.parseControlFrame(text) {
            switch control {
            case .authChallenge(let challenge) where phase == .native:
                do { enqueue(Data(try sign(challenge).utf8)) } catch { failed() }
            case .authResult(let status, _) where phase == .native:
                if status == RelayIdentityProtocol.statusVerified { phase = .proof }
                else { refuse() }
            default: break
            }
            return
        }
        guard let fields = try? AtemSessionJSON.validatePacket(bytes), case .object(let object) = fields else { return }
        if fields["type"]?.string == "relay" {
            let op = fields["op"]?.string
            if phase == .proof, op == "host_challenge", !challengeForwarded {
                challengeForwarded = true; forwardLocal(bytes); return
            }
            if phase == .proof, challengeForwarded, op == "host_route_ok" {
                phase = .ready; retryCount = 0; timer?.cancel(); forwardLocal(bytes); return
            }
            if phase == .proof, op == "host_route_refused" {
                refuse(finalLocal: bytes); return
            }
            guard phase == .ready, let reply = try? relayDecodeToHost(message: text) else { return }
            switch reply {
            case .heads(let heads, _):
                feeds = Dictionary(heads.map { ($0.origin, $0.feedId) }, uniquingKeysWith: { _, latest in latest })
            case .controlSyncResult(_, let origin, let feed, _, _, _, _):
                guard let pending, !pending.membership, pending.deadline > now(),
                      feeds[origin] == feed,
                      (try? relayControlSyncAnswers(call: pending.call, result: text)) == .answers else { return }
                self.pending = nil
            case .membershipFetchResult, .membershipFetchRefused:
                guard let pending, pending.membership, pending.deadline > now() else { return }
                self.pending = nil
            case .controlSyncRefused:
                guard let pending, !pending.membership, pending.deadline > now() else { return }
                self.pending = nil
            case .controlAckRefused: break
            }
            forwardLocal(bytes)
        } else if phase == .ready, fields["type"]?.string == "channel",
                  let handle = fields["channel"]?.string, RemoteChannelRoute.isValidHandle(handle) {
            switch fields["event"]?.string {
            case "open":
                guard Set(object.keys) == ["type", "event", "channel", "transport"],
                      fields["transport"]?.string == "relay", channels.count < 64,
                      !channels.contains(handle) else { failed(); return }
                channels.insert(handle)
            case "frame": guard channels.contains(handle), (try? RemoteChannelEnvelope.readHost(bytes)) != nil else { return }
            case "close": guard (try? RemoteChannelEnvelope.readHost(bytes)) != nil,
                                channels.remove(handle) != nil else { return }
            default: return
            }
            forwardLocal(bytes)
        }
    }

    /// Returns true only for traffic this proxy owns. Native channels keep their
    /// own dispatcher and never become Station traffic.
    @discardableResult func receiveHost(_ bytes: Data) -> Bool {
        guard current(), phase != .closed, phase != .refused,
              let fields = try? AtemSessionJSON.validatePacket(bytes),
              let text = String(data: bytes, encoding: .utf8) else { return false }
        if fields["type"]?.string == "channel", let handle = fields["channel"]?.string, channels.contains(handle) {
            guard phase == .ready, let event = try? RemoteChannelEnvelope.readHost(bytes) else { return true }
            if case .close = event { channels.remove(handle) }
            enqueue(bytes); return true
        }
        guard fields["type"]?.string == "relay" else { return false }
        if phase == .proof, challengeForwarded, fields["op"]?.string == "host_route" {
            enqueue(bytes); return true
        }
        guard phase == .ready, let call = try? relayDecodeToStation(message: text) else { return true }
        switch call {
        case .controlSync, .membershipFetch:
            guard pending == nil else { failed(); return true }
            let membership: Bool
            if case .membershipFetch = call { membership = true } else { membership = false }
            pending = (text, membership, now() + 30)
            timer?.cancel()
            let generation = attempt
            timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self, self.attempt == generation, self.pending != nil else { return }
                self.failed()
            }
        case .controlAck: break
        }
        enqueue(bytes); return true
    }

    private func enqueue(_ bytes: Data) {
        guard socket != nil, queue.count < 128, bytes.count <= RemoteChannelEnvelope.maximumBytes,
              queuedBytes + bytes.count <= 8 * 1024 * 1024 else { failed(); return }
        queue.append(bytes); queuedBytes += bytes.count; flush()
    }

    private func flush() {
        guard !sending, let socket, let bytes = queue.first, current() else { return }
        sending = true
        socket.send(.string(String(decoding: bytes, as: UTF8.self))) { [weak self, weak socket] error in
            Task { @MainActor in
                guard let self, let socket, self.socket === socket else { return }
                if error != nil { self.failed(); return }
                self.queue.removeFirst(); self.queuedBytes -= bytes.count; self.sending = false; self.flush()
            }
        }
    }

    private func forwardLocal(_ bytes: Data) {
        guard localQueue.count < 128, localBytes + bytes.count <= 8 * 1024 * 1024 else { failed(); return }
        localQueue.append(bytes); localBytes += bytes.count; flushLocal()
    }

    private func flushLocal() {
        guard !localSending, let bytes = localQueue.first, current() else { return }
        localSending = true; let generation = attempt
        writeLocal(bytes) { [weak self] error in
            Task { @MainActor in
                guard let self, self.attempt == generation else { return }
                if error != nil { self.failed(); return }
                self.localQueue.removeFirst(); self.localBytes -= bytes.count
                self.localSending = false; self.flushLocal()
            }
        }
    }

    private func clearTransport() {
        timer?.cancel(); timer = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        pending = nil; feeds.removeAll(); challengeForwarded = false
        queue.removeAll(); queuedBytes = 0; sending = false
        localQueue.removeAll(); localBytes = 0; localSending = false
        // Closing old channels remains necessary after account/Station authority
        // changes. The close-only writer still fences the local socket generation.
        for handle in channels {
            if let route = try? RemoteChannelRoute(linkGeneration: UUID(), handle: handle) {
                closeLocal(RemoteChannelEnvelope.close(route: route))
            }
        }
        channels.removeAll()
    }

    private func refuse(finalLocal: Data? = nil) {
        attempt = UUID(); phase = .refused; clearTransport()
        // The old queue is retired, but Atem still needs the definitive verdict.
        if let finalLocal, current() { writeLocal(finalLocal) { _ in } }
    }

    private func failed() {
        guard phase != .closed, phase != .refused else { return }
        attempt = UUID(); clearTransport(); phase = .connecting
        guard current() else { close(); return }
        retryCount = min(retryCount + 1, 6)
        let delay = min(pow(2, Double(retryCount)), 30)
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }; self?.start()
        }
    }

    func close() { attempt = UUID(); phase = .closed; clearTransport() }
}
