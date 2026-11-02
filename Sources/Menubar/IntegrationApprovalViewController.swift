import AppKit
import AtemClient
import AstationRemote
import Combine

/// Account-scoped consent UI; all signing and durable retry state lives in the
/// existing recovery coordinator, shared with pairing and recovery.
@MainActor
final class IntegrationApprovalViewController: NSViewController {
    private let hub: AstationHubManager
    private let status = NSTextField(wrappingLabelWithString: "Load integration requests for your selected Station.")
    private let picker = NSPopUpButton()
    private let hosts = NSStackView()
    private let hostStatus = NSTextField(wrappingLabelWithString: "")
    private let sessions = NSTextField()
    private let projects = NSTextField()
    private let reviewText = NSTextField(wrappingLabelWithString: "")
    private let loadButton = NSButton(title: "Load Requests", target: nil, action: nil)
    private let reviewButton = NSButton(title: "Review Access", target: nil, action: nil)
    private let approveButton = NSButton(title: "Approve on This Mac…", target: nil, action: nil)
    private let reviewAgainButton = NSButton(title: "Review Changed Request", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove Revoked Access…", target: nil, action: nil)
    private let setupButton = NSButton(title: "Set Up Account Security…", target: nil, action: nil)
    private let openSecurity: () -> Void
    private let relayOnlyButton = NSButton(title: "Use Selected Relay Only…", target: nil, action: nil)
    private let relayStatus = NSTextField(wrappingLabelWithString: "")
    private var policySubscription: AnyCancellable?
    private var hostButtons: [(String, NSButton)] = []
    private var records: [PortalIntegrationRecord] = []
    private var auth: AstationAccountAuth?
    private var portal: PortalIntegrationHTTP?
    private var coordinator: AstationRecoveryCoordinator?
    private var log: MembershipLog?
    private var approval: RemoteServiceApproval?
    private var approvedScope: ApprovedScope?
    private var task: Task<Void, Never>?
    private var revocationRefresh: Task<Void, Never>?
    private var generation = UUID()
    private var contextCurrent: (() -> Bool)?
    private var securityMissingOnStation = false
    private var hasLoadedRequests = false
    private var selectedIntegrationID: String?

    init(hub: AstationHubManager, openSecurity: @escaping () -> Void = {}) {
        self.hub = hub; self.openSecurity = openSecurity; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        let title = NSTextField(labelWithString: "Integration Access")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "Review which agents an integration can use and who processes their content. Approval requires this Mac’s owner authentication.")
        intro.textColor = .secondaryLabelColor
        hosts.orientation = .vertical; hosts.alignment = .leading; hosts.spacing = 6
        hostStatus.textColor = .secondaryLabelColor
        sessions.placeholderString = "All sessions, or comma-separated session IDs"
        projects.placeholderString = "All projects, or comma-separated h1 project hashes"
        sessions.setAccessibilityLabel("Session restrictions")
        projects.setAccessibilityLabel("Project restrictions")
        reviewText.isSelectable = true
        reviewText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        picker.setAccessibilityLabel("Integration request")
        if picker.numberOfItems == 0 { picker.addItem(withTitle: "Load requests to choose an integration") }
        status.textColor = .secondaryLabelColor
        let actions = NSStackView(views: [loadButton, reviewButton, approveButton])
        actions.spacing = 10
        relayStatus.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, intro, relayOnlyButton, relayStatus, actions,
            NSTextField(labelWithString: "Integration request"), picker,
            setupButton, NSTextField(labelWithString: "Allowed Atem hosts"), hosts, hostStatus, sessions, projects, reviewText, reviewAgainButton, removeButton, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = NSView(); scroll.documentView = document
        view.addSubview(scroll); document.addSubview(stack)
        scroll.translatesAutoresizingMaskIntoConstraints = false; stack.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        for field in [intro, sessions, projects, reviewText, status, relayStatus, hostStatus] {
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        picker.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        picker.target = self; picker.action = #selector(selectionChanged)
        loadButton.target = self; loadButton.action = #selector(loadRequests)
        reviewButton.target = self; reviewButton.action = #selector(reviewAccess)
        approveButton.target = self; approveButton.action = #selector(approveAccess)
        reviewAgainButton.target = self; reviewAgainButton.action = #selector(reviewAgain)
        removeButton.target = self; removeButton.action = #selector(removeRevokedAccess)
        relayOnlyButton.target = self; relayOnlyButton.action = #selector(changeRelayPolicy)
        setupButton.target = self; setupButton.action = #selector(setupSecurity)
        policySubscription = hub.$relayOnlyPolicyStatus.sink { [weak self] value in self?.relayStatus.stringValue = value }
        render()
    }

    func cancelPending() {
        if records.indices.contains(picker.indexOfSelectedItem) { selectedIntegrationID = records[picker.indexOfSelectedItem].id }
        revocationRefresh?.cancel(); revocationRefresh = nil
        generation = UUID(); task?.cancel(); task = nil
        approval = nil; contextCurrent = nil; log = nil; reviewText.stringValue = ""
        coordinator = nil
        securityMissingOnStation = false
        approvedScope = nil
        records = []; picker.removeAllItems(); picker.addItem(withTitle: "Load requests to choose an integration")
        status.stringValue = "Load integration requests for your selected Station."
        showScope(hosts: [], sessions: nil, projects: nil, approved: false)
        render()
    }

    func refreshForDisplay() {
        _ = view
        guard hasLoadedRequests else { render(); return }
        reloadRequests(allowSignIn: false)
    }

    private func render(busy: Bool = false) {
        loadButton.isEnabled = !busy
        relayOnlyButton.isEnabled = !busy && log != nil && contextCurrent?() == true
        relayOnlyButton.title = hub.relayOnlyPolicyRequired && hub.relayOnlyPolicyAppliesToSelectedStation
            ? "Allow Direct Connections…" : "Use Selected Relay Only…"
        picker.isEnabled = !busy && !records.isEmpty && approval == nil
        let pendingSelection = records.indices.contains(picker.indexOfSelectedItem)
            && records[picker.indexOfSelectedItem].state == "awaiting_approval"
        let revoking = records.indices.contains(picker.indexOfSelectedItem)
            && ["revoking", "revoked"].contains(records[picker.indexOfSelectedItem].state)
        let pendingRemoval = revoking && (try? coordinator?.pendingServiceRemovalID()) == records[picker.indexOfSelectedItem].id
        let removed = revoking && log.map {
            (try? AstationRecoveryCoordinator.serviceRemovalComplete(record: records[picker.indexOfSelectedItem], log: $0)) == true
        } == true
        let removable = revoking && log.map { log in
            (try? AstationRecoveryCoordinator.removableService(record: records[picker.indexOfSelectedItem], log: log)) != nil
                || pendingRemoval
        } == true
        removeButton.isHidden = !revoking || (removed && !pendingRemoval)
        removeButton.isEnabled = !busy && removable && approval == nil && contextCurrent?() == true
        let canSelectHosts = !busy && pendingSelection && log != nil && approval == nil && contextCurrent?() == true
        let hasSelectedHost = hostButtons.contains { $0.1.state == .on }
        reviewButton.isEnabled = canSelectHosts && pendingSelection && hasSelectedHost
        let missingApprovedScope = log != nil && !pendingSelection && !records.isEmpty
            && approval == nil && approvedScope == nil
        hosts.isHidden = missingApprovedScope
        sessions.isHidden = missingApprovedScope; projects.isHidden = missingApprovedScope
        hostStatus.isHidden = revoking || log == nil || approval != nil || (!pendingSelection && !missingApprovedScope)
        hostStatus.stringValue = missingApprovedScope
            ? "The approved scope is not available in this Mac's verified account log. Load requests again to refresh it."
            : hostButtons.isEmpty
            ? "No verified Atem hosts are enrolled in this account. Pair and verify an Atem host, then load requests again."
            : "Select at least one host to review access."
        if hasSelectedHost && !missingApprovedScope { hostStatus.isHidden = true }
        setupButton.isHidden = contextCurrent?() != true || log != nil
        setupButton.title = securityMissingOnStation ? "Connect Account Security to This Station…" : "Set Up Account Security…"
        setupButton.isEnabled = !busy && contextCurrent?() == true
        approveButton.isEnabled = !busy && approval != nil && contextCurrent?() == true
        reviewAgainButton.isHidden = approval == nil
        reviewAgainButton.isEnabled = !busy && approval != nil && contextCurrent?() == true
        sessions.isEnabled = canSelectHosts && hasSelectedHost; projects.isEnabled = sessions.isEnabled
        for (_, button) in hostButtons { button.isEnabled = canSelectHosts }
    }

    @objc private func selectionChanged() {
        revocationRefresh?.cancel(); revocationRefresh = nil
        approval = nil; reviewText.stringValue = ""
        if records.indices.contains(picker.indexOfSelectedItem) { selectedIntegrationID = records[picker.indexOfSelectedItem].id }
        showSelectedScope()
        status.stringValue = selectedRequestGuidance()
        render()
        refreshRemovedServiceStatus()
    }
    @objc private func hostSelectionChanged() { render() }
    @objc private func setupSecurity() {
        guard securityMissingOnStation else { openSecurity(); return }
        guard let coordinator, let current = contextCurrent, current() else { return }
        let origin = coordinator.relayURL
        let alert = NSAlert()
        alert.messageText = "Connect your existing account security?"
        alert.informativeText = "Publish your saved, signed device list and an encrypted key backup to \(origin). Your identity, Recovery Kit, keys and verified devices are retained. Integration access still requires a separate approval."
        alert.addButton(withTitle: "Connect…"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, current() else { return }
        let epoch = generation; render(busy: true)
        status.stringValue = "Connecting your saved account security to the selected Station…"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await coordinator.connectAccountSecurity(current: current, confirm: {
                    await withCheckedContinuation { continuation in
                        DeviceOwnerAuth.authenticate(reason: "connect your existing account security to \(origin)") {
                            continuation.resume(returning: $0)
                        }
                    }
                })
                guard epoch == generation, current() else { return }
                loadRequests()
            } catch { fail(error, epoch: epoch) }
        }
    }

