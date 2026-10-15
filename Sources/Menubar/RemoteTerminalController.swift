import Foundation

/// Main-thread protocol state. Rendering and transport are injected so credit,
/// ownership and reconnect behavior can be tested without a window or relay.
final class RemoteTerminalController {
    enum Phase: Equatable {
        case closed, offline, listing, ready, attaching, restoring, viewing, controlling, stopping, exited, failed
    }

    private(set) var phase: Phase = .closed
    private(set) var status = "Choose a terminal to view."
    private(set) var sessions: [RemoteTerminalSession] = []
    private(set) var session: RemoteTerminalSession?
    private(set) var connection: RemoteTerminalConnection?
    private(set) var stream: RemoteTerminalStream?
    private(set) var leaseId: String?
    private(set) var pendingWrites: [UInt64: TimeInterval] = [:]
    private(set) var receivedOffset: UInt64 = 0
    private(set) var acknowledgedOffset: UInt64 = 0
    private(set) var nextSequence: UInt64 = 0
    private(set) var queuedBytes = 0
    var onChange: (() -> Void)?
    var render: ((RemoteTerminalFrame, String) -> Void)?

    var canTakeControl: Bool { phase == .viewing && !wantsControl && session?.exitStatus == nil }
    var canInput: Bool { phase == .controlling && leaseId != nil && wantsControl }
    var canRelease: Bool { wantsControl || leaseId != nil }

    private let currentConnection: () -> RemoteTerminalConnection?
    private let sendMessage: (RemoteTerminalMessage, RemoteTerminalConnection) -> Bool
    private let now: () -> TimeInterval
    private var isOpen = false
    private var preferredTerminalId: String?
    private var listingSince: TimeInterval?
    private var attachSince: TimeInterval?
    private var controlSince: TimeInterval?
    private var stopSince: TimeInterval?
    private var autoView = false
    private var reconnectSession: RemoteTerminalSession?
    private var wantsControl = false
    private var restored = false
    private var receivedFirstFrame = false
    private var transactionOpen = false
    private var transactionBytes = 0
    private var frameSize: (rows: Int, cols: Int)?
    private var frames: [(frame: RemoteTerminalFrame, count: Int)] = []
    private var rendering: (token: String, since: TimeInterval)?
    private var desiredSize: (rows: Int, cols: Int)?
    private var sentSize: (rows: Int, cols: Int)?
    private struct AttachmentRequest {
        let connection: RemoteTerminalConnection
        let sessionId: String
        var cancelled: Bool
    }
    private var attachmentRequests: [AttachmentRequest] = []

    init(currentConnection: @escaping () -> RemoteTerminalConnection?,
         send: @escaping (RemoteTerminalMessage, RemoteTerminalConnection) -> Bool,
         now: @escaping () -> TimeInterval = { Date.timeIntervalSinceReferenceDate }) {
        self.currentConnection = currentConnection
        self.sendMessage = send
        self.now = now
    }

    func open(preferredTerminalId: String?) {
        close()
        self.preferredTerminalId = preferredTerminalId
        isOpen = true
        connectionChanged()
    }

    func close() {
        detach()
        isOpen = false
        connection = nil
        sessions = []
        session = nil
        reconnectSession = nil
        listingSince = nil
        phase = .closed
        changed()
    }

    func connectionChanged() {
        guard isOpen else { return }
        let current = currentConnection()
        guard current != connection || phase == .closed else { return }
        let uncertain = !pendingWrites.isEmpty
        let previous = session ?? reconnectSession
        detach()
        reconnectSession = previous
        connection = current
        sessions = []
        listingSince = nil
        if current == nil {
            phase = .offline
            status = uncertain ? "Disconnected. Some input has an unknown outcome; it will not be resent."
                : "Atem is offline. Reconnect will open in viewing mode."
        } else {
            refresh(autoView: true)
            if uncertain { status = "Reconnecting in viewing mode. Unconfirmed input will not be resent." }
        }
        changed()
    }

    func refresh(autoView: Bool = false) {
        guard isOpen, connection != nil else { connectionChanged(); return }
        self.autoView = autoView
        listingSince = now()
        if stream == nil { phase = .listing; status = "Looking for shared terminals..." }
        if !send(.list) { disconnectedSend() }
        changed()
    }

