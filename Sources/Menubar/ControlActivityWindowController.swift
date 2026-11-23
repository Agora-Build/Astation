import AppKit
import AstationRemote
import UniformTypeIdentifiers

@MainActor
final class ControlActivityWindowController: NSWindowController, NSWindowDelegate {
    private let hub: AstationHubManager
    private let stationOrigin: String?
    private let text = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let refresh = NSButton(title: "Refresh", target: nil, action: nil)
    private let export = NSButton(title: "Export Recovery Evidence...", target: nil, action: nil)
    private let recovery = NSButton(title: "Review Recovery Copies...", target: nil, action: nil)
    private var recoveryWindow: ControlRecoveryWindowController?
    private var exportPanel: NSSavePanel?
    private let stops = NSPopUpButton()
    private let review = NSButton(title: "Review with Current Manager...", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel Unsigned Copy", target: nil, action: nil)
    private var rows: [RemoteControlActivity] = []
    private var reviewRows: [RemoteControlActivity] = []
    private var coordinator: AstationRecoveryCoordinator?
    private var current: (() -> Bool)?
    private var discovery: AstationRecoveryCoordinator.ControlDiscoveryPage?
    private var generation = UUID()
    private var task: Task<Void, Never>?

    init(hub: AstationHubManager, stationOrigin: String? = nil) {
        self.hub = hub
        self.stationOrigin = stationOrigin
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Control Activity"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let intro = NSTextField(wrappingLabelWithString:
            "Saved stops for " + (stationOrigin ?? "the selected Station") + ". Refresh also finds stops whose signer lost manager access. Station reports do not confirm delivery elsewhere or guarantee that a running task stopped. Select this Station before signing a fresh copy with owner confirmation.")
        text.isEditable = false; text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.documentView = text
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = .width
        text.textContainer?.widthTracksTextView = true
        let footer = NSStackView(views: [status, refresh]); footer.spacing = 12
        let actions = NSStackView(views: [review, cancel]); actions.spacing = 8
        let recoveryActions = NSStackView(views: [export, recovery]); recoveryActions.spacing = 8
        let stack = NSStackView(views: [intro, scroll, stops, actions, recoveryActions, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        guard let content = window.contentView else { return }
        content.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            stops.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        refresh.target = self; refresh.action = #selector(reload)
        export.target = self; export.action = #selector(exportEvidence)
        recovery.target = self; recovery.action = #selector(showRecoveryCopies)
        stops.target = self; stops.action = #selector(selectionChanged)
        stops.setAccessibilityLabel("Stop requiring a fresh manager review")
        review.target = self; review.action = #selector(reviewStop)
        cancel.target = self; cancel.action = #selector(cancelReview)
        for name in [Notification.Name.accountLoginChanged, .serverInfoChanged, .relayIdentityKeyChanged] {
            NotificationCenter.default.addObserver(self, selector: #selector(contextChanged), name: name, object: nil)
        }
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { task?.cancel(); NotificationCenter.default.removeObserver(self) }

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
        generation = UUID(); task?.cancel(); text.string = ""; status.stringValue = ""
        clearContext()
    }

    @objc private func contextChanged() {
        generation = UUID(); task?.cancel(); text.string = ""
        clearContext()
        status.stringValue = "Account or Station access changed. Refresh to review current records."
    }

    private func clearContext() {
        recoveryWindow?.close(); recoveryWindow = nil
        exportPanel?.cancel(nil); exportPanel = nil
        coordinator = nil; current = nil; discovery = nil; rows = []; reviewRows = []; stops.removeAllItems(); render()
    }

    static func description(_ row: RemoteControlActivity) -> String {
        let action = row.body.action == "revoke" ? "Revoke" : "Interrupt"
        let portal = row.portalPending ? "\nPortal mirror is still pending." : ""
        let stations = row.additionalStations.keys.sorted().map {
            "\n\($0): " + (row.additionalStations[$0] == true ? "Stored - host application not checked" : "Delivery pending")
        }.joined()
        return "\(action) \(row.body.principal)\n\(row.summary)\nRecord: \(row.body.recordId)\nSigner: \(row.body.signer)\(portal)\(stations)"
    }

    private var selected: RemoteControlActivity? {
        reviewRows.indices.contains(stops.indexOfSelectedItem) ? reviewRows[stops.indexOfSelectedItem] : nil
    }

    private func display(_ activity: [RemoteControlActivity]) {
        let previous = selected?.body.recordId
        rows = activity
        reviewRows = activity.filter(\.requiresManagerReview)
        stops.removeAllItems()
        stops.addItems(withTitles: reviewRows.map { $0.body.principal + " - " + $0.body.recordId })
        if let index = reviewRows.firstIndex(where: { $0.body.recordId == previous }) { stops.selectItem(at: index) }
        text.string = activity.isEmpty ? "No saved stops found for this Station." : activity.map(Self.description).joined(separator: "\n\n")
        render()
    }

    @objc private func selectionChanged() { render() }

    private func render() {
        let ready = task == nil && exportPanel == nil && current?() == true && coordinator?.delegatedControlsAvailable == true &&
            (stationOrigin == nil || stationOrigin == coordinator?.relayURL)
        let replacement = selected?.replacementRecordID.flatMap { id in rows.first { $0.body.recordId == id } }
        review.title = replacement?.signed == true ? "Retry Saved Copy" : "Review with Current Manager..."
        review.isEnabled = ready && selected != nil
        cancel.isEnabled = ready && replacement?.signed == false
        stops.isEnabled = ready && !reviewRows.isEmpty
        refresh.isEnabled = task == nil && exportPanel == nil
        export.isEnabled = task == nil && exportPanel == nil && hub.signedInAccount != nil &&
            hub.portalSettings?.issuer != nil
        recovery.isEnabled = export.isEnabled
    }

    @objc private func showRecoveryCopies() {
        guard recovery.isEnabled else { return }
        if recoveryWindow == nil {
            recoveryWindow = ControlRecoveryWindowController(hub: hub, stationOrigin: stationOrigin ?? hub.stationRelayUrl)
        }
        recoveryWindow?.showWindow(nil)
    }

    @objc private func exportEvidence() {
        guard task == nil, exportPanel == nil, let window, let owner = hub.signedInAccount,
              let issuer = hub.portalSettings?.issuer else { return }
        let epoch = generation, accountEpoch = hub.integrationAccountGeneration, selectedOrigin = hub.stationRelayUrl
        let current: () -> Bool = { [weak self] in
            guard let self else { return false }
            return generation == epoch && window.isVisible && hub.stationRelayUrl == selectedOrigin &&
                hub.integrationAccountGeneration == accountEpoch && hub.signedInAccount == owner &&
                hub.portalSettings?.issuer == issuer
        }
        do {
            // A failed remote refresh or expired token cannot hide this account's
            // protected local evidence. Explicit sign-out clears the account.
            let coordinator = try hub.recoveryCoordinator()
            let evidence = try coordinator.exportControlRecoveryEvidence(stationOrigin: stationOrigin, current: current)
            let panel = NSSavePanel()
            exportPanel = panel
            panel.nameFieldStringValue = "Astation Control Recovery.json"
            panel.allowedContentTypes = [.json]
            panel.message = "Save original signed stops and unsigned reviews for Station recovery. This file contains account and control metadata, not private keys. It does not confirm a complete history or resume access."
            panel.beginSheetModal(for: window) { [weak self] result in
                guard let self, self.exportPanel === panel else { return }
                self.exportPanel = nil
                defer { self.render() }
                guard result == .OK, let url = panel.url, current() else { return }
                do {
                    try RecoveryKit.save(evidence, to: url)
                    self.status.stringValue = "Recovery evidence saved. Complete history, clocks and manager review are still required."
                } catch {
                    self.status.stringValue = "Could not save recovery evidence: " + error.localizedDescription
                }
            }
            render()
        } catch { status.stringValue = "Could not export recovery evidence: " + error.localizedDescription }
    }

    static func explanation(_ review: RemoteControlReview, station: String) -> String {
        let body = review.body
        let intent: String
        if body.principal.hasPrefix("host:") {
            intent = "Request interruption of tasks sent by \(body.principal) before revoke #\(body.revokeSeq ?? 0). New work after readmit is unaffected."
        } else if body.action == "revoke" {
            intent = "Revoke \(body.principal). " + (body.interruptRunning == true
                ? "Also request interruption of its running tasks." : "Running tasks are not interrupted.")
        } else { intent = "Request interruption of running tasks from \(body.principal)." }
        let stations = [station] + review.additionalStationOrigins
        return intent + "\n\nThe original stop stays saved. This copy does not confirm that tasks stopped or that other Stations received it." +
            "\nStations to receive this copy:\n" + stations.joined(separator: "\n") +
            "\nOriginal record: \(review.resignsRecordID ?? "")\nNew record: \(body.recordId)\nSigner: \(body.signer)"
    }

    @objc private func reviewStop() {
        guard task == nil, let row = selected, let coordinator, let current, current(),
              stationOrigin == nil || stationOrigin == coordinator.relayURL else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; render() }
            do {
                let prepared = try await coordinator.prepareControlResign(recordID: row.body.recordId, current: current)
                guard current(), !Task.isCancelled else { return }
                if !prepared.signed { try coordinator.requireControlChange(prepared.request) }
                let alert = NSAlert()
                alert.messageText = prepared.signed ? "Retry the saved stop?" : "Confirm this stop with the current manager?"
                alert.informativeText = Self.explanation(prepared, station: coordinator.relayURL)
                alert.addButton(withTitle: prepared.signed ? "Retry Delivery" : "Continue to Confirmation")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn, current(), !Task.isCancelled else {
                    if current() { display(try coordinator.localControlActivity()) }
                    return
                }
                let result = try await coordinator.commitControlResign(prepared, current: current)
                guard current(), !Task.isCancelled else { return }
                display(try coordinator.localControlActivity())
                status.stringValue = result.stationStored
                    ? "Fresh copy stored at the selected Station. Host application is not confirmed."
                    : "Fresh copy saved. Station delivery will retry with the same signature."
            } catch {
                guard current(), !Task.isCancelled else { return }
                status.stringValue = error.localizedDescription
                if let activity = try? coordinator.localControlActivity() { display(activity) }
            }
        }
        render()
    }

    @objc private func cancelReview() {
        guard task == nil, let row = selected, let coordinator, current?() == true,
              stationOrigin == nil || stationOrigin == coordinator.relayURL else { return }
        do {
            try coordinator.cancelUnsignedControlResign(recordID: row.body.recordId)
            display(try coordinator.localControlActivity())
            status.stringValue = "Unsigned copy cancelled. The original stop is retained."
        } catch { status.stringValue = error.localizedDescription }
    }

    @objc private func reload() {
        guard task == nil else { return }
        generation = UUID()
        let epoch = generation, selectedOrigin = hub.stationRelayUrl
        let origin = stationOrigin ?? selectedOrigin
        text.string = ""; status.stringValue = "Loading saved control activity..."; refresh.isEnabled = false
        coordinator = nil; current = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; render() }
            do {
                if origin == selectedOrigin { try await hub.prepareAccountSecurityAccess(allowSignIn: false) }
                guard generation == epoch, window?.isVisible == true,
                      let owner = hub.signedInAccount, let issuer = hub.portalSettings?.issuer else { return }
                let accountEpoch = hub.integrationAccountGeneration
                let current: () -> Bool = { [weak self] in
                    guard let self else { return false }
                    return generation == epoch && window?.isVisible == true && hub.stationRelayUrl == selectedOrigin &&
                        hub.integrationAccountGeneration == accountEpoch && hub.signedInAccount == owner &&
                        hub.portalSettings?.issuer == issuer && !hub.accountSignInRequired
                }
                guard current(), !Task.isCancelled else { return }
                let coordinator = try hub.recoveryCoordinator()
                if origin == selectedOrigin { _ = try await coordinator.hostSenderMembership() }
                guard current(), !Task.isCancelled else { return }
                self.coordinator = coordinator; self.current = current
                let local = try coordinator.localControlActivity(stationOrigin: origin)
                display(local)
                guard coordinator.delegatedControlsAvailable else {
                    status.stringValue = "Station: " + origin + "\nHost application has not been checked."
                    return
                }
                do {
                    discovery = try await coordinator.discoverControlActivity(previous: discovery, stationOrigin: origin, current: current)
                    guard current(), !Task.isCancelled else { return }
                    let activity = try await coordinator.refreshControlActivity(stationOrigin: origin, current: current)
                    guard current(), !Task.isCancelled else { return }
                    display(activity)
                    status.stringValue = "Station: " + origin + "\nThis Station's reports refreshed." +
                        (discovery?.more == true ? " Refresh continues the search for other saved stops." : "") +
                        (origin != selectedOrigin ? " Select this Station to review and sign a fresh copy." : "")
                } catch {
                    guard current(), !Task.isCancelled else { return }
                    status.stringValue = "Saved records shown. Station reports unavailable; retry Refresh."
                    if let activity = try? coordinator.localControlActivity(stationOrigin: origin) { display(activity) }
                }
            } catch {
                guard generation == epoch, window?.isVisible == true, !Task.isCancelled else { return }
                status.stringValue = error.localizedDescription
            }
        }
        render()
    }
}
