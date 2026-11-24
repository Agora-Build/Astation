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
    private let servers = NSButton(title: "Review Station Servers...", target: nil, action: nil)
    private let processes = NSButton(title: "Review Member Processes...", target: nil, action: nil)
    private let revoke = NSButton(title: "Revoke...", target: nil, action: nil)
    private let readmit = NSButton(title: "Readmit...", target: nil, action: nil)
    private let interrupt = NSButton(title: "Interrupt...", target: nil, action: nil)
    private let resume = NSButton(title: "Continue Saved Change...", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel Unsigned Change", target: nil, action: nil)
    private var rows: [Row] = []
    private var verifierMembers: [String] = []
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var coordinator: AstationRecoveryCoordinator?
    private var current: (() -> Bool)?
    private var pending: RemoteHostSenderReview?
    private var pendingInterrupt: AstationRecoveryCoordinator.HostInterruptReview?

    init(hub: AstationHubManager) {
        self.hub = hub
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 470),
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
        let stack = NSStackView(views: [intro, hosts, details, actions, savedActions,
            NSStackView(views: [servers, processes]), status])
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
        for (button, action) in [(refresh, #selector(reload)), (servers, #selector(reviewServers)),
            (processes, #selector(reviewProcesses)), (revoke, #selector(revokeHost)),
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
        verifierMembers = log.members().filter { $0.status == .active && ["native", "service"].contains($0.kind) }
            .map(\.deviceId).sorted()
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
        servers.isEnabled = task == nil && current?() == true && coordinator?.verifierRosterReviewAvailable == true
        processes.isEnabled = task == nil && current?() == true && coordinator?.processReviewAvailable == true && !verifierMembers.isEmpty
    }

    static func serverReviewText(_ review: AstationRecoveryCoordinator.VerifierRosterReview) -> String {
        var text = "Station: \(review.candidate.origin)\nServer list revision: \(review.candidate.generation)\n\nServers to check:\n"
        text += review.candidate.replicas.joined(separator: "\n")
        if !review.removed.isEmpty { text += "\n\nServers removed from the current list:\n" + review.removed.joined(separator: "\n") }
        return text
    }

    @objc private func reviewServers() {
        guard task == nil, let coordinator, let current, current(), NSApp.isActive else { return }
        let epoch = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; render() }
            do {
                let review = try await coordinator.prepareStationVerifierRoster(current: current)
                guard current(), NSApp.isActive, !Task.isCancelled else { throw AccountLoginError.changed }
                let alert = NSAlert()
                alert.messageText = "Review this Station's servers"
                alert.informativeText = "All listed servers must confirm support before new permissions can be signed. Saving this list does not enable permissions or verify the servers."
                if !review.removed.isEmpty {
                    alert.alertStyle = .warning
                    alert.informativeText += " Removed servers will no longer be checked. Confirm they no longer serve this Station."
                }
                let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 470, height: 200))
                text.isEditable = false; text.isSelectable = true
                text.font = .systemFont(ofSize: 12); text.string = Self.serverReviewText(review)
                let scroll = NSScrollView(frame: text.frame)
                scroll.hasVerticalScroller = true; scroll.documentView = text
                alert.accessoryView = scroll
                alert.addButton(withTitle: "Confirm Server List..."); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn, current(), NSApp.isActive, !Task.isCancelled else { return }
                try await coordinator.acceptStationVerifierRoster(review, current: current)
                guard current(), generation == epoch else { return }
                status.stringValue = "Station server list saved. Live support checks are still required."
            } catch { if generation == epoch { status.stringValue = error.localizedDescription } }
        }
        render()
    }

    private func processEditor(_ text: String, editable: Bool) -> (NSScrollView, NSTextView) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 490, height: 160))
        let view = NSTextView(frame: scroll.bounds)
        view.isRichText = false; view.isEditable = editable
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.string = text
        scroll.hasVerticalScroller = true; scroll.documentView = view
        return (scroll, view)
    }

    @objc private func reviewProcesses() {
        guard task == nil, let coordinator, let current, current(), NSApp.isActive else { return }
        let pick = NSAlert()
        pick.messageText = "Choose a verifier member"
        pick.informativeText = "Review the processes using this device or integration's signing key."
        let members = NSPopUpButton()
        do {
            let reviews = try coordinator.memberProcessReviews()
            var firstPending: Int?
            for (index, review) in reviews.enumerated() {
                let detail: String
                switch review.status {
                case .needsReview: detail = "Needs review"
                case .previousRevision: detail = "Device list changed"
                case .expiredService: detail = "Service expired"
                case .reviewed(let slots): detail = slots == 1 ? "1 reviewed slot" : "\(slots) reviewed slots"
                }
                members.addItem(withTitle: review.member + " (" + detail + ")")
                members.lastItem?.representedObject = review.member
                if firstPending == nil && (review.status == .needsReview || review.status == .previousRevision) {
                    firstPending = index
                }
            }
            guard !reviews.isEmpty else { return }
            members.selectItem(at: firstPending ?? reviews.firstIndex(where: { $0.member == coordinator.managerID }) ?? 0)
        } catch { status.stringValue = error.localizedDescription; return }
        pick.accessoryView = members
        pick.addButton(withTitle: "Continue"); pick.addButton(withTitle: "Cancel")
        guard pick.runModal() == .alertFirstButtonReturn,
              let member = members.selectedItem?.representedObject as? String, current() else { return }
        let epoch = generation
        let active = { current() && NSApp.isActive && !Task.isCancelled }
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; render() }
            do {
                let review = try await coordinator.prepareProcessReview(member: member, current: active)
                guard active() else { throw AccountLoginError.changed }
                let edit = NSAlert()
                edit.messageText = "Processes for " + member
                edit.informativeText = "Include every SDK process using this key, even offline ones. Enter its configured slot name and SDK process ID on each line, separated by a space."
                if member == coordinator.managerID {
                    edit.informativeText += "\n\nThis Mac's SDK process ID is " + verifierReportProcess()
                }
                let (scroll, text) = processEditor(review.previous?.lines.joined(separator: "\n") ?? "", editable: true)
                edit.accessoryView = scroll
                edit.window.initialFirstResponder = text
                edit.addButton(withTitle: "Review List"); edit.addButton(withTitle: "Cancel")
                var lines: [String]
                while true {
                    guard edit.runModal() == .alertFirstButtonReturn, active() else { return }
                    do {
                        lines = try AstationProcessRoster.rows(member: member, text: text.string).map { $0.slot + " " + $0.process }
                        break
                    } catch {
                        edit.messageText = "Check the process list"
                        edit.informativeText = "Enter one unique slot and its 22-character SDK process ID on each line. Include at least one process."
                    }
                }
                let selected = Set(lines)
                let removed = (review.previous?.lines ?? []).filter { !selected.contains($0) }
                let confirm = NSAlert()
                confirm.messageText = "Confirm processes for " + member
                confirm.informativeText = "Station: " + review.origin + "\nDevice list revision: " + String(review.head.seq) +
                    "\nConfirm that this list includes every SDK process using this key. Each still needs a fresh signed report."
                var summary = lines.joined(separator: "\n")
                if !removed.isEmpty {
                    confirm.alertStyle = .warning
                    summary += "\n\nRemoved from the previous review:\n" + removed.joined(separator: "\n")
                }
                confirm.accessoryView = processEditor(summary, editable: false).0
                confirm.addButton(withTitle: "Confirm with Mac..."); confirm.addButton(withTitle: "Cancel")
                guard confirm.runModal() == .alertFirstButtonReturn, active() else { return }
                try await coordinator.acceptProcessReview(review, lines: lines, current: active)
                if current() { status.stringValue = "Process list saved for " + member + "." }
            } catch { if generation == epoch { status.stringValue = error.localizedDescription } }
        }
        render()
    }

    @objc private func revokeHost() { change(readmitting: false) }
    @objc private func readmitHost() { change(readmitting: true) }

    @objc private func interruptHost() {
        guard rows.indices.contains(hosts.indexOfSelectedItem), let coordinator, let current else { return }
        let hostID = rows[hosts.indexOfSelectedItem].hostID
        let active = { current() && NSApp.isActive && !Task.isCancelled }
        runInterrupt { [hub] in
            try await coordinator.prepareHostInterrupt(hostID: hostID, directory: {
                try await hub.controlPortal().stationDirectory()
            }, chooseStations: { review in
                guard active() else { throw AccountLoginError.changed }
                return try InterruptStationPicker.choose(review)
            }, current: active)
        }
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
                try coordinator.requireControlChange(review.request)
                pendingInterrupt = review
                let alert = NSAlert()
                alert.messageText = "Interrupt earlier host work?"
                let explanation = Self.interruptExplanation(review)
                if review.additionalStationOrigins.count > 3 {
                    alert.accessoryView = processEditor(explanation, editable: false).0
                } else {
                    alert.informativeText = explanation
                }
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

@MainActor
private final class InterruptStationPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let review: AstationRecoveryCoordinator.InterruptStations
    let origins: [String]
    init(_ review: AstationRecoveryCoordinator.InterruptStations) {
        self.review = review
        origins = review.candidates.union(review.unavailable).sorted()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { origins.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        title(row)
    }

    private func title(_ row: Int) -> String {
        let origin = origins[row]
        if review.unavailable.contains(origin) { return origin + " (unavailable in Portal)" }
        if review.previous.contains(origin) { return origin + " (previously confirmed)" }
        return origin
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        review.candidates.contains(origins[row])
    }

    static func choose(_ review: AstationRecoveryCoordinator.InterruptStations) throws -> Set<String> {
        if review.candidates.isEmpty && review.unavailable.isEmpty && review.directoryComplete { return [] }
        let alert = NSAlert()
        alert.messageText = "Choose Stations for this interruption"
        alert.informativeText = "The request will go to " + review.primary + "."
        if !review.directoryComplete {
            alert.informativeText += "\n\nThe Portal directory is unavailable or incomplete. Only known destinations are available."
        }
        let picker = InterruptStationPicker(review)
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 490, height: 165))
        if !picker.origins.isEmpty {
            alert.informativeText += "\n\nSelect any additional Stations for this request. Command-click to select more than one."
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 490, height: 165))
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("origin"))
            column.isEditable = false
            column.width = max(scroll.bounds.width - 20, picker.origins.indices.map {
                (picker.title($0) as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width + 16
            }.max() ?? 0)
            table.addTableColumn(column)
            table.headerView = nil
            table.allowsMultipleSelection = true
            table.allowsEmptySelection = true
            table.setAccessibilityLabel("Additional Stations")
            table.delegate = picker
            table.dataSource = picker
            scroll.documentView = table
            table.reloadData()
            table.deselectAll(nil)
            alert.accessoryView = scroll
        }
        alert.addButton(withTitle: "Review Request")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { throw CancellationError() }
        return Set(table.selectedRowIndexes.map { picker.origins[$0] })
    }
}