    func select(_ selected: RemoteTerminalSession) {
        guard sessions.contains(selected), selected != session else { return }
        detach()
        session = selected
        preferredTerminalId = selected.terminalId
        reconnectSession = nil
        phase = .ready
        status = selected.isSupported ? "Choose View to open this terminal." : "This terminal uses an unsupported renderer."
        changed()
    }

    func view() {
        guard let session, session.isSupported, connection != nil, listingSince == nil else { return }
        detach()
        guard attachmentRequests.count < 16, let connection else {
            fail("Too many unanswered attach requests. Reconnect Atem before retrying."); return
        }
        phase = .attaching
        status = "Opening terminal in viewing mode..."
        attachSince = now()
        attachmentRequests.append(AttachmentRequest(connection: connection, sessionId: session.id, cancelled: false))
        if !send(.subscribe(terminalId: session.terminalId, generation: session.generation)) { disconnectedSend() }
        changed()
    }

    func takeControl() {
        guard canTakeControl, let stream else { return }
        wantsControl = true
        controlSince = now()
        status = "Requesting control..."
        if !send(.control(stream, take: true)) { disconnectedSend() }
        changed()
    }

    func release() {
        guard let stream, canRelease else { return }
        wantsControl = false
        leaseId = nil
        controlSince = nil
        sentSize = nil
        phase = .viewing
        status = pendingWrites.isEmpty ? "Viewing. Local typing is available on Atem." : "Viewing. Waiting for outstanding input results."
        if !send(.control(stream, take: false)) { disconnectedSend() }
        changed()
    }

    func input(_ bytes: Data) {
        guard canInput, let stream, let leaseId, !bytes.isEmpty else { return }
        guard bytes.count <= 16 * 1024 else {
            status = "Paste is too large. The limit is 16 KiB; nothing was sent."
            changed()
            return
        }
        guard pendingWrites.count < 64, nextSequence < UInt64.max else {
            fail("Input queue is full. Open a fresh view; unconfirmed input will not be resent.")
            return
        }
        let sequence = nextSequence
        pendingWrites[sequence] = now()
        nextSequence += 1
        if !send(.input(stream, leaseId: leaseId, sequence: sequence, bytes: bytes.base64EncodedString())) {
            disconnectedSend()
        } else {
            status = "Controlling. Waiting for input to reach the terminal..."
        }
        changed()
    }

    func resize(rows: Int, cols: Int) {
        desiredSize = (max(2, min(200, rows)), max(2, min(400, cols)))
        sendResizeIfNeeded()
    }

    func stop() {
        guard canInput, let stream, let leaseId else { return }
        phase = .stopping
        stopSince = now()
        status = "Stopping this agent. Waiting for its final screen..."
        if !send(.stop(stream, leaseId: leaseId)) { disconnectedSend() }
        changed()
    }

