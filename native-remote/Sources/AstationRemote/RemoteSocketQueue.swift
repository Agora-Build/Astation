import Foundation

/// Ordered, bounded writes. A failed write ends the connection; ciphertext is never replayed.
@MainActor
public final class RemoteSocketQueue {
    private var frames: [Data] = []
    private var bytes = 0
    private var writing = false
    private var connected = true
    private var accepting = true
    private var drainOwner: RemoteSocketQueue?
    private let write: (Data, @escaping (Error?) -> Void) -> Void
    private let failed: (Error) -> Void

    public init(write: @escaping (Data, @escaping (Error?) -> Void) -> Void, failed: @escaping (Error) -> Void) {
        self.write = write
        self.failed = failed
    }

    public func enqueue(_ frame: Data) throws {
        guard connected, accepting else { throw RemoteChannelError.staleLink }
        guard frames.count < 64, frame.count <= RemoteChannelEnvelope.maximumBytes + 1024,
              bytes + frame.count <= 4 * 1024 * 1024 else { throw RemoteChannelWriteError.busy }
        frames.append(frame); bytes += frame.count
        flush()
    }

    public func disconnect() { connected = false; accepting = false; frames = []; bytes = 0; drainOwner = nil }

    /// Discard writes not yet handed to the socket, then close only this channel in order.
    public func finish(with close: Data) {
        guard connected, accepting else { return }
        accepting = false
        frames = writing ? Array(frames.prefix(1)) : []
        frames.append(close)
        bytes = frames.reduce(0) { $0 + $1.count }
        retainWhileDraining()
    }

    public func drain() {
        guard connected, accepting else { return }
        accepting = false
        if frames.isEmpty { disconnect(); return }
        retainWhileDraining()
    }

    private func retainWhileDraining() {
        drainOwner = self
        flush()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.disconnect()
        }
    }

    private func flush() {
        guard connected, !writing, let frame = frames.first else { return }
        writing = true
        write(frame) { [weak self] error in
            Task { @MainActor in
                guard let self, self.connected else { return }
                self.writing = false
                if let error { self.disconnect(); self.failed(error); return }
                self.frames.removeFirst(); self.bytes -= frame.count
                if self.frames.isEmpty && !self.accepting { self.disconnect(); return }
                self.flush()
            }
        }
    }
}
