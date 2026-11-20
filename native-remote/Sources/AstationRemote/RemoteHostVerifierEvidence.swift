import AtemClient

/// One channel owns this evidence; disposing it also retires its gate connection.
final class RemoteHostVerifierEvidence {
    private let gate: RemoteVerifierSigningGate
    private let hostID: String
    private var connection: RemoteVerifierSigningGate.Connection?
    private var confirmedHead: LogHead?

    init(gate: RemoteVerifierSigningGate, hostID: String) {
        self.gate = gate
        self.hostID = hostID
    }

    deinit { disconnect() }

    func start() throws {
        connection = try gate.connect(.host(hostID))
    }

    func welcome(_ welcome: WelcomeInfo) {
        guard let connection else { return }
        do {
            try gate.observeHostWelcome(welcome, on: connection)
            confirmedHead = welcome.head
        }
        catch { disconnect() }
    }

    func membershipHead(_ head: LogHead) {
        if head != confirmedHead { disconnect() }
    }

    func disconnect() {
        guard let connection else { return }
        gate.disconnect(connection)
        self.connection = nil
        confirmedHead = nil
    }
}
