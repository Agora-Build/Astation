import AppKit
import AtemClient
import AstationRemote

@MainActor
final class HostSenderAccessWindowController: NSWindowController, NSWindowDelegate {
    struct Row: Equatable {
        let hostID: String
        let projects: [String]
        let revoked: Bool
        let removed: Bool
        let latestRevokeSeq: UInt64?
    }

    private let hub: AstationHubManager
    private let hosts = NSPopUpButton()
    private let details = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let refresh = NSButton(title: "Refresh", target: nil, action: nil)
    private let revoke = NSButton(title: "Revoke...", target: nil, action: nil)
    private let readmit = NSButton(title: "Readmit...", target: nil, action: nil)
    private let interrupt = NSButton(title: "Interrupt...", target: nil, action: nil)
    private let resume = NSButton(title: "Continue Saved Change...", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel Unsigned Change", target: nil, action: nil)
    private var rows: [Row] = []
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var coordinator: AstationRecoveryCoordinator?
    private var current: (() -> Bool)?
    private var pending: RemoteHostSenderReview?
    private var pendingInterrupt: AstationRecoveryCoordinator.HostInterruptReview?

    init(hub: AstationHubManager) {
        self.hub = hub
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Host Sending Access"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let intro = NSTextField(wrappingLabelWithString:
            "Manage which Atem hosts can send work to other hosts on your account. Previously accepted work can keep running until you revoke the sender or interrupt it.")
        let actions = NSStackView(views: [revoke, readmit, interrupt, refresh])
        actions.spacing = 8
        let savedActions = NSStackView(views: [resume, cancel])
        savedActions.spacing = 8
        let stack = NSStackView(views: [intro, hosts, details, actions, savedActions, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        guard let content = window.contentView else { return }
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
            details.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hosts.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        status.textColor = .secondaryLabelColor
        hosts.target = self; hosts.action = #selector(selectedHost)
        hosts.setAccessibilityLabel("Host sender")
        for (button, action) in [(refresh, #selector(reload)), (revoke, #selector(revokeHost)),
            (readmit, #selector(readmitHost)), (interrupt, #selector(interruptHost)),
            (resume, #selector(resumeChange)), (cancel, #selector(cancelChange))] {
            button.bezelStyle = .rounded; button.target = self; button.action = action
        }
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { task?.cancel() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center(); window?.makeKeyAndOrderFront(sender)
        if let previous = task {
            Task { [weak self] in
                await previous.value
                guard let self, window?.isVisible == true else { return }
                reload()
            }
        } else { reload() }
    }

    func windowWillClose(_ notification: Notification) {
        generation = UUID(); task?.cancel(); current = nil; coordinator = nil
        rows = []; pending = nil; pendingInterrupt = nil; hosts.removeAllItems(); details.stringValue = ""
        render()
    }

    static func senderRows(log: MembershipLog) throws -> [Row] {
        var ids = Set<String>()
        for entry in log.entries() {
            let body = try JSONSerialization.jsonObject(with: Data(signedObjectInfo(json: entry).bodyJcs.utf8)) as? [String: Any]
            if let host = body?["host"] as? [String: Any], let id = host["host_id"] as? String { ids.insert(id) }
        }
        return try ids.sorted().compactMap { id in
            guard let state = log.hostSenderState(hostId: id) else { return nil }
            let revoked: Bool
            switch state { case .authorized: revoked = false; case .revoked: revoked = true }
            return Row(hostID: id, projects: log.hostProjects(hostId: id), revoked: revoked, removed: log.host(hostId: id) == nil,
                latestRevokeSeq: try AstationRecoveryCoordinator.latestHostSenderRevocation(log: log, hostID: id))
        }
    }

    static func explanation(_ review: RemoteHostSenderReview) -> String {
        switch review.operation {
        case .revoke(let interrupt):
            return "Revoke \(review.hostID) as a sender. Queued work from this host is cancelled. " +
                (interrupt ? "Also request interruption of its running tasks. An interruption is not a guarantee that the tasks stopped."
                    : "Tasks already running are not interrupted.")
        case .readmit:
            return "Readmit \(review.hostID) as a sender. Only newly sent work can be accepted. Cancelled tasks do not return."
        }
    }

    static func interruptExplanation(_ review: AstationRecoveryCoordinator.HostInterruptReview) -> String {
        let stations = [review.stationOrigin] + review.additionalStationOrigins
        return "Request interruption of tasks sent by \(review.hostID) before revoke #\(review.body.revokeSeq ?? 0). " +
        "New work accepted after a readmit is unaffected. Delivery through this Station does not confirm that tasks stopped " +
        "or that other Stations received the request.\n\nStations to receive this request:\n" + stations.joined(separator: "\n") + "\nRecord: \(review.recordID)"
    }

    @objc private func reload() {
        guard task == nil else { return }
        generation = UUID()
        let epoch = generation, origin = hub.stationRelayUrl
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; render() }
            do {
                try await hub.prepareAccountSecurityAccess()
                guard let owner = hub.signedInAccount, let issuer = hub.portalSettings?.issuer,
                      generation == epoch, hub.stationRelayUrl == origin else { throw AccountLoginError.changed }
                let accountEpoch = hub.integrationAccountGeneration
                let active: () -> Bool = { [weak self] in
                    guard let self else { return false }
                    return generation == epoch && window?.isVisible == true && hub.integrationAccountGeneration == accountEpoch &&
                        hub.stationRelayUrl == origin && hub.signedInAccount == owner && hub.portalSettings?.issuer == issuer && !hub.accountSignInRequired
                }
                let coordinator = try hub.recoveryCoordinator()
                let log = try await coordinator.hostSenderMembership()
                guard active(), !Task.isCancelled else { throw AccountLoginError.changed }
                self.coordinator = coordinator; current = active
                try populate(log: log, coordinator: coordinator)
                status.stringValue = coordinator.hostSenderControlsAvailable
                    ? "Changes require Touch ID or your Mac password."
                    : "Host sending controls are not enabled for this account."
            } catch { if generation == epoch { status.stringValue = error.localizedDescription } }
        }
        render()
    }

    private func populate(log: MembershipLog, coordinator: AstationRecoveryCoordinator) throws {
        let previous = rows.indices.contains(hosts.indexOfSelectedItem) ? rows[hosts.indexOfSelectedItem].hostID : nil
        pending = try coordinator.pendingHostSenderReview()
        pendingInterrupt = try coordinator.pendingHostInterrupts().first
        rows = try Self.senderRows(log: log)
        hosts.removeAllItems()
        hosts.addItems(withTitles: rows.map { $0.hostID + ($0.revoked ? " - Revoked" : " - Authorized") + ($0.removed ? " (removed)" : "") })
        if let index = rows.firstIndex(where: { $0.hostID == (pending?.hostID ?? pendingInterrupt?.hostID ?? previous) }) { hosts.selectItem(at: index) }
    }

    @objc private func selectedHost() { render() }
    private func render() {
        let row = rows.indices.contains(hosts.indexOfSelectedItem) ? rows[hosts.indexOfSelectedItem] : nil
        details.stringValue = row.map { "Projects: " + ($0.projects.isEmpty ? "None" : $0.projects.joined(separator: ", ")) } ?? "No host senders."
        let ready = task == nil && current?() == true && coordinator?.hostSenderControlsAvailable == true
        let hasSavedChange = pending != nil || pendingInterrupt != nil
        revoke.isEnabled = ready && row?.revoked == false && !hasSavedChange
        readmit.isEnabled = ready && row?.revoked == true && !hasSavedChange
        interrupt.isEnabled = ready && row?.latestRevokeSeq != nil && !hasSavedChange
        resume.isHidden = !hasSavedChange; cancel.isHidden = !hasSavedChange
        resume.isEnabled = ready && hasSavedChange; cancel.isEnabled = ready && hasSavedChange
        hosts.isEnabled = task == nil && !hasSavedChange
        refresh.isEnabled = task == nil
    }

    @objc private func revokeHost() { change(readmitting: false) }
    @objc private func readmitHost() { change(readmitting: true) }

    @objc private func interruptHost() {
        guard rows.indices.contains(hosts.indexOfSelectedItem), let coordinator, let current else { return }
        let hostID = rows[hosts.indexOfSelectedItem].hostID
        runInterrupt { try await coordinator.prepareHostInterrupt(hostID: hostID, current: current) }
    }

    private func change(readmitting: Bool) {
        guard task == nil, rows.indices.contains(hosts.indexOfSelectedItem), let coordinator, let current, current() else { return }
        let row = rows[hosts.indexOfSelectedItem]
        var operation: RemoteHostSenderReview.Operation = .readmit
        if !readmitting {
            let alert = NSAlert()
            alert.messageText = "Revoke \(row.hostID)?"
            alert.informativeText = "Cancel work this host has queued on other hosts. Choose whether to interrupt tasks that already started."
            let interrupt = NSButton(checkboxWithTitle: "Also interrupt the tasks running now", target: nil, action: nil)
            interrupt.state = .off; alert.accessoryView = interrupt
            alert.addButton(withTitle: "Review Revoke"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn, current() else { return }
            operation = .revoke(interruptRunning: interrupt.state == .on)
        }
        let selected = operation
        runChange { try await coordinator.prepareHostSender(hostID: row.hostID, operation: selected, current: current) }
    }

    @objc private func resumeChange() {
        if let pending { runChange { pending } }
        else if let pendingInterrupt { runInterrupt { pendingInterrupt } }
    }

    private func runInterrupt(_ prepare: @escaping () async throws -> AstationRecoveryCoordinator.HostInterruptReview) {
        guard task == nil, let coordinator, let current, current(), NSApp.isActive else { return }
        let epoch = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; render() }
            do {
                let review = try await prepare()
                guard current(), NSApp.isActive, !Task.isCancelled else { throw AccountLoginError.changed }
                pendingInterrupt = review
                let alert = NSAlert()
                alert.messageText = "Interrupt earlier host work?"
                alert.informativeText = Self.interruptExplanation(review)
                alert.addButton(withTitle: "Confirm..."); alert.addButton(withTitle: "Later")
                guard alert.runModal() == .alertFirstButtonReturn, current(), NSApp.isActive else { return }
                status.stringValue = "Confirm with Touch ID or your Mac password..."
                let delivery = try await coordinator.commitHostInterrupt(review, current: { current() && NSApp.isActive })
                guard current(), !Task.isCancelled else { throw AccountLoginError.changed }
                let log = try await coordinator.hostSenderMembership()
                guard current(), !Task.isCancelled else { throw AccountLoginError.changed }
                try populate(log: log, coordinator: coordinator)
                status.stringValue = delivery.allStationsStored
                    ? "Interruption stored at every reviewed Station. Host application is not confirmed."
                    : "Interruption saved. Delivery to some reviewed Stations is pending and will retry; host application is not confirmed."
            } catch {
                if generation == epoch {
                    pendingInterrupt = try? coordinator.pendingHostInterrupts().first
                    status.stringValue = error.localizedDescription
                }
            }
        }
        render()
    }

    private func runChange(_ prepare: @escaping () async throws -> RemoteHostSenderReview) {
        guard task == nil, let coordinator, let current, current(), NSApp.isActive else { return }
        let epoch = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; render() }
            do {
                let review = try await prepare()
                guard current(), NSApp.isActive, !Task.isCancelled else { throw AccountLoginError.changed }
                pending = review
                let alert = NSAlert()
                alert.messageText = "Confirm host sending change"
                alert.informativeText = Self.explanation(review) + "\n\nStation: " + review.stationOrigin
                alert.addButton(withTitle: "Confirm..."); alert.addButton(withTitle: "Later")
                guard alert.runModal() == .alertFirstButtonReturn, current(), NSApp.isActive else { return }
                status.stringValue = "Confirm with Touch ID or your Mac password..."
                try await coordinator.commitHostSender(review, current: { current() && NSApp.isActive })
                guard current(), !Task.isCancelled else { throw AccountLoginError.changed }
                let log = try await coordinator.hostSenderMembership()
                guard current(), !Task.isCancelled else { throw AccountLoginError.changed }
                try populate(log: log, coordinator: coordinator)
                status.stringValue = "Device list updated. Application on the receiving hosts is not yet confirmed."
            } catch {
                if generation == epoch {
                    pending = try? coordinator.pendingHostSenderReview()
                    status.stringValue = error.localizedDescription
                }
            }
        }
        render()
    }

    @objc private func cancelChange() {
        guard task == nil, let coordinator, current?() == true else { return }
        do {
            if let pending {
                try coordinator.cancelUnsignedHostSender(pending)
                self.pending = nil
            } else if let pendingInterrupt {
                try coordinator.cancelUnsignedHostInterrupt(pendingInterrupt)
                self.pendingInterrupt = nil
            }
            status.stringValue = "Unsigned change cancelled."
        } catch { status.stringValue = "A signed or uncertain change must be reconciled before it can be removed." }
        render()
    }
}