    func receive(_ message: RemoteTerminalMessage, from source: RemoteTerminalConnection) {
        if case .attached(let attached, let streamId) = message,
           let index = attachmentRequests.firstIndex(where: { $0.connection == source && $0.sessionId == attached.id }) {
            let request = attachmentRequests.remove(at: index)
            if request.cancelled {
                // Close/selection can race with Attached, before a stream ID exists.
                // Release that late subscription without touching its successor.
                let replaced = attachmentRequests.contains { $0.connection == source && $0.sessionId == attached.id }
                    || (stream?.terminalId == attached.terminalId && stream?.generation == attached.generation)
                if !replaced, source == currentConnection(), !streamId.isEmpty, streamId.utf8.count <= 128 {
                    _ = sendMessage(.unsubscribe(RemoteTerminalStream(terminalId: attached.terminalId,
                        generation: attached.generation, streamId: streamId)), source)
                }
                return
            }
        }
        if case .error(let terminalId, _) = message,
           let index = attachmentRequests.firstIndex(where: { $0.connection == source
               && (terminalId == nil || $0.sessionId.hasPrefix((terminalId ?? "") + ":")) }),
           attachmentRequests[index].cancelled {
            attachmentRequests.remove(at: index)
            return
        }
        guard isOpen, source == connection, source == currentConnection() else { return }
        switch message {
        case .sessions(let available):
            guard listingSince != nil else { return }
            listingSince = nil
            guard available.count <= 64 else { fail("Atem reported too many terminals."); return }
            sessions = available
            if stream != nil { changed(); return }
            let previous = reconnectSession ?? session
            session = available.first(where: { $0.id == previous?.id })
                ?? available.first(where: { $0.terminalId == preferredTerminalId }) ?? available.first
            let shouldView = autoView && (previous == nil || session?.id == previous?.id)
            autoView = false
            reconnectSession = nil
            phase = .ready
            if available.isEmpty {
                status = "No shared terminal. On this host, run atem agent launch claude or codex."
            } else if previous != nil && session?.id != previous?.id {
                status = "The previous process ended or restarted. Choose a terminal and View."
            } else { status = "Choose View to open a terminal." }
            if shouldView { view() }
        case .attached(let attached, let streamId):
            guard phase == .attaching, attached.id == session?.id else { return }
            guard attached.isSupported, !streamId.isEmpty, streamId.utf8.count <= 128 else {
                fail("Atem returned an unsupported terminal session."); return
            }
            session = attached
            stream = RemoteTerminalStream(terminalId: attached.terminalId, generation: attached.generation, streamId: streamId)
            phase = .restoring
            status = "Restoring the current terminal screen..."
            attachSince = now()
        case .frame(let frame):
            guard frame.stream == stream else { return }
            receiveFrame(frame)
        case .controller(let scope, let lease):
            guard scope == stream, restored, phase != .exited else { return }
            controlSince = nil
            if let lease {
                guard !lease.isEmpty, lease.utf8.count <= 128 else { fail("Invalid control lease."); return }
                guard wantsControl else {
                    _ = send(.control(scope, take: false))
                    return
                }
                leaseId = lease
                if phase != .stopping {
                    phase = .controlling
                    status = "Controlling. Keyboard input goes to this agent."
                    sendResizeIfNeeded()
                }
            } else {
                leaseId = nil
                wantsControl = false
                sentSize = nil
                if phase != .stopping {
                    phase = .viewing
                    status = "Viewing. Control was released or reclaimed on Atem."
                }
            }
        case .written(let scope, let sequence, let error):
            guard scope == stream, pendingWrites.removeValue(forKey: sequence) != nil else { return }
            if let error { fail("Input was not confirmed: " + String(error.prefix(240))); return }
            if canInput && pendingWrites.isEmpty { status = "Written to terminal. Waiting for the agent's response." }
        case .exited(let terminalId, let generation, let exitStatus):
            guard terminalId == session?.terminalId, generation == session?.generation, stream != nil else { return }
            session?.exitStatus = exitStatus
            leaseId = nil
            wantsControl = false
            stopSince = nil
            attachSince = nil
            phase = .exited
            status = "Agent exited: " + String(exitStatus.prefix(160))
            if !pendingWrites.isEmpty { status += ". Some input has an unknown outcome." }
            pendingWrites = [:]
        case .error(let terminalId, let message):
            if let index = attachmentRequests.firstIndex(where: { $0.connection == source
                && (terminalId == nil || $0.sessionId.hasPrefix(terminalId! + ":")) }) {
                attachmentRequests.remove(at: index)
            }
            guard terminalId == nil || terminalId == session?.terminalId else { return }
            fail("Atem: " + String(message.prefix(300)))
        case .unsupported:
            fail("This Atem uses an unsupported terminal protocol. Update Astation and Atem together.")
        default: break // Host requests are never interpreted as viewer commands.
        }
        changed()
    }

    func rendererAvailable() { pumpRenderer() }

    func consumed(_ token: String) {
        guard rendering?.token == token, let first = frames.first, let stream else { return }
        rendering = nil
        frames.removeFirst()
        queuedBytes -= first.count
        acknowledgedOffset = first.frame.offset + UInt64(first.count)
        guard send(.ack(stream, offset: acknowledgedOffset)) else { disconnectedSend(); return }
        if !restored && first.frame.complete {
            restored = true
            attachSince = nil
            phase = session?.exitStatus == nil ? .viewing : .exited
            status = phase == .exited ? "Agent exited. Showing its final screen." : "Viewing. Take Control to type in this terminal."
            changed()
        }
        pumpRenderer()
    }

    func rendererFailed() {
        render = nil
        if isOpen { fail("The terminal renderer stopped. Reopen the window to load a fresh view.") }
    }

