import AtemClient
import Foundation

/// One router per live host connection. Possessing a route grants no endpoint authority.
@MainActor
public final class RemoteChannelRouter {
    public let writer: RemoteChannelWriter
    public var count: Int { channels.count }
    private var channels: [String: RemoteAgentChannel] = [:]

    public init(generation: UUID, transport: RemoteChannelTransport, write: @escaping (Data) throws -> Void) {
        writer = RemoteChannelWriter(generation: generation, transport: transport, write: write)
    }

    public func open(hostID: String, identity: ClientIdentity, log: MembershipLog, needBefore: UInt64? = nil,
        sign: @escaping (SignRequest) async throws -> Data,
        observe: @escaping (RemoteAgentChannel.Event) -> Void) throws -> RemoteAgentChannel {
        try open(make: { route, send, close, events in
            try RemoteAgentChannel(route: route, hostID: hostID, identity: identity, log: log,
                needBefore: needBefore, sign: sign, send: send, close: close, observe: events)
        }, observe: observe)
    }

    typealias ChannelFactory = (RemoteChannelRoute,
        @escaping (RemoteChannelRoute, Data) throws -> Void,
        @escaping (RemoteChannelRoute) -> Void,
        @escaping (RemoteAgentChannel.Event) -> Void) throws -> RemoteAgentChannel

    func open(make: ChannelFactory, observe: @escaping (RemoteAgentChannel.Event) -> Void) throws -> RemoteAgentChannel {
        let route = try writer.open()
        do {
            let channel = try make(route, { [weak self] route, frame in
                guard let self else { throw RemoteChannelError.staleLink }
                try self.writer.send(frame, to: route)
            }, { [weak self] route in self?.writer.close(route) }, { [weak self] event in
                guard let self else { return }
                if case .ready = event { try? self.writer.welcomed(route) }
                if case .closed = event { self.channels.removeValue(forKey: route.handle) }
                observe(event)
            })
            guard writer.contains(route) else { throw RemoteChannelError.staleLink }
            channels[route.handle] = channel
            try channel.start()
            return channel
        } catch {
            writer.close(route)
            channels.removeValue(forKey: route.handle)?.disconnect()
            throw error
        }
    }

    /// Pass complete, reassembled envelopes before any legacy message dispatcher.
    public func receive(_ envelope: Data, generation: UUID) {
        guard generation == writer.generation, writer.isConnected else { return }
        do {
            switch try RemoteChannelEnvelope.readHost(envelope) {
            case .frame(let handle, let bytes):
                guard let channel = channels[handle] else { return }
                channel.receive(bytes, from: channel.route)
            case .close(let handle, _):
                guard let route = try? RemoteChannelRoute(linkGeneration: generation, handle: handle) else { return }
                // Remove writer state first: the endpoint's close callback must never answer a peer close.
                writer.peerClosed(route)
                channels.removeValue(forKey: handle)?.disconnect()
            }
        } catch let error as RemoteChannelReadError {
            guard let handle = error.handle, let channel = channels[handle] else { return }
            writer.close(channel.route, reason: error.reason)
            channel.disconnect()
        } catch { }
    }

    public func linkLost() {
        writer.linkLost()
        let previous = Array(channels.values)
        channels.removeAll()
        for channel in previous { channel.linkLost(generation: writer.generation) }
    }
}
