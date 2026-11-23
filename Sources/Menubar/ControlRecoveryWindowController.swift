import AppKit
import AtemClient
import AstationRemote
import UniformTypeIdentifiers

@MainActor
final class ControlRecoveryWindowController: NSWindowController, NSWindowDelegate {
    struct Access {
        let coordinator: AstationRecoveryCoordinator
        let current: () -> Bool
        let canSign: () -> Bool
    }

    private let stationOrigin: String
    private let loadAccess: () throws -> Access
    private let confirm: ((RemoteControlRecoveryReview) async -> Bool)?
    private let makeSavePanel: @MainActor () -> NSSavePanel
    private let choices = NSPopUpButton()
    private let originalChoices = NSPopUpButton()
    private let details = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let authorStatus = NSTextField(wrappingLabelWithString: "")
    private let stationStatus = NSTextField(wrappingLabelWithString: "Station review has not been loaded. Saved copies remain available offline.")
    private let refresh = NSButton(title: "Refresh", target: nil, action: nil)
    private let sign = NSButton(title: "Confirm Copy...", target: nil, action: nil)
    private let export = NSButton(title: "Save Signed Copy...", target: nil, action: nil)
    private let sendCopy = NSButton(title: "Send to Station", target: nil, action: nil)
    private let loadReview = NSButton(title: "Load Station Review", target: nil, action: nil)
    private let exportRoster = NSButton(title: "Save Reviewed Processes...", target: nil, action: nil)
    private let checkHold = NSButton(title: "Check Signing Hold", target: nil, action: nil)
    private var heldPlan: RemoteControlRecoveryContext?
    private let report = NSButton(title: "Review Signing Report...", target: nil, action: nil)
    private let retryReport = NSButton(title: "Retry Report Delivery", target: nil, action: nil)
    private let prepare = NSButton(title: "Prepare Copy...", target: nil, action: nil)
    private var access: Access?
    private var rows: [RemoteControlRecoveryReview] = []
    private var originals: [RemoteControlActivity] = []
    private var preparation: RemoteControlRecoveryPreparation?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var panel: NSSavePanel?
    private var alert: NSAlert?

    convenience init(hub: AstationHubManager, stationOrigin: String) {
        self.init(stationOrigin: stationOrigin, loadAccess: {
            guard let owner = hub.signedInAccount, let issuer = hub.portalSettings?.issuer else {
                throw RemoteRecoveryError.requiresReview
            }
            let accountGeneration = hub.integrationAccountGeneration, selected = hub.stationRelayUrl
            return Access(coordinator: try hub.recoveryCoordinator(), current: {
                hub.signedInAccount == owner && hub.portalSettings?.issuer == issuer &&
                    hub.integrationAccountGeneration == accountGeneration && hub.stationRelayUrl == selected
            }, canSign: { !hub.accountSignInRequired && hub.stationRelayUrl == stationOrigin })
        })
    }

