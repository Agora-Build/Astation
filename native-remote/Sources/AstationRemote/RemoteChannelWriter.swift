import Foundation

public enum RemoteChannelTransport: String, Sendable {
    case relay, direct
}

public enum RemoteChannelWriteError: Error, Equatable {
    case tooLarge
    case malformedFrame
    case busy
}

public enum RemoteChannelCloseReason: String, Sendable {
    case closed, busy, malformed, expired
    case unknownChannel = "unknown_channel"
    case tooLarge = "too_large"
    case handshakeFailed = "handshake_failed"
}

/// Outbound R9.7a envelopes. Inner frames come from the shared core and retain their original bytes.
public enum RemoteChannelEnvelope {
    public static let maximumBytes = 2_097_152

    public static func open(route: RemoteChannelRoute, transport: RemoteChannelTransport) -> Data {
        Data("{\"type\":\"channel\",\"event\":\"open\",\"channel\":\"\(route.handle)\",\"transport\":\"\(transport.rawValue)\"}".utf8)
    }

    public static func frame(_ frame: Data, route: RemoteChannelRoute) throws -> Data {
        let prefix = Data("{\"type\":\"channel\",\"event\":\"frame\",\"channel\":\"\(route.handle)\",\"frame\":".utf8)
        guard frame.count <= maximumBytes - prefix.count - 1 else { throw RemoteChannelWriteError.tooLarge }
        // Foundation checks framing only. Never re-encode a signed frame through its numeric representation.
        guard String(data: frame, encoding: .utf8) != nil,
              (try? JSONSerialization.jsonObject(with: frame)) is [String: Any] else {
            throw RemoteChannelWriteError.malformedFrame
        }
        var result = prefix
        result.append(frame)
        result.append(125)
        return result
    }

    public static func close(route: RemoteChannelRoute, reason: RemoteChannelCloseReason = .closed) -> Data {
        Data("{\"type\":\"channel\",\"event\":\"close\",\"channel\":\"\(route.handle)\",\"reason\":\"\(reason.rawValue)\"}".utf8)
    }
}

/// One writer per authenticated host link. The sink accepts synchronously into a bounded transport queue,
/// throwing before acceptance when full. Call flush when that queue becomes writable again.
/// Socket loss must also be delivered to each RemoteAgentChannel; this writer owns no cryptographic authority.
@MainActor
public final class RemoteChannelWriter {
    public let generation: UUID
    public let transport: RemoteChannelTransport
    public private(set) var isConnected = true
    public var count: Int { channels.count }
    public var pendingCloseCount: Int { pendingCloses.count }
    private let write: (Data) throws -> Void
    private var channels: [String: Bool] = [:]
    private var pendingCloses: [(route: RemoteChannelRoute, frame: Data)] = []
    private var isFlushing = false
    private var nextHandle: UInt64 = 0

    public init(generation: UUID, transport: RemoteChannelTransport, write: @escaping (Data) throws -> Void) {
        self.generation = generation
        self.transport = transport
        self.write = write
    }

    public func open() throws -> RemoteChannelRoute {
        guard isConnected else { throw RemoteChannelError.staleLink }
        flush()
        guard isConnected else { throw RemoteChannelError.staleLink }
        guard pendingCloses.isEmpty, channels.count + pendingCloses.count < 64,
              channels.values.filter({ !$0 }).count < 16,
              nextHandle < UInt64.max else { throw RemoteChannelWriteError.busy }
        nextHandle += 1
        let route = try RemoteChannelRoute(linkGeneration: generation, handle: "native_\(nextHandle)")
        channels[route.handle] = false
        do {
            try write(RemoteChannelEnvelope.open(route: route, transport: transport))
            guard contains(route) else { throw RemoteChannelError.staleLink }
            return route
        } catch {
            close(route, reason: .busy)
            throw error
        }
    }

    public func welcomed(_ route: RemoteChannelRoute) throws {
        guard contains(route) else { throw RemoteChannelError.staleLink }
        channels[route.handle] = true
    }

    public func send(_ frame: Data, to route: RemoteChannelRoute) throws {
        guard contains(route) else { throw RemoteChannelError.staleLink }
        do {
            flush()
            guard contains(route) else { throw RemoteChannelError.staleLink }
            guard pendingCloses.isEmpty else { throw RemoteChannelWriteError.busy }
            try write(RemoteChannelEnvelope.frame(frame, route: route))
            guard contains(route) else { throw RemoteChannelError.staleLink }
        } catch {
            let reason: RemoteChannelCloseReason
            switch error as? RemoteChannelWriteError {
            case .tooLarge: reason = .tooLarge
            case .malformedFrame: reason = .malformed
            default: reason = .busy
            }
            close(route, reason: reason)
            throw error
        }
    }

    public func contains(_ route: RemoteChannelRoute) -> Bool {
        isConnected && route.linkGeneration == generation && channels[route.handle] != nil
    }

    /// Remove before writing so reentrant closure callbacks cannot send a second close.
    public func close(_ route: RemoteChannelRoute, reason: RemoteChannelCloseReason = .closed) {
        guard contains(route) else { return }
        channels.removeValue(forKey: route.handle)
        // A pending close retains its slot until accepted. It can never exceed the 64-channel bound.
        let message = RemoteChannelEnvelope.close(route: route, reason: reason)
        pendingCloses.append((route, message))
        flush()
    }

    public func flush() {
        guard isConnected, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }
        while isConnected, let next = pendingCloses.first {
            do { try write(next.frame) } catch { return }
            pendingCloses.removeAll { $0.route == next.route }
        }
    }

    /// A host close is never answered, including a duplicate or unknown close.
    public func peerClosed(_ route: RemoteChannelRoute) {
        guard isConnected, route.linkGeneration == generation else { return }
        channels.removeValue(forKey: route.handle)
        pendingCloses.removeAll { $0.route == route }
    }

    public func linkLost() {
        isConnected = false
        channels.removeAll()
        pendingCloses.removeAll()
    }
}