    func checkTimeouts() {
        let time = now()
        if let since = listingSince, time - since >= 8 {
            listingSince = nil
            if stream == nil {
                phase = .failed
                status = "No terminal response. Check the connection, update Atem, or Refresh."
            } else { status = "The session list did not respond. The current terminal remains open." }
            changed()
        }
        if let since = attachSince, time - since >= 15 { fail("Terminal restore timed out. Choose View to try again.") }
        if let since = rendering?.since, time - since >= 15 { fail("Terminal rendering timed out. Choose View to try again.") }
        if let since = controlSince, time - since >= 8 { fail("Control request timed out. Choose View to reconnect safely.") }
        if let oldest = pendingWrites.values.min(), time - oldest >= 10 {
            fail("Input acknowledgment timed out. Its outcome is unknown; it will not be resent.")
        }
        if let since = stopSince, time - since >= 15 {
            fail("Stop was not confirmed. Refresh the session list to check the process.")
        }
    }

    private func receiveFrame(_ frame: RemoteTerminalFrame) {
        guard frame.offset == receivedOffset, frame.bytes.utf8.count <= 21_848,
              let bytes = Data(base64Encoded: frame.bytes), !bytes.isEmpty, bytes.count <= 16 * 1024,
              (2...200).contains(frame.rows), (2...400).contains(frame.cols) else {
            fail("Invalid or missing terminal frame. Choose View to restore a fresh screen."); return
        }
        if !receivedFirstFrame && !frame.reset { fail("The terminal restore is missing its initial snapshot."); return }
        if frame.reset {
            guard !transactionOpen else { fail("Terminal reset interrupted a screen transaction."); return }
            frameSize = (frame.rows, frame.cols)
        }
        guard frameSize?.rows == frame.rows, frameSize?.cols == frame.cols else {
            fail("Terminal dimensions changed without a reset."); return
        }
        if !transactionOpen { transactionBytes = 0 }
        transactionBytes += bytes.count
        let (end, overflow) = receivedOffset.addingReportingOverflow(UInt64(bytes.count))
        guard !overflow, transactionBytes <= 1024 * 1024, queuedBytes + bytes.count <= 128 * 1024,
              frames.count < 128 else { fail("Terminal frame limits were exceeded. Choose View to reconnect."); return }
        receivedFirstFrame = true
        transactionOpen = !frame.complete
        receivedOffset = end
        queuedBytes += bytes.count
        frames.append((frame, bytes.count))
        pumpRenderer()
    }

    private func pumpRenderer() {
        guard rendering == nil, let frame = frames.first?.frame, let render else { return }
        let token = UUID().uuidString
        rendering = (token, now())
        render(frame, token)
    }

    private func sendResizeIfNeeded() {
        guard canInput, let stream, let leaseId, let size = desiredSize,
              sentSize?.rows != size.rows || sentSize?.cols != size.cols else { return }
        sentSize = size
        if !send(.resize(stream, leaseId: leaseId, rows: size.rows, cols: size.cols)) { disconnectedSend() }
    }

    private func send(_ message: RemoteTerminalMessage) -> Bool {
        guard let connection, connection == currentConnection() else { return false }
        return sendMessage(message, connection)
    }

    private func detach() {
        if let stream { _ = send(.unsubscribe(stream)) }
        if stream == nil, attachSince != nil, let connection, let session,
           let index = attachmentRequests.lastIndex(where: { $0.connection == connection && $0.sessionId == session.id }) {
            attachmentRequests[index].cancelled = true
        }
        attachmentRequests.removeAll { $0.connection != currentConnection() }
        stream = nil
        leaseId = nil
        wantsControl = false
        restored = false
        receivedFirstFrame = false
        transactionOpen = false
        transactionBytes = 0
        frameSize = nil
        receivedOffset = 0
        acknowledgedOffset = 0
        nextSequence = 0
        pendingWrites = [:]
        frames = []
        queuedBytes = 0
        rendering = nil
        sentSize = nil
        attachSince = nil
        controlSince = nil
        stopSince = nil
    }

    private func fail(_ message: String) {
        let uncertain = !pendingWrites.isEmpty
        detach()
        listingSince = nil
        phase = .failed
        status = message
        if uncertain && !message.contains("unknown") { status += " Unconfirmed input will not be resent." }
        changed()
    }

    private func disconnectedSend() {
        if currentConnection() != connection { connectionChanged() }
        else { fail("The terminal connection could not send. Reopen a view; unconfirmed input will not be resent.") }
    }

    private func changed() { onChange?() }
}
