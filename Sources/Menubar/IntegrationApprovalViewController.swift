import AppKit
import AtemClient
import AstationRemote

/// Account-scoped consent UI; all signing and durable retry state lives in the
/// existing recovery coordinator, shared with pairing and recovery.
@MainActor
final class IntegrationApprovalViewController: NSViewController {
    private let hub: AstationHubManager
    private let status = NSTextField(wrappingLabelWithString: "Choose a custom Station in General, then load your integration requests.")
    private let picker = NSPopUpButton()
    private let hosts = NSStackView()
    private let sessions = NSTextField()
    private let projects = NSTextField()
    private let reviewText = NSTextField(wrappingLabelWithString: "")
    private let loadButton = NSButton(title: "Load Requests", target: nil, action: nil)
    private let reviewButton = NSButton(title: "Review Access", target: nil, action: nil)
    private let approveButton = NSButton(title: "Approve on This Mac…", target: nil, action: nil)
    private let reviewAgainButton = NSButton(title: "Review Changed Request", target: nil, action: nil)
    private var hostButtons: [(String, NSButton)] = []
    private var records: [PortalIntegrationRecord] = []
    private var auth: AstationAccountAuth?
    private var portal: PortalIntegrationHTTP?
    private var coordinator: AstationRecoveryCoordinator?
    private var log: MembershipLog?
    private var approval: RemoteServiceApproval?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var contextCurrent: (() -> Bool)?

    init(hub: AstationHubManager) { self.hub = hub; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        let title = NSTextField(labelWithString: "Integration Access")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: "Review which agents an integration can use. Approval requires this Mac’s owner authentication.")
        intro.textColor = .secondaryLabelColor
        hosts.orientation = .vertical; hosts.alignment = .leading; hosts.spacing = 6
        sessions.placeholderString = "All sessions, or comma-separated session IDs"
        projects.placeholderString = "All projects, or comma-separated h1 project hashes"
        sessions.setAccessibilityLabel("Session restrictions")
        projects.setAccessibilityLabel("Project restrictions")
        reviewText.isSelectable = true
        reviewText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        let actions = NSStackView(views: [loadButton, reviewButton, approveButton])
        actions.spacing = 10
        let stack = NSStackView(views: [title, intro, actions, picker,
            NSTextField(labelWithString: "Allowed Atem hosts"), hosts, sessions, projects, reviewText, reviewAgainButton, status])
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
        for field in [intro, sessions, projects, reviewText, status] {
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        picker.target = self; picker.action = #selector(selectionChanged)
        loadButton.target = self; loadButton.action = #selector(loadRequests)
        reviewButton.target = self; reviewButton.action = #selector(reviewAccess)
        approveButton.target = self; approveButton.action = #selector(approveAccess)
        reviewAgainButton.target = self; reviewAgainButton.action = #selector(reviewAgain)
        render()
    }

    func cancelPending() {
        generation = UUID(); task?.cancel(); task = nil
        approval = nil; contextCurrent = nil; reviewText.stringValue = ""
        render()
    }

    private func render(busy: Bool = false) {
        loadButton.isEnabled = !busy
        picker.isEnabled = !busy && !records.isEmpty && approval == nil
        let pendingSelection = records.indices.contains(picker.indexOfSelectedItem)
            && records[picker.indexOfSelectedItem].state == "awaiting_approval"
        reviewButton.isEnabled = !busy && pendingSelection && approval == nil && contextCurrent?() == true
        approveButton.isEnabled = !busy && approval != nil && contextCurrent?() == true
        reviewAgainButton.isHidden = approval == nil
        reviewAgainButton.isEnabled = !busy && approval != nil && contextCurrent?() == true
        sessions.isEnabled = !busy && approval == nil; projects.isEnabled = sessions.isEnabled
        for (_, button) in hostButtons { button.isEnabled = sessions.isEnabled }
    }

    @objc private func selectionChanged() { approval = nil; reviewText.stringValue = ""; render() }

