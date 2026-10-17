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
    var sessionClient: AtemSessionClient?

    private var protocolTarget: AtemSessionTarget? {
        guard let session else { return nil }
        return sessionClient?.target(sessionId: session.terminalId, process: session.generation)
    }

    var canTakeControl: Bool {
        if let client = sessionClient {
            return client.welcome?.permissions?.contains("control") == true
                && phase == .viewing && !wantsControl && session?.exitStatus == nil
                && protocolTarget.map { client.registry[$0.session_id]?.state == "running" && !client.acquiring($0) } == true
        }
        return phase == .viewing && !wantsControl && session?.exitStatus == nil && session?.supportsExpiringControl == true
    }
    var canInput: Bool {
        if let client = sessionClient {
            return phase == .controlling && stream != nil && restored && protocolTarget.map(client.controls) == true
        }
        return phase == .controlling && leaseId != nil && wantsControl && leaseConfirmedAt.map { now() - $0 < 15 } == true
    }
    var canRelease: Bool { wantsControl || leaseId != nil }

    private let currentConnection: () -> RemoteTerminalConnection?
    private let sendMessage: (RemoteTerminalMessage, RemoteTerminalConnection) -> Bool
    private let now: () -> TimeInterval
    private var isOpen = false
    private var preferredTerminalId: String?
    private var preferredAgentId: String?
    private var listingSince: TimeInterval?
    private var attachSince: TimeInterval?
    private var controlSince: TimeInterval?
    private var stopSince: TimeInterval?
    private var autoView = false
    private var reconnectSession: RemoteTerminalSession?
    private var wantsControl = false
    private var leaseConfirmedAt: TimeInterval?
    private var renewalSince: TimeInterval?
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
    private var sessionAttachment: String?

    init(currentConnection: @escaping () -> RemoteTerminalConnection?,
         send: @escaping (RemoteTerminalMessage, RemoteTerminalConnection) -> Bool,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.currentConnection = currentConnection
        self.sendMessage = send
        self.now = now
    }

    func open(preferredTerminalId: String?, preferredAgentId: String? = nil) {
        close()
        self.preferredTerminalId = preferredTerminalId
        self.preferredAgentId = preferredAgentId
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
        if let client = sessionClient {
            if !client.hasRegistrySnapshot { client.refresh() }
            sessionStateChanged()
            changed()
            return
        }
        if !send(.list) { disconnectedSend() }
        changed()
    }

    func select(_ selected: RemoteTerminalSession) {
        guard sessions.contains(selected), selected.id != session?.id else { return }
        detach()
        session = selected
        preferredTerminalId = selected.terminalId
        preferredAgentId = selected.agentId
        reconnectSession = nil
        autoView = listingSince != nil && selected.isSupported
        phase = .ready
        status = selected.isSupported ? "Opening the selected terminal..." : "This terminal uses an unsupported renderer."
        changed()
        view()
    }

    func view() {
        guard let session, session.isSupported, connection != nil, listingSince == nil else { return }
        guard sessionClient == nil || protocolTarget != nil else {
            status = sessionClient?.status ?? "Waiting for the session registry."
            autoView = true
            changed()
            return
        }
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
        if let client = sessionClient, let target = protocolTarget {
            wantsControl = true
            client.acquire(target)
            sessionStateChanged()
            return
        }
        wantsControl = true
        controlSince = now()
        status = "Requesting control..."
        if !send(.control(stream, take: true)) { disconnectedSend() }
        changed()
    }

    func release() {
        guard let stream, canRelease else { return }
        if let client = sessionClient, let target = protocolTarget {
            wantsControl = false
            leaseId = nil
            phase = .viewing
            client.release(target)
            sessionStateChanged()
            return
        }
        wantsControl = false
        leaseId = nil
        leaseConfirmedAt = nil
        renewalSince = nil
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
        guard pendingWrites.count < 64, nextSequence < (sessionClient == nil ? UInt64.max : AtemSessionWire.maximumCounter) else {
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

    @discardableResult
    func sendScopedInput(kind: String, value: String) -> Bool {
        guard canInput else { return false }
        if let client = sessionClient, let target = protocolTarget {
            if kind == "text" {
                guard !value.isEmpty else { return false }
                return client.submit(target, kind: "prompt", text: value) != nil
            }
            if kind == "key", value == "ctrl-c" { return client.submit(target, kind: "interrupt") != nil }
        }
        let bytes: Data
        if kind == "text" {
            guard !value.isEmpty, value.utf8.count < 16 * 1024 else { return false }
            bytes = Data((value + "\r").utf8)
        } else if kind == "key" {
            let keys = ["enter": "\r", "esc": "\u{1b}", "ctrl-c": "\u{3}",
                        "up": "\u{1b}[A", "down": "\u{1b}[B", "y": "y", "n": "n"]
            guard let key = keys[value] else { return false }
            bytes = Data(key.utf8)
        } else { return false }
        let before = nextSequence
        input(bytes)
        return nextSequence > before && canInput
    }

    func resize(rows: Int, cols: Int) {
        desiredSize = (max(2, min(200, rows)), max(2, min(400, cols)))
        sendResizeIfNeeded()
    }

    func stop() {
        guard canInput, let stream, let leaseId else { return }
        if let client = sessionClient, let target = protocolTarget {
            guard client.submit(target, kind: "stop") != nil else { return }
            phase = .stopping
            stopSince = now()
            status = "Stopping this agent. Waiting for its durable receipt..."
            changed()
            return
        }
        phase = .stopping
        stopSince = now()
        status = "Stopping this agent. Waiting for its final screen..."
        if !send(.stop(stream, leaseId: leaseId)) { disconnectedSend() }
        changed()
    }

    func receive(_ message: RemoteTerminalMessage, from source: RemoteTerminalConnection) {
        if case .bound(let inner, let binding) = message {
            guard source == connection, binding.attachment_gen == sessionClient?.welcome?.attachment_gen,
                  binding.target == protocolTarget else { return }
            receivePayload(inner, from: source)
            return
        }
        if sessionClient != nil {
            switch message {
            // r6.2 host events carry no binding. The authenticated connection,
            // outstanding subscribe and exact process/stream fence delivery.
            case .attached, .frame, .written, .exited, .error, .unsupported: break
            default: return
            }
        }
        receivePayload(message, from: source)
    }

    private func receivePayload(_ message: RemoteTerminalMessage, from source: RemoteTerminalConnection) {
        if case .attached(let attached, let streamId) = message,
           let index = attachmentRequests.firstIndex(where: { $0.connection == source && $0.sessionId == attached.id }) {
            let request = attachmentRequests.remove(at: index)
            if request.cancelled {
                // Close/selection can race with Attached, before a stream ID exists.
                // Release that late subscription without touching its successor.
                let replaced = attachmentRequests.contains { $0.connection == source && $0.sessionId == attached.id }
                    || (stream?.terminalId == attached.terminalId && stream?.generation == attached.generation)
                if !replaced, source == currentConnection(), !streamId.isEmpty, streamId.utf8.count <= 128 {
                    let unsubscribe = RemoteTerminalMessage.unsubscribe(RemoteTerminalStream(terminalId: attached.terminalId,
                        generation: attached.generation, streamId: streamId))
                    if let client = sessionClient {
                        if let target = client.target(sessionId: attached.terminalId, process: attached.generation),
                           let binding = client.binding(for: target, mutation: false) {
                            _ = sendMessage(.bound(unsubscribe, binding), source)
                        }
                    } else { _ = sendMessage(unsubscribe, source) }
                }
                return
            }
        }
        if case .error(let terminalId, let errorStream, _, _) = message,
           errorStream == nil,
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
            guard available.count <= (sessionClient == nil ? 64 : 1024) else { fail("Atem reported too many terminals."); return }
            sessions = available
            if stream != nil { changed(); return }
            let previous = reconnectSession ?? session
            let preferred: RemoteTerminalSession?
            if let preferredAgentId {
                preferred = available.first(where: { $0.agentId == preferredAgentId })
            } else if let preferredTerminalId {
                preferred = available.first(where: { $0.terminalId == preferredTerminalId })
            } else { preferred = available.first }
            session = available.first(where: { $0.id == previous?.id }) ?? preferred
            let shouldView = autoView && (previous == nil || session?.id == previous?.id)
            autoView = false
            reconnectSession = nil
            phase = .ready
            if available.isEmpty {
                status = "No shared terminal. On this host, run atem agent launch claude or codex."
            } else if session == nil {
                status = "This agent's original terminal was not reported. Select a terminal explicitly."
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
            guard sessionClient == nil else { return }
            guard scope == stream, restored, phase != .exited else { return }
            if let lease {
                guard !lease.isEmpty, lease.utf8.count <= 128 else { fail("Invalid control lease."); return }
                guard wantsControl else {
                    _ = send(.control(scope, take: false))
                    return
                }
                if let confirmed = leaseConfirmedAt, now() - confirmed >= 15 {
                    release()
                    status = "Control expired before renewal was confirmed. Take Control to type again."
                    break
                }
                guard session?.supportsExpiringControl == true,
                      leaseId == nil || leaseId == lease else {
                    fail("The terminal control lease changed unexpectedly. Take Control again from a fresh view.")
                    return
                }
                // Only an outstanding acquire/renew may extend the local deadline.
                if let since = renewalSince ?? controlSince {
                    leaseConfirmedAt = since
                    renewalSince = nil
                    controlSince = nil
                }
                guard leaseConfirmedAt.map({ now() - $0 < 15 }) == true else {
                    release()
                    status = "Control confirmation arrived too late. Take Control again."
                    break
                }
                leaseId = lease
                if phase != .stopping {
                    phase = .controlling
                    status = "Controlling. Keyboard input goes to this agent."
                    sendResizeIfNeeded()
                }
            } else {
                leaseId = nil
                leaseConfirmedAt = nil
                renewalSince = nil
                controlSince = nil
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
            leaseConfirmedAt = nil
            renewalSince = nil
            wantsControl = false
            stopSince = nil
            attachSince = nil
            phase = .exited
            status = "Agent exited: " + String(exitStatus.prefix(160))
            if !pendingWrites.isEmpty { status += ". Some input has an unknown outcome." }
            pendingWrites = [:]
        case .error(let terminalId, let errorStream, let code, let message):
            guard errorStream == nil || errorStream == stream?.streamId else { return }
            if let index = attachmentRequests.firstIndex(where: { $0.connection == source
                && (terminalId == nil || $0.sessionId.hasPrefix(terminalId! + ":")) }) {
                attachmentRequests.remove(at: index)
            }
            guard terminalId == nil || terminalId == session?.terminalId else { return }
            if let client = sessionClient {
                // A registry refresh disables target(), but a refusal must
                // still fence the selected process's cached lease.
                let target = session.flatMap { session -> AtemSessionTarget? in
                    guard let context = client.context, let trust = client.welcome?.host_trust_gen else { return nil }
                    return AtemSessionTarget(account_id: context.account, atem_device_id: context.device,
                        host_trust_gen: trust, session_id: session.terminalId, process_gen: session.generation)
                }
                client.handleRefusal(code: code, target: target)
            }
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
            status = phase == .exited ? "Agent exited. Showing its final screen."
                : sessionClient != nil || session?.supportsExpiringControl == true ? "Viewing. Take Control to type in this terminal."
                : "Viewing. Update Atem to enable control with expiring session leases."
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
        if sessionClient == nil, let confirmed = leaseConfirmedAt, time - confirmed >= 15 {
            release()
            status = "Control expired. Viewing continues; Take Control to type again."
            changed()
        } else if sessionClient == nil, phase == .controlling, wantsControl, renewalSince == nil,
                  let confirmed = leaseConfirmedAt, time - confirmed >= 5,
                  let stream, let leaseId {
            renewalSince = time
            if !send(.renew(stream, leaseId: leaseId)) { disconnectedSend() }
        }
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
        guard !overflow, sessionClient == nil || end <= AtemSessionWire.maximumCounter,
              transactionBytes <= 1024 * 1024, queuedBytes + bytes.count <= 128 * 1024,
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
        if let client = sessionClient {
            guard client.phase == .ready else { return false }
            let terminalId: String
            let generation: String
            let mutation: Bool
            switch message {
            case .subscribe(let id, let process): terminalId = id; generation = process; mutation = false
            case .unsubscribe(let stream), .ack(let stream, _): terminalId = stream.terminalId; generation = stream.generation; mutation = false
            case .input(let stream, _, _, _), .resize(let stream, _, _, _), .stop(let stream, _):
                terminalId = stream.terminalId; generation = stream.generation; mutation = true
            default: return false
            }
            guard let target = client.target(sessionId: terminalId, process: generation),
                  let binding = client.binding(for: target, mutation: mutation) else { return false }
            return sendMessage(.bound(message, binding), connection)
        }
        return sendMessage(message, connection)
    }

    func sessionStateChanged() {
        guard isOpen, let client = sessionClient else { return }
        if sessionAttachment != client.welcome?.attachment_gen {
            sessionAttachment = client.welcome?.attachment_gen
            let previous = session ?? reconnectSession
            detach()
            attachmentRequests = []
            sessions = []
            session = nil
            reconnectSession = previous
            listingSince = now()
            autoView = true
            phase = .listing
        }
        guard client.hasRegistrySnapshot else {
            if client.phase == .failed { fail(client.status) }
            else { status = client.status; changed() }
            return
        }
        let available = client.registry.values.filter { $0.capabilities.contains("terminal-v1") }
            .sorted { $0.session_id < $1.session_id }.map { descriptor in
                RemoteTerminalSession(terminalId: descriptor.session_id, generation: descriptor.process_gen,
                    provider: descriptor.provider, rows: 24, cols: 80,
                    exitStatus: descriptor.state == "exited" || descriptor.state == "closed" ? descriptor.state : nil,
                    rendering: "vt100-screen-diff", widthProfile: "atem-unicode-width-0.1.14",
                    capabilities: descriptor.capabilities, agentId: descriptor.session_id, label: descriptor.cwd_label)
            }
        if listingSince != nil || available != sessions {
            if let session, !available.contains(where: { $0.id == session.id }), stream != nil {
                detach()
                self.session = nil
                phase = .ready
            }
            listingSince = listingSince ?? now()
            guard let source = connection else { return }
            receivePayload(.sessions(available), from: source)
        }
        if phase == .ready, autoView, protocolTarget != nil {
            autoView = false
            view()
            return
        }
        if let target = protocolTarget, let binding = client.binding(for: target, mutation: true),
           restored, stream != nil, phase != .stopping {
            leaseId = binding.attachment_gen + ":" + String(binding.lease_epoch!)
            wantsControl = true
            phase = .controlling
            status = client.status
            sendResizeIfNeeded()
        } else if restored, phase != .exited, phase != .stopping {
            leaseId = nil
            wantsControl = protocolTarget.map(client.acquiring) == true
            phase = .viewing
            status = client.status
        }
        changed()
    }

    private func detach() {
        if let client = sessionClient, let target = protocolTarget, client.controls(target) || client.acquiring(target) { client.release(target) }
        if let stream { _ = send(.unsubscribe(stream)) }
        if stream == nil, attachSince != nil, let connection, let session,
           let index = attachmentRequests.lastIndex(where: { $0.connection == connection && $0.sessionId == session.id }) {
            attachmentRequests[index].cancelled = true
        }
        attachmentRequests.removeAll { $0.connection != currentConnection() }
        stream = nil
        leaseId = nil
        leaseConfirmedAt = nil
        renewalSince = nil
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