    init(stationOrigin: String, loadAccess: @escaping () throws -> Access,
        confirm: ((RemoteControlRecoveryReview) async -> Bool)? = nil,
        makeSavePanel: @escaping @MainActor () -> NSSavePanel = { NSSavePanel() }) {
        self.stationOrigin = stationOrigin; self.loadAccess = loadAccess
        self.confirm = confirm; self.makeSavePanel = makeSavePanel
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 720),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Recovery Copies"; window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 680)
        super.init(window: window)
        window.delegate = self
        let intro = NSTextField(wrappingLabelWithString:
            "Review saved recovery copies for " + stationOrigin + ". Originals stay saved. Confirming a copy does not publish a new feed or resume access.")
        details.isEditable = false; details.isSelectable = true
        details.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        details.textContainerInset = NSSize(width: 8, height: 8)
        details.isVerticallyResizable = true; details.isHorizontallyResizable = false
        details.autoresizingMask = .width; details.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = details
        let reviewActions = NSStackView(views: [loadReview, exportRoster, refresh]); reviewActions.spacing = 12
        let authorActions = NSStackView(views: [report, retryReport, checkHold]); authorActions.spacing = 12
        let originalActions = NSStackView(views: [originalChoices, prepare]); originalActions.spacing = 12
        originalChoices.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [sign, export, sendCopy]); actions.spacing = 12
        let stack = NSStackView(views: [intro, stationStatus, reviewActions, authorStatus, authorActions,
            NSTextField(labelWithString: "Original signed stop"), originalActions,
            NSTextField(labelWithString: "Saved recovery copy"), choices, scroll, status, actions])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        if let content = window.contentView {
            content.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
                intro.widthAnchor.constraint(equalTo: stack.widthAnchor),
                stationStatus.widthAnchor.constraint(equalTo: stack.widthAnchor),
                authorStatus.widthAnchor.constraint(equalTo: stack.widthAnchor),
                originalActions.widthAnchor.constraint(equalTo: stack.widthAnchor),
                choices.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
                status.widthAnchor.constraint(equalTo: stack.widthAnchor)
            ])
        }
        choices.setAccessibilityLabel("Saved recovery copy")
        choices.target = self; choices.action = #selector(selectionChanged)
        originalChoices.setAccessibilityLabel("Original signed stop")
        originalChoices.target = self; originalChoices.action = #selector(selectionChanged)
        refresh.target = self; refresh.action = #selector(reload)
        sign.target = self; sign.action = #selector(confirmCopy)
        export.target = self; export.action = #selector(saveCopy)
        sendCopy.target = self; sendCopy.action = #selector(retainCopy)
        loadReview.target = self; loadReview.action = #selector(loadStationReview)
        exportRoster.target = self; exportRoster.action = #selector(saveRoster)
        checkHold.target = self; checkHold.action = #selector(checkSigningHold)
        report.target = self; report.action = #selector(reviewReport)
        retryReport.target = self; retryReport.action = #selector(retrySignedReport)
        prepare.target = self; prepare.action = #selector(prepareCopy)
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
        reload()
    }

    private var selected: RemoteControlRecoveryReview? {
        rows.indices.contains(choices.indexOfSelectedItem) ? rows[choices.indexOfSelectedItem] : nil
    }

    private var selectedOriginal: RemoteControlActivity? {
        originals.indices.contains(originalChoices.indexOfSelectedItem) ? originals[originalChoices.indexOfSelectedItem] : nil
    }

    private func isCurrent(_ access: Access, epoch: UUID) -> Bool {
        generation == epoch && window?.isVisible == true && access.current() && !Task.isCancelled
    }

    func windowWillClose(_ notification: Notification) { invalidate() }

    private func invalidate() {
        generation = UUID(); task?.cancel()
        panel?.cancel(nil); panel = nil
        if let alert { window?.endSheet(alert.window, returnCode: .abort) }
        alert = nil; heldPlan = nil; access = nil; rows = []; originals = []; preparation = nil
        choices.removeAllItems(); originalChoices.removeAllItems(); details.string = ""
        authorStatus.stringValue = ""
        stationStatus.stringValue = "Station review has not been loaded. Saved copies remain available offline."
        render()
    }

    @objc private func contextChanged() {
        invalidate()
        status.stringValue = "Account or Station access changed. Refresh to review current copies."
    }

    @objc private func reload() {
        guard task == nil, panel == nil else { return }
        generation = UUID(); heldPlan = nil; access = nil; rows = []; originals = []; preparation = nil
        choices.removeAllItems(); originalChoices.removeAllItems(); details.string = ""
        authorStatus.stringValue = ""
        stationStatus.stringValue = "Station review has not been loaded. Saved copies remain available offline."
        do {
            let value = try loadAccess(), epoch = generation
            guard isCurrent(value, epoch: epoch) else { throw RemoteRecoveryError.requiresReview }
            let copies = try value.coordinator.localControlRecoveryReviews(stationOrigin: stationOrigin,
                current: { self.isCurrent(value, epoch: epoch) })
            access = value
            refreshAuthorInventory(value, epoch: epoch)
            setCopies(copies)
            status.stringValue = rows.isEmpty
                ? "No saved recovery copies. Load the Station review, then prepare a copy of an original stop. Preparation requires verified recovery authority."
                : "Saved copies shown. History, clocks, publication and reopening are separate recovery steps."
            do {
                originals = try value.coordinator.localControlRecoveryOriginals(stationOrigin: stationOrigin,
                    current: { self.isCurrent(value, epoch: epoch) })
                originalChoices.addItems(withTitles: originals.map {
                    $0.body.principal + " - " + $0.body.recordId
                })
            } catch {
                // A currently unreviewable original must not hide an independently
                // retained signed copy. Export still rechecks the protected store.
                status.stringValue = "Could not review originals for new preparation: " + error.localizedDescription +
                    " Saved recovery copies remain listed."
            }
        } catch { status.stringValue = "Could not read protected recovery copies: " + error.localizedDescription }
        render()
    }

    private func refreshAuthorInventory(_ access: Access, epoch: UUID) {
        guard isCurrent(access, epoch: epoch) else { return }
        do {
            let inventory = try access.coordinator.localControlAuthorInventory(stationOrigin: stationOrigin,
                current: { self.isCurrent(access, epoch: epoch) })
            guard isCurrent(access, epoch: epoch) else { return }
            heldPlan = inventory.heldPlan
            authorStatus.stringValue = "Stops retained on this Mac at last review: " +
                "\(inventory.signedRecords.count) signed, \(inventory.unsignedDraftBodies.count) unsigned, " +
                "\(inventory.missingSignatureBodies.count) with an unresolved signature." + (heldPlan == nil ? "" : " Stop signing is on hold.")
        } catch {
            guard isCurrent(access, epoch: epoch) else { return }
            heldPlan = nil
            authorStatus.stringValue = "This Mac's stop inventory is unavailable. Refresh to try again."
        }
    }

    private func setCopies(_ copies: [RemoteControlRecoveryReview], selecting recordID: String? = nil) {
        rows = copies
        choices.removeAllItems()
        choices.addItems(withTitles: rows.map {
            ($0.signed ? "Signed - " : "Needs confirmation - ") + $0.body.principal + " - " + $0.body.recordId
        })
        if let recordID, let index = rows.firstIndex(where: { $0.body.recordId == recordID }) {
            choices.selectItem(at: index)
        }
    }

    static func explanation(_ review: RemoteControlRecoveryReview) -> String {
        let body = review.body, context = review.context
        let intent: String
        if body.principal.hasPrefix("host:") {
            intent = "Request interruption of tasks sent by \(body.principal) before revoke #\(body.revokeSeq ?? 0). New work after readmit is unaffected."
        } else if body.action == "revoke" {
            intent = "Revoke \(body.principal). " + (body.interruptRunning == true
                ? "Also request interruption of its running tasks." : "Running tasks are not interrupted.")
        } else { intent = "Request interruption of running tasks from \(body.principal)." }
        return intent + "\n\n" + (review.signed ? "Signed copy saved." : "Fresh owner confirmation is required.") +
            " Originals stay saved. This copy does not confirm delivery, stop completion or restored access." +
            "\n\nStation: \(context.stationOrigin)\nAccount: \(context.accountID)\nGenesis: \(context.genesisHash)\nGeneration: \(context.generation)" +
            "\nPlan: \(context.planID)\nReplacement feed: \(context.candidateFeedID)" +
            "\nMembership: \(context.membershipHead.seq) / \(context.membershipHead.hash)" +
            "\nOriginal record: \(review.originalRecordID)\nNew record: \(body.recordId)\nSigner: \(body.signer)" +
            (body.principalKey.map { "\nPrincipal key: " + $0 } ?? "") +
            "\nReserved timestamp: \(body.issuedAt)" +
            "\nSource: \(context.sourceHash)\nEvidence: \(context.evidenceHash)"
    }

    @objc private func selectionChanged() { render() }

    @objc private func loadStationReview() {
        guard loadReview.isEnabled, let access else { return }
        let epoch = generation
        preparation = nil
        stationStatus.stringValue = "Loading the selected Station's prepared recovery review..."
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; render() }
            do {
                let value = try await access.coordinator.loadControlRecoveryPreparation(stationOrigin: stationOrigin,
                    current: { self.isCurrent(access, epoch: epoch) && access.canSign() })
                guard isCurrent(access, epoch: epoch), access.canSign() else { return }
                preparation = value
                stationStatus.stringValue = "Station review loaded for recovery generation \(value.context.generation). Access remains fenced."
                status.stringValue = "Complete history, signing clocks and service authority still need verification before signing or reopening."
            } catch {
                guard isCurrent(access, epoch: epoch) else { return }
                stationStatus.stringValue = "Could not load the Station review: " + error.localizedDescription
            }
        }
        render()
    }

    static func explanation(_ preparation: RemoteControlRecoveryPreparation) -> String {
        let context = preparation.context
        return "The Station retained this recovery plan. It does not prove complete history or signing clocks and does not authorize a signature or restored access." +
            "\n\nStation: \(context.stationOrigin)\nAccount: \(context.accountID)\nGenesis: \(context.genesisHash)" +
            "\nGeneration: \(context.generation)\nPlan: \(context.planID)\nReplacement feed: \(context.candidateFeedID)" +
            "\nMembership: \(context.membershipHead.seq) / \(context.membershipHead.hash)" +
            "\nSource: \(context.sourceHash)\nEvidence: \(context.evidenceHash)\nReconstruction: \(preparation.reconstructionHash)"
    }

    static func explanation(_ original: RemoteControlActivity) -> String {
        let body = original.body
        return "Original signed stop: \(body.recordId)\nPrincipal: \(body.principal)\nAction: \(body.action)" +
            "\nInterrupt running: \(body.action == "interrupt_running" || body.interruptRunning == true ? "yes" : "no")" +
            (body.revokeSeq.map { "\nHost revoke sequence: \($0)" } ?? "") +
            "\nOriginal signer: \(body.signer)\nOriginal timestamp: \(body.issuedAt)" +
            "\n\nPreparation reserves a timestamp and saves an unsigned draft only when recovery authority is verified. Review and confirm the draft separately."
    }

    @objc private func checkSigningHold() {
        guard checkHold.isEnabled, let access, let heldPlan else { return }
        let epoch = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; refreshAuthorInventory(access, epoch: epoch); render() }
            let current = { self.isCurrent(access, epoch: epoch) && access.canSign() }
            do {
                let ended = try await access.coordinator.checkSigningHold(heldPlan, current: current)
                guard current() else { return }
                if ended { preparation = nil }
                status.stringValue = ended ? "Station abandoned this plan. Its signing hold has ended."
                    : "Station still has this plan pending. Its signing hold continues."
            } catch {
                guard current() else { return }
                status.stringValue = "Could not verify the plan's end. " + error.localizedDescription
            }
        }
        render()
    }

    @objc private func reviewReport() {
        guard report.isEnabled, let access, let context = preparation?.context, let window else { return }
        let epoch = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; refreshAuthorInventory(access, epoch: epoch); render() }
            let current = { self.isCurrent(access, epoch: epoch) && access.canSign() }
            do {
                let preview = try access.coordinator.localControlAuthorInventory(stationOrigin: stationOrigin, current: current)
                guard preview.missingSignatureBodies.isEmpty else {
                    status.stringValue = "Resolve the missing signatures on this Mac before sending its report."
                    return
                }
                let slot = try access.coordinator.localSignerReportSlot(context)
                let sheet = NSAlert(); alert = sheet
                sheet.messageText = "Hold stop signing and report to Station?"
                sheet.informativeText = """
                    \(stationOrigin)
                    Recovery plan \(context.planID) (generation \(context.generation))
                    Replacement feed \(context.candidateFeedID)
                    Reporting slot \(slot)
                    SDK process \(verifierReportProcess())
                    This Mac will report \(preview.signedRecords.count) signed stops and commit to \(preview.reportDraftCount) draft bodies.

                    Continuing places a durable hold before Touch ID or password confirmation. During the hold this Mac cannot sign service stops for this Station or host interrupts at any Station. Closing this window or cancelling authentication keeps the hold.

                    You can still remove a service from the device list, revoke a host sender, or interrupt work through its live channel.
                    """
                sheet.addButton(withTitle: "Hold and Continue"); sheet.addButton(withTitle: "Cancel")
                sheet.buttons[0].keyEquivalent = ""
                sheet.buttons[1].keyEquivalent = "\r"
                let consent = await withCheckedContinuation { continuation in
                    sheet.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
                }
                alert = nil
                guard consent, current() else { return }
                try await access.coordinator.submitSignerReport(context, slot: slot, preview: preview, current: current)
                guard current() else { return }
                status.stringValue = "Station retained this Mac's signed report. The signing hold remains in place."
            } catch {
                guard current() else { return }
                status.stringValue = error.localizedDescription + " A saved signing hold stays in effect. Retry delivery to check for a receipt."
            }
        }
        render()
    }

    @objc private func retrySignedReport() {
        guard retryReport.isEnabled, let access, let context = preparation?.context else { return }
        let epoch = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; render() }
            let current = { self.isCurrent(access, epoch: epoch) && access.canSign() }
            do {
                let retained = try await access.coordinator.retrySignerReport(context, current: current)
                guard current() else { return }
                status.stringValue = retained ? "Station confirmed receipt of the saved report. The signing hold remains in place."
                    : "No current receipt. Load the latest Station review before approving a new report."
            } catch {
                guard current() else { return }
                status.stringValue = "Could not confirm report delivery. " + error.localizedDescription
            }
        }
        render()
    }

    @objc private func prepareCopy() {
        guard prepare.isEnabled, let access, let preparation, let original = selectedOriginal else { return }
        let epoch = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; refreshAuthorInventory(access, epoch: epoch); render() }
            let current = { self.isCurrent(access, epoch: epoch) && access.canSign() && self.preparation == preparation }
            do {
                let review = try await access.coordinator.prepareControlRecoveryCopy(recordID: original.body.recordId,
                    context: preparation.context, current: current)
                guard current() else { return }
                setCopies(try access.coordinator.localControlRecoveryReviews(stationOrigin: stationOrigin, current: current),
                    selecting: review.body.recordId)
                status.stringValue = review.signed
                    ? "The exact signed copy was already saved. Export it without another signature."
                    : "Unsigned copy saved. Review its intent and Station plan, then choose Confirm Copy."
            } catch {
                guard isCurrent(access, epoch: epoch) else { return }
                self.preparation = nil
                stationStatus.stringValue = "Load the Station review again before preparing another copy."
                status.stringValue = "Could not prepare recovery copy: " + error.localizedDescription
            }
        }
        render()
    }

    private func render() {
        let available = task == nil && panel == nil && access?.current() == true
        choices.isEnabled = available && !rows.isEmpty
        originalChoices.isEnabled = available && !originals.isEmpty
        refresh.isEnabled = task == nil && panel == nil
        sign.isEnabled = available && selected?.signed == false && access?.canSign() == true &&
            access?.coordinator.controlRecoveryAvailable == true
        export.isEnabled = available && selected?.signed == true
        sendCopy.isEnabled = available && selected?.signed == true && access?.canSign() == true
        loadReview.isEnabled = available && access?.canSign() == true
        exportRoster.isEnabled = available && preparation != nil && access?.canSign() == true
        checkHold.isEnabled = available && heldPlan != nil && access?.canSign() == true
        report.isEnabled = available && preparation != nil && access?.canSign() == true &&
            access?.coordinator.delegatedControlsAvailable == true
        retryReport.isEnabled = available && preparation != nil && access?.canSign() == true
        prepare.isEnabled = available && selectedOriginal != nil && preparation != nil &&
            access?.canSign() == true && access?.coordinator.controlRecoveryAvailable == true
        details.string = [selected.map(Self.explanation), selectedOriginal.map(Self.explanation), preparation.map {
            "Current Station Review\n\n" + Self.explanation($0)
        }].compactMap { $0 }.joined(separator: "\n\n")
    }

    @objc private func confirmCopy() {
        guard sign.isEnabled, let access, let review = selected else { return }
        let epoch = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; refreshAuthorInventory(access, epoch: epoch); render() }
            do {
                guard isCurrent(access, epoch: epoch), access.canSign() else { return }
                try access.coordinator.requireControlChange(review.request)
                let approved: Bool
                if let confirm { approved = await confirm(review) }
                else {
                    guard let window else { return }
                    let alert = NSAlert(); self.alert = alert
                    alert.messageText = "Confirm this recovery copy?"
                    alert.informativeText = Self.explanation(review)
                    alert.addButton(withTitle: "Continue to Confirmation"); alert.addButton(withTitle: "Cancel")
                    approved = await withCheckedContinuation { continuation in
                        alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
                    }
                    self.alert = nil
                }
                guard approved, isCurrent(access, epoch: epoch), access.canSign() else { return }
                _ = try await access.coordinator.signControlRecoveryCopy(review,
                    current: { self.isCurrent(access, epoch: epoch) && access.canSign() })
                guard isCurrent(access, epoch: epoch) else { return }
                setCopies(try access.coordinator.localControlRecoveryReviews(stationOrigin: stationOrigin,
                    current: { self.isCurrent(access, epoch: epoch) }), selecting: review.body.recordId)
                status.stringValue = "Signed copy saved. Use Save Signed Copy to hand it to the recovery operator. Access stays fenced."
            } catch {
                guard isCurrent(access, epoch: epoch) else { return }
                status.stringValue = "Could not confirm recovery copy: " + error.localizedDescription
            }
        }
        render()
    }

    @objc private func saveCopy() {
        guard export.isEnabled, let access, let review = selected else { return }
        saveEvidence(access, filename: "Astation Recovery Copy.json",
            message: "Save this exact signed copy for the Station recovery operator. It contains account and control metadata, not private keys. Saving does not publish it or resume access.",
            success: "Signed copy saved to file. Publication and reopening are still required.") { current in
            try access.coordinator.exportControlRecoveryCopies(context: review.context,
                recordIDs: [review.body.recordId], current: current)
        }
    }

    @objc private func saveRoster() {
        guard exportRoster.isEnabled, let access, let preparation else { return }
        saveEvidence(access, filename: "Astation Reviewed Processes.json",
            message: "Share these reviewed process IDs with the Station recovery operator to identify missing reports.",
            success: "Reviewed process list saved for comparison at this Station.") { current in
            try access.coordinator.exportAuthorRoster(preparation, current: current)
        }
    }

    private func saveEvidence(_ access: Access, filename: String, message: String, success: String,
        read: @escaping (() -> Bool) throws -> String) {
        guard let window else { return }
        let epoch = generation
        do {
            let json = try read { self.isCurrent(access, epoch: epoch) }
            let panel = makeSavePanel(); self.panel = panel
            panel.nameFieldStringValue = filename; panel.allowedContentTypes = [.json]
            panel.message = message
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self, self.panel === panel else { return }
                self.panel = nil
                defer { self.render() }
                guard response == .OK, let url = panel.url, self.isCurrent(access, epoch: epoch) else { return }
                do {
                    guard try read({ self.isCurrent(access, epoch: epoch) }) == json else {
                        throw RemoteRecoveryError.requiresReview
                    }
                    try RecoveryKit.save(json, to: url)
                    self.status.stringValue = success
                } catch { self.status.stringValue = "Could not save file: " + error.localizedDescription }
            }
            render()
        } catch { status.stringValue = "Could not export file: " + error.localizedDescription }
    }

    @objc private func retainCopy() {
        guard sendCopy.isEnabled, let access, let review = selected else { return }
        let epoch = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; render() }
            do {
                _ = try await access.coordinator.retainControlRecoveryCopy(review,
                    current: { self.isCurrent(access, epoch: epoch) && access.canSign() })
                guard isCurrent(access, epoch: epoch) else { return }
                status.stringValue = "Station retained the signed copy. Your original and saved copy stay protected. Access remains fenced."
            } catch {
                guard isCurrent(access, epoch: epoch) else { return }
                status.stringValue = "Could not confirm Station storage: " + error.localizedDescription +
                    " Retry sends the same saved signature."
            }
        }
        render()
    }
}