    @objc private func loadRequests() {
        cancelPending(); render(busy: true)
        do { try hub.configureIntegrationRelayAuth() }
        catch { status.stringValue = "Select a registered custom HTTPS Station in General to review integration access."; render(); return }
        let epoch = generation, accountEpoch = hub.integrationAccountGeneration, origin = hub.stationRelayUrl
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard let settings = hub.portalSettings, let owner = hub.signedInAccount, !hub.accountSignInRequired,
                      hub.accountAuth.configuration?.resource == origin else { throw AccountLoginError.signInRequired }
                let config = try AccountOIDCConfiguration(issuer: settings.issuer, clientID: settings.clientID,
                    resource: settings.portalURL, requiredScope: "integrations:read", additionalScopes: ["integrations:approve"])
                let auth = AstationAccountAuth(configuration: config,
                    storage: AccountKeychainStorage(service: "build.agora.astation.integrations-v1." + settings.storageContext))
                self.auth = auth
                do { _ = try await auth.accessToken() }
                catch AccountLoginError.signInRequired { try await auth.signIn() }
                do { _ = try await hub.accountAuth.accessToken() }
                catch AccountLoginError.signInRequired { try await hub.accountAuth.signIn() }
                let nativeSession = try await hub.accountAuth.current()
                if try await auth.current()?.session.subject != owner {
                    try await auth.signIn()
                }
                if nativeSession?.session.subject != owner {
                    try await hub.accountAuth.signIn()
                }
                guard try await auth.current()?.session.subject == owner,
                      try await hub.accountAuth.current()?.session.subject == owner else {
                    throw AccountLoginError.changed
                }
                let portal = try PortalIntegrationHTTP(configuration: config, portalOrigin: settings.portalURL,
                    ownerAccount: owner, accessToken: { try await auth.accessToken() })
                let records = try await portal.owned(stationOrigin: origin)
                let coordinator = try hub.recoveryCoordinator()
                let log = try await coordinator.serviceMembership()
                guard epoch == generation, accountEpoch == hub.integrationAccountGeneration,
                      hub.signedInAccount == owner, hub.stationRelayUrl == origin, !Task.isCancelled else { throw AccountLoginError.changed }
                contextCurrent = { [weak self, weak hub = self.hub] in
                    self?.generation == epoch && hub?.integrationAccountGeneration == accountEpoch && hub?.signedInAccount == owner
                        && hub?.accountSignInRequired == false && hub?.stationRelayUrl == origin
                }
                self.portal = portal; self.coordinator = coordinator; self.log = log
                self.records = records.filter { $0.state == "awaiting_approval" || ["provisioning", "waiting_for_host"].contains($0.state) }
                picker.removeAllItems(); picker.addItems(withTitles: self.records.map { "\($0.name) · \($0.state.replacingOccurrences(of: "_", with: " "))" })
                for child in hosts.arrangedSubviews { hosts.removeArrangedSubview(child); child.removeFromSuperview() }
                hostButtons = try Self.hostIDs(log).map { id in
                    let button = NSButton(checkboxWithTitle: id, target: nil, action: nil); hosts.addArrangedSubview(button)
                    return (id, button)
                }
                if let saved = try coordinator.pendingServiceApproval() {
                    guard saved.issuer == settings.issuer, saved.ownerAccount == owner, saved.stationOrigin == origin else {
                        throw AccountLoginError.changed
                    }
                    approval = saved; try showReview(saved)
                    status.stringValue = "A saved approval is ready to resume. Its original signature is retained."
                } else { status.stringValue = self.records.isEmpty ? "No requests are waiting on this Station." : "Choose an integration and its allowed hosts, then review access." }
                render()
            } catch { fail(error, epoch: epoch) }
        }
    }

    @objc private func reviewAccess() {
        guard records.indices.contains(picker.indexOfSelectedItem), let coordinator, let log, let settings = hub.portalSettings,
              let owner = hub.signedInAccount, contextCurrent?() == true else { return }
        let record = records[picker.indexOfSelectedItem], selectedHosts = hostButtons.filter { $0.1.state == .on }.map(\.0)
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
                try await coordinator.approveService(approval, portal: portal, current: { [weak self] in self?.contextCurrent?() == true && !Task.isCancelled })
                guard epoch == generation else { return }
                self.approval = nil; reviewText.stringValue = ""
                status.stringValue = "Access approved and saved. Hosted execution stays disabled until end-to-end verification is complete."
                records = []; picker.removeAllItems(); render()
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

    private func showReview(_ approval: RemoteServiceApproval) throws {
        let value = try RemoteServiceReview(approval: approval)
        reviewText.stringValue = "Account: \(approval.ownerAccount)\nStation: \(approval.stationOrigin)\nActions: \(value.operations.joined(separator: ", "))\nHosts: \(value.hosts.joined(separator: ", "))\nSessions: \(value.sessions?.joined(separator: ", ") ?? "All on allowed hosts")\nProjects: \(value.projects?.joined(separator: ", ") ?? "All on allowed hosts")\nExpires: \(value.expiresAt.formatted())\nService: \(value.serviceID)\nKey SHA-256: \(approval.fingerprint)\nAccount root: \(approval.genesisHash)\nPrevious entry: \(value.predecessor)"
    }
    private func fail(_ error: Error, epoch: UUID) {
        guard epoch == generation else { return }
        status.stringValue = error.localizedDescription; render()
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