    @objc private func changeRelayPolicy() {
        guard contextCurrent?() == true else { return }
        let required = !hub.relayOnlyPolicyAppliesToSelectedStation || !hub.relayOnlyPolicyRequired
        let alert = NSAlert()
        alert.messageText = required ? "Use only the selected Station?" : "Allow direct Atem connections?"
        alert.informativeText = required
            ? "Atem hosts will save this policy and reconnect through your selected relay. Offline hosts remain pending. Agent integrations remain disabled until live verification is complete."
            : "Atem hosts may connect directly again after they save this change. This does not enable hosted integrations."
        alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        revocationRefresh?.cancel(); revocationRefresh = nil
        let epoch = generation; render(busy: true)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await hub.setRelayOnlyPolicy(required)
                guard epoch == generation else { return }
                render()
            } catch { fail(error, epoch: epoch) }
        }
    }

    @objc private func loadRequests() { reloadRequests(allowSignIn: true) }

    private func reloadRequests(allowSignIn: Bool) {
        cancelPending(); render(busy: true)
        status.stringValue = "Loading integration access for the selected Station…"
        do { try hub.configureIntegrationRelayAuth() }
        catch { status.stringValue = "Select the built-in Station or a registered custom HTTPS Station in General."; render(); return }
        let epoch = generation, accountEpoch = hub.integrationAccountGeneration, origin = hub.stationRelayUrl
        task = Task { [weak self] in
            guard let self else { return }
            do {
                func signIn(_ provider: AstationAccountAuth) async throws {
                    guard allowSignIn else { throw AccountLoginError.signInRequired }
                    try await provider.signIn()
                }
                guard let settings = hub.portalSettings, let owner = hub.signedInAccount, !hub.accountSignInRequired,
                      hub.accountAuth.configuration?.resource == origin else { throw AccountLoginError.signInRequired }
                let config = try AccountOIDCConfiguration(issuer: settings.issuer, clientID: settings.clientID,
                    resource: settings.portalURL, requiredScope: "integrations:read", additionalScopes: ["integrations:approve"])
                let auth = AstationAccountAuth(configuration: config,
                    storage: AccountKeychainStorage(service: "build.agora.astation.integrations-v1." + settings.storageContext))
                self.auth = auth
                do { _ = try await auth.accessToken() }
                catch AccountLoginError.signInRequired { try await signIn(auth) }
                do { _ = try await hub.accountAuth.accessToken() }
                catch AccountLoginError.signInRequired { try await signIn(hub.accountAuth) }
                let nativeSession = try await hub.accountAuth.current()
                if try await auth.current()?.session.subject != owner {
                    try await signIn(auth)
                }
                if nativeSession?.session.subject != owner {
                    try await signIn(hub.accountAuth)
                }
                guard try await auth.current()?.session.subject == owner,
                      try await hub.accountAuth.current()?.session.subject == owner else {
                    throw AccountLoginError.changed
                }
                let portal = try PortalIntegrationHTTP(configuration: config, portalOrigin: settings.portalURL,
                    ownerAccount: owner, accessToken: { try await auth.accessToken() })
                let records = try await portal.owned(stationOrigin: origin)
                guard epoch == generation, accountEpoch == hub.integrationAccountGeneration,
                      hub.signedInAccount == owner, hub.stationRelayUrl == origin, !Task.isCancelled else { throw AccountLoginError.changed }
                contextCurrent = { [weak self, weak hub = self.hub] in
                    self?.generation == epoch && hub?.integrationAccountGeneration == accountEpoch && hub?.signedInAccount == owner
                        && hub?.accountSignInRequired == false && hub?.stationRelayUrl == origin
                }
                self.portal = portal
                hasLoadedRequests = true
                setRequests(records, selectedID: selectedIntegrationID)
                for child in hosts.arrangedSubviews { hosts.removeArrangedSubview(child); child.removeFromSuperview() }
                hostButtons = []
                try await hub.prepareAccountSecurityAccess(allowSignIn: allowSignIn)
                guard contextCurrent?() == true else { throw AccountLoginError.changed }
                let coordinator = try hub.recoveryCoordinator()
                self.coordinator = coordinator
                guard try coordinator.securitySetupComplete else {
                    status.stringValue = "Requests loaded. Set up account security before reviewing integration access."
                    render(); return
                }
                let log = try await coordinator.serviceMembership()
                guard contextCurrent?() == true else { throw AccountLoginError.changed }
                try presentRequests(records, membership: log, coordinator: coordinator, portal: portal,
                    current: contextCurrent ?? { false }, selectedID: selectedIntegrationID)
            } catch { fail(error, epoch: epoch) }
        }
    }

    private func setRequests(_ records: [PortalIntegrationRecord], selectedID: String?) {
        self.records = records
        picker.removeAllItems()
        if records.isEmpty { picker.addItem(withTitle: "No integrations on this Station") }
        else {
            picker.addItems(withTitles: records.map(Self.requestTitle))
            if let index = records.firstIndex(where: { $0.id == selectedID }) { picker.selectItem(at: index) }
            self.selectedIntegrationID = records[picker.indexOfSelectedItem].id
        }
    }

    /// Display one validated account/Station snapshot; controls still require its live context.
    func presentRequests(_ records: [PortalIntegrationRecord], membership: MembershipLog,
        coordinator: AstationRecoveryCoordinator, portal: PortalIntegrationHTTP,
        current: @escaping () -> Bool, selectedID: String? = nil) throws {
        guard current() else { throw AccountLoginError.changed }
        self.coordinator = coordinator; self.portal = portal; log = membership.snapshot(); contextCurrent = current
        hasLoadedRequests = true
        approval = nil; reviewText.stringValue = ""
        setRequests(records, selectedID: selectedID)
        showSelectedScope()
        if let saved = try coordinator.pendingServiceApproval() {
            guard saved.issuer == portal.configuration.issuer, saved.ownerAccount == portal.ownerAccount,
                  saved.stationOrigin == coordinator.relayURL,
                  let index = records.firstIndex(where: { $0.id == saved.integrationID }) else { throw AccountLoginError.changed }
            picker.selectItem(at: index); selectedIntegrationID = saved.integrationID
            approval = saved; try showReview(saved)
            status.stringValue = "A saved approval is ready to resume. Its original signature is retained."
        } else {
            if let id = try coordinator.pendingServiceRemovalID(), let index = records.firstIndex(where: { $0.id == id }) {
                picker.selectItem(at: index); selectedIntegrationID = id; showSelectedScope()
            }
            status.stringValue = selectedRequestGuidance()
        }
        render()
        refreshRemovedServiceStatus()
    }

    @objc private func reviewAccess() {
        guard records.indices.contains(picker.indexOfSelectedItem), let coordinator, let log, let settings = hub.portalSettings,
              let owner = hub.signedInAccount, contextCurrent?() == true else { return }
        let record = records[picker.indexOfSelectedItem], selectedHosts = hostButtons.filter { $0.1.state == .on }.map(\.0)
        guard !selectedHosts.isEmpty else {
            status.stringValue = StationIntegrationError.hostSelectionRequired.localizedDescription
            render(); return
        }
        let epoch = generation
        render(busy: true)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let transport = try StationIntegrationHTTP(origin: record.stationOrigin,
                    accessToken: { [auth = hub.accountAuth] in try await auth.accessToken(relayURL: record.stationOrigin) })
                let draft = try await transport.prepare(record: record, ownerAccount: owner, issuer: settings.issuer,
                    log: log, managerID: coordinator.managerID, hosts: selectedHosts,
                    sessions: Self.items(sessions.stringValue), projects: Self.items(projects.stringValue),
                    signedAt: AstationRecoveryCoordinator.clock().wallMs)
                guard contextCurrent?() == true, !Task.isCancelled else { throw AccountLoginError.changed }
                let candidate = try RemoteServiceApproval(operationID: UUID().uuidString, integrationID: record.id,
                    issuer: settings.issuer, ownerAccount: owner, stationOrigin: record.stationOrigin,
                    bodyJSON: draft.bodyJSON, log: log, managerID: coordinator.managerID, now: AstationRecoveryCoordinator.clock())
                let review = try RemoteServiceReview(approval: candidate)
                try review.check(record: record, hosts: selectedHosts, sessions: Self.items(sessions.stringValue), projects: Self.items(projects.stringValue))
                guard candidate.fingerprint == draft.fingerprint else { throw AccountLoginError.invalidResponse }
                try await coordinator.prepareService(candidate)
                guard contextCurrent?() == true else { throw AccountLoginError.changed }
                approval = candidate; try showReview(candidate)
                status.stringValue = "Review this access carefully. Approval does not enable hosted execution yet."
                render()
            } catch { fail(error, epoch: epoch) }
        }
    }

    @objc private func approveAccess() {
        guard let approval, let coordinator, let portal, contextCurrent?() == true else { return }
        let epoch = generation; render(busy: true)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await coordinator.approveService(approval, portal: portal, current: { [weak self] in self?.contextCurrent?() == true && !Task.isCancelled })
                guard epoch == generation, let current = contextCurrent, current() else { return }
                self.approval = nil; reviewText.stringValue = ""
                let updated = records.map { $0.id == result.record.id ? result.record : $0 }
                try presentRequests(updated, membership: result.membership, coordinator: coordinator, portal: portal,
                    current: current, selectedID: result.record.id)
            } catch { fail(error, epoch: epoch) }
        }
    }

    @objc private func reviewAgain() {
        guard let approval, let coordinator, contextCurrent?() == true else { return }
        let epoch = generation; render(busy: true)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                do { try coordinator.cancelUnsignedService(approval) }
                catch { try await coordinator.reviewServiceAgain(approval) }
                guard epoch == generation else { return }
                self.approval = nil; loadRequests()
            } catch { fail(error, epoch: epoch) }
        }
    }

    @objc private func removeRevokedAccess() {
        guard records.indices.contains(picker.indexOfSelectedItem), let coordinator, let portal, let log,
              let owner = hub.signedInAccount, contextCurrent?() == true else { return }
        let record = records[picker.indexOfSelectedItem]
        guard ["revoking", "revoked"].contains(record.state) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove revoked integration access?"
        alert.informativeText = "\(record.name)\nStation: \(record.stationOrigin)\nService: \((try? AstationRecoveryCoordinator.removableService(record: record, log: log)) ?? "Resume saved removal")\nKey: \(record.r9Svc ?? "Unavailable")\n\nThis signs a removal from your verified account device list. It does not change other integrations."
        alert.addButton(withTitle: "Remove Access"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let epoch = generation; render(busy: true)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await coordinator.removeRevokedService(record, ownerAccount: owner, portal: portal,
                    current: { [weak self] in self?.contextCurrent?() == true && !Task.isCancelled })
                guard epoch == generation else { return }
                self.log = try await coordinator.serviceMembership()
                guard epoch == generation else { return }
                showSelectedScope()
                status.stringValue = selectedRequestGuidance()
                render()
                refreshRemovedServiceStatus()
            } catch { fail(error, epoch: epoch) }
        }
    }

    private static func requestTitle(_ record: PortalIntegrationRecord) -> String {
        let state = record.state == "waiting_for_host" ? "approved; waiting for host"
            : record.state.replacingOccurrences(of: "_", with: " ")
        return "\(record.name) · \(state)"
    }

    private func refreshRemovedServiceStatus() {
        revocationRefresh?.cancel(); revocationRefresh = nil
        guard records.indices.contains(picker.indexOfSelectedItem), let portal, let log else { return }
        let record = records[picker.indexOfSelectedItem]
        guard record.state == "revoking",
              (try? AstationRecoveryCoordinator.serviceRemovalComplete(record: record, log: log)) == true else { return }
        let epoch = generation
        let current = { [weak self] in
            guard let self, self.generation == epoch, self.contextCurrent?() == true,
                  self.records.indices.contains(self.picker.indexOfSelectedItem) else { return false }
            return self.records[self.picker.indexOfSelectedItem].id == record.id
        }
        revocationRefresh = Task { [weak self] in
            do {
                let complete = try await IntegrationRevocationRefresh.run(record: record, current: current,
                    fetch: { try await portal.owned(stationOrigin: record.stationOrigin) },
                    update: { [weak self] next in
                        guard let self, current() else { return }
                        let index = self.picker.indexOfSelectedItem
                        self.records[index] = next
                        self.picker.item(at: index)?.title = Self.requestTitle(next)
                        self.status.stringValue = self.selectedRequestGuidance()
                        self.render()
                    })
                if !complete, let self, current(), !Task.isCancelled {
                    self.status.stringValue = "Service removed from the verified account log. Station cleanup is still pending. Load requests to check again."
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, current(), !Task.isCancelled else { return }
                self.status.stringValue = "Service removed from the verified account log. Could not refresh Station cleanup status. Load requests to try again."
            }
        }
    }

    private func showReview(_ approval: RemoteServiceApproval) throws {
        let value = try RemoteServiceReview(approval: approval)
        showScope(hosts: value.hosts, sessions: value.sessions, projects: value.projects, approved: false)
        reviewText.stringValue = "\(IntegrationAccessNotice.disclosure(stationOrigin: approval.stationOrigin))\n\nAccount: \(approval.ownerAccount)\nStation: \(approval.stationOrigin)\nActions: \(value.operations.joined(separator: ", "))\nHosts: \(value.hosts.joined(separator: ", "))\nSessions: \(value.sessions?.joined(separator: ", ") ?? "All on allowed hosts")\nProjects: \(value.projects?.joined(separator: ", ") ?? "All on allowed hosts")\nExpires: \(value.expiresAt.formatted())\nService: \(value.serviceID)\nKey SHA-256: \(approval.fingerprint)\nAccount root: \(approval.genesisHash)\nPrevious entry: \(value.predecessor)"
    }

    struct ApprovedScope: Equatable {
        let hosts: [String]
        let sessions: [String]?
        let projects: [String]?
    }

    /// Resolve the Portal fingerprint against active membership verified by the
    /// shared core. Portal status alone cannot supply an approved host scope.
    static func approvedScope(record: PortalIntegrationRecord, log: MembershipLog,
                              now: HostClock = AstationRecoveryCoordinator.clock()) throws -> ApprovedScope? {
        guard ["provisioning", "waiting_for_host", "ready"].contains(record.state),
              let fingerprint = record.r9Svc else { return nil }
        let log = log.snapshot()
        _ = try log.advance(now: now)
        guard log.frozen() == nil else { return nil }
        let matches = try log.members().filter { member in
            guard member.kind == "service", member.status == .active, (member.expiresAt ?? 0) > now.wallMs else { return false }
            return try RemoteServiceKeyFingerprint.compute(member.authKey) == fingerprint
        }
        guard matches.count == 1, let scopeJSON = matches[0].scopeJson,
              let scope = try JSONSerialization.jsonObject(with: Data(scopeJSON.utf8)) as? [String: Any],
              let hosts = scope["hosts"] as? [String] else { return nil }
        return ApprovedScope(hosts: hosts, sessions: scope["sessions"] as? [String], projects: scope["projects"] as? [String])
    }

    private func showSelectedScope() {
        approvedScope = nil
        guard records.indices.contains(picker.indexOfSelectedItem), let log else { return }
        let record = records[picker.indexOfSelectedItem]
        approvedScope = try? Self.approvedScope(record: record, log: log)
        showScope(hosts: approvedScope?.hosts ?? [], sessions: approvedScope?.sessions,
                  projects: approvedScope?.projects, approved: record.state != "awaiting_approval")
    }

    private func showScope(hosts selected: [String], sessions allowedSessions: [String]?,
                           projects allowedProjects: [String]?, approved: Bool) {
        for child in hosts.arrangedSubviews { hosts.removeArrangedSubview(child); child.removeFromSuperview() }
        let enrolled = log.flatMap { try? Self.hostIDs($0) } ?? []
        hostButtons = Set(enrolled + selected).sorted().map { id in
            let button = NSButton(checkboxWithTitle: id, target: self, action: #selector(hostSelectionChanged))
            button.state = selected.contains(id) ? .on : .off
            hosts.addArrangedSubview(button)
            return (id, button)
        }
        sessions.stringValue = allowedSessions?.joined(separator: ", ") ?? (approved && approvedScope != nil ? "All sessions on approved hosts" : "")
        projects.stringValue = allowedProjects?.joined(separator: ", ") ?? (approved && approvedScope != nil ? "All projects on approved hosts" : "")
    }
    private func fail(_ error: Error, epoch: UUID) {
        guard epoch == generation else { return }
        if error as? RemoteRecoveryTransportError == .recordNotFound, log == nil, coordinator != nil {
            securityMissingOnStation = true
        }
        if error as? AccountLoginError == .signInRequired {
            status.stringValue = "Authorization needs to be renewed. Click Load Requests to sign in and refresh integration access."
            render(); return
        }
        status.stringValue = error.localizedDescription; render()
    }
    private func selectedRequestGuidance() -> String {
        guard records.indices.contains(picker.indexOfSelectedItem) else { return "No integrations are available on this Station." }
        switch records[picker.indexOfSelectedItem].state {
        case "waiting_for_host":
            return "Access is approved and saved. Waiting for an approved Atem host to connect to this Station."
        case "provisioning":
            return "Access is already approved. The Station is preparing this integration."
        case "ready":
            return "Access is approved and saved. The Station reports this integration as ready."
        case "revoking", "revoked":
            if let log, (try? AstationRecoveryCoordinator.serviceRemovalComplete(record: records[picker.indexOfSelectedItem], log: log)) == true {
                return records[picker.indexOfSelectedItem].state == "revoked"
                    ? "Access revoked. The service is removed from the verified account log and Station cleanup is complete."
                    : "The service is removed from the verified account log. Waiting for the Station to confirm cleanup."
            }
            return "Access has been revoked. Remove its service from the verified account log to complete cleanup."
        case "awaiting_approval":
            return "Choose the allowed hosts, then review access."
        default:
            return "Integration status: \(records[picker.indexOfSelectedItem].state.replacingOccurrences(of: "_", with: " ")). Load requests to refresh."
        }
    }
    private static func items(_ text: String) -> [String]? {
        let values = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return values.isEmpty ? nil : values
    }
    private static func hostIDs(_ log: MembershipLog) throws -> [String] {
        let ids = try log.entries().compactMap { entry -> String? in
            let body = try JSONSerialization.jsonObject(with: Data(signedObjectInfo(json: entry).bodyJcs.utf8)) as? [String: Any]
            return (body?["host"] as? [String: Any])?["host_id"] as? String
        }
        return Set(ids).filter { log.host(hostId: $0) != nil }.sorted()
    }
}
