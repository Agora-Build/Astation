import AtemClient
import Foundation

/// A native/mobile/service controller's own outbound connection. No running Mac or pairing-room owner is used.
@MainActor
public final class RemoteRelayClient {
    private let socket: URLSessionWebSocketTask
    private let hostID: String
    private let generation = UUID()
    private var router: RemoteChannelRouter!
    private var queue: RemoteSocketQueue!
    private var channel: RemoteAgentChannel?
    private var reader: Task<Void, Never>?
    private var connected = false
    private var started = false
    private let observe: (RemoteAgentChannel.Event) -> Void

    public init(relayURL: URL, genesis: String, hostID: String, accessToken: String,
                session: URLSession = .shared, observe: @escaping (RemoteAgentChannel.Event) -> Void) throws {
        guard var url = URLComponents(url: relayURL, resolvingAgainstBaseURL: false),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              ["https", "wss"].contains(url.scheme) || (["http", "ws"].contains(url.scheme) && ["127.0.0.1", "localhost", "::1"].contains(url.host)),
              genesis.utf8.count == 64, genesis.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !hostID.isEmpty, hostID.utf8.count <= 128, !accessToken.isEmpty,
              !accessToken.contains("\r"), !accessToken.contains("\n") else { throw RemoteChannelError.invalidInput }
        url.scheme = ["https", "wss"].contains(url.scheme) ? "wss" : "ws"
        url.path = "/api/remote/v1/channels"
        url.queryItems = [URLQueryItem(name: "genesis", value: genesis), URLQueryItem(name: "host", value: hostID)]
        guard let endpoint = url.url else { throw RemoteChannelError.invalidInput }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        socket = session.webSocketTask(with: request)
        self.hostID = hostID
        socket.maximumMessageSize = RemoteChannelEnvelope.maximumBytes
        self.observe = observe
        queue = RemoteSocketQueue(write: { [weak self] frame, completion in
            guard let self, self.connected, let text = String(data: frame, encoding: .utf8) else {
                completion(RemoteChannelError.staleLink); return
            }
            self.socket.send(.string(text)) { completion($0) }
        }, failed: { [weak self] _ in self?.disconnect() })
        router = RemoteChannelRouter(generation: generation, transport: .relay) { [weak self] frame in
            guard let self, self.connected else { throw RemoteChannelError.staleLink }
            try self.queue.enqueue(frame)
        }
    }

    public func connect(identity: ClientIdentity, log: MembershipLog,
                        sign: @escaping (SignRequest) async throws -> Data) throws {
        guard !started else { throw RemoteChannelError.alreadyStarted }
        started = true
        connected = true
        socket.resume()
        do {
            channel = try router.open(hostID: hostID, identity: identity, log: log, sign: sign,
                observe: { [weak self] event in self?.observe(event) })
        } catch { disconnect(); throw error }
        reader = Task { [weak self, socket] in
            while !Task.isCancelled {
                do {
                    let message = try await socket.receive()
                    guard let self, self.connected, !Task.isCancelled else { return }
                    let bytes: Data
                    switch message {
                    case .string(let text): bytes = Data(text.utf8)
                    case .data(let data): bytes = data
                    @unknown default: throw RemoteChannelError.invalidInput
                    }
                    self.router.receive(bytes, generation: self.generation)
                    if self.channel?.phase == .closed { self.disconnect(); return }
                } catch { self?.disconnect(); return }
            }
        }
    }

    @discardableResult public func perform(_ operation: RemoteAgentOperation) throws -> String {
        guard connected, let channel else { throw RemoteChannelError.notReady }
        return try channel.perform(operation)
    }

    public func disconnect() {
        guard connected else { return }
        connected = false
        reader?.cancel(); reader = nil
        queue.disconnect()
        router.linkLost()
        channel = nil
        socket.cancel(with: .goingAway, reason: nil)
    }

    deinit { reader?.cancel(); socket.cancel(with: .goingAway, reason: nil) }
}
