import AppKit
import AtemClient
import AstationRemote

final class AccountSettingsViewController: NSViewController {
    private let hub: AstationHubManager
    private var auth: AstationAccountAuth? { hub.portalAuth }
    private let identity = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private lazy var signIn = NSButton(title: "Sign in to Agora.Build", target: self, action: #selector(login))
    private lazy var signOut = NSButton(title: "Sign out", target: self, action: #selector(logout))
    private lazy var stationOwnership = NSButton(title: "Review Station Ownership…", target: self, action: #selector(reviewStationOwnership))
    private var busy = false
    private var loginTask: Task<Void, Never>?
    private var loginAuth: AstationAccountAuth?

    init(hub: AstationHubManager) {
        self.hub = hub; super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionChanged), name: .accountLoginChanged, object: nil)
    }
    deinit { loginTask?.cancel(); NotificationCenter.default.removeObserver(self) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        let title = NSTextField(labelWithString: "Agora.Build Account")
        title.font = .boldSystemFont(ofSize: 17)
        let description = NSTextField(wrappingLabelWithString:
            "Sign in with Agora.Build. Manage your linked Agora account in Agora Projects. Device verification is still required for encrypted data and remote control.")
        description.textColor = .secondaryLabelColor
        identity.font = .systemFont(ofSize: 13, weight: .medium); identity.isSelectable = true
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        let actions = NSStackView(views: [signIn, signOut]); actions.spacing = 10
        [signIn, signOut, stationOwnership].forEach { $0.bezelStyle = .rounded }
        [title, description, identity, actions, stationOwnership, status].forEach { stack.addArrangedSubview($0) }
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        for label in [description, identity, status] {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        refresh()
    }
    override func viewWillAppear() { super.viewWillAppear(); refresh() }
    @objc private func sessionChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.busy, self.loginAuth !== self.auth {
                self.loginTask?.cancel(); self.loginAuth = nil; self.busy = false
            }
            self.refresh()
        }
    }
    private func refresh() {
        stationOwnership.isHidden = !["https://station-dev.agora.build", "https://station.agora.build"].contains(hub.stationRelayUrl)
        stationOwnership.isEnabled = !busy && !hub.needsAccountSignIn
        guard isViewLoaded, !busy else { return }
        Task { @MainActor in
            do {
                let currentAuth = auth
                let record = try await currentAuth?.current()
                guard currentAuth === auth, !busy else { return }
                identity.stringValue = record.map { $0.session.subject } ?? "Not signed in"
                status.stringValue = record?.refreshPending == true
                    ? "The last token refresh was interrupted. Sign in again to continue safely."
                    : record == nil ? "Sign in using your browser."
                    : hub.stationAccountSignInRequired ? "Sign in again to authorize the selected Station. Your Agora.Build account is still signed in."
                    : "Account credentials are saved in this device's Keychain."
                status.textColor = .secondaryLabelColor
                signIn.title = record == nil ? "Sign in to Agora.Build" : "Sign in again"
                signIn.isEnabled = auth?.configuration != nil; signOut.isEnabled = record != nil
            } catch {
                identity.stringValue = "Sign in to Agora.Build"
                status.stringValue = error.localizedDescription; status.textColor = .secondaryLabelColor
                signIn.isEnabled = auth?.configuration != nil; signOut.isEnabled = true
            }
        }
    }
    @MainActor @objc private func reviewStationOwnership() {
        guard !busy, let owner = hub.signedInAccount, !hub.needsAccountSignIn else { return }
        let origin = hub.stationRelayUrl, epoch = hub.integrationAccountGeneration
        let authorization = hub.accountAuth
        func current() -> Bool {
            hub.stationRelayUrl == origin && hub.integrationAccountGeneration == epoch &&
                hub.signedInAccount == owner && !hub.needsAccountSignIn && hub.accountAuth === authorization
        }
        busy = true
        stationOwnership.isEnabled = false
        signIn.isEnabled = false
        signOut.isEnabled = false
        Task { @MainActor in
            defer {
                busy = false
                signIn.isEnabled = auth?.configuration != nil
                signOut.isEnabled = hub.signedInAccount != nil
                stationOwnership.isEnabled = !hub.needsAccountSignIn
            }
            do {
                _ = try await authorization.accessToken(relayURL: origin)
                guard current(), let session = try await authorization.current()?.session,
                      current(), session.subject == owner else { throw AccountLoginError.changed }
                let coordinator = try hub.recoveryCoordinator()
                let receipt = coordinator.lastStationBindingReceipt
                let previous = receipt?.ownership ?? .neverBound
                let pending = coordinator.hasPendingStationBinding
                let submission: AstationRecoveryCoordinator.StationBindingSubmission
                let label: String
                let details: String
                if pending {
                    submission = .retry
                    label = "Check Previous Request"
                    details = "Check the Station's receipt for the ownership request already approved on this Mac."
                } else if let receipt, receipt.bindingState == "bound" {
                    let action: BindingAction = receipt.account == owner ? .unbind : .transfer
                    submission = .change(action, previous)
                    label = action == .unbind ? "Review Unbind…" : "Review Transfer…"
                    details = "This Mac last confirmed owner " + receipt.account + " at version " + String(receipt.version) + ". " +
                        (action == .unbind ? "Unbinding stops this Station from serving these hosts." :
                            "A transfer needs the current owner's separate consent.")
                } else {
                    submission = .change(.bind, previous)
                    label = "Review Binding…"
                    details = "Bind this device list to your Agora.Build account so its account status controls service at this Station."
                }
                let alert = NSAlert()
                alert.messageText = "Station ownership"
                alert.informativeText = details + "\n\nStation: " + origin + "\nSigned in as: " + owner
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: label)
                guard alert.runModal() == .alertSecondButtonReturn, current() else { return }
                let confirmed = try await coordinator.submitStationBinding(submission,
                    session: session, current: current)
                guard current() else { return }
                status.stringValue = "Station confirmed " + confirmed.bindingState + " at version " + String(confirmed.version) + "."
                status.textColor = .secondaryLabelColor
            } catch {
                guard current() else { return }
                status.stringValue = error.localizedDescription
                status.textColor = .systemRed
            }
        }
    }

    @objc private func login() {
        guard !busy else { return }; busy = true; signIn.isEnabled = false; signOut.isEnabled = false
        let context = auth
        loginAuth = context
        status.stringValue = "Continue sign-in in your browser..."; status.textColor = .secondaryLabelColor
        loginTask = Task { @MainActor in
            do {
                if hub.signedInAccount != nil, !hub.accountSignInRequired, hub.stationAccountSignInRequired {
                    try await hub.prepareAccountSecurityAccess()
                } else { try await hub.signInAccount() }
                guard loginAuth === context else { return }
                busy = false; refresh()
            }
            catch {
                guard loginAuth === context else { return }
                busy = false; status.stringValue = error.localizedDescription; status.textColor = .systemRed
                signIn.isEnabled = true; signOut.isEnabled = true
            }
        }
    }
    @objc private func logout() {
        let alert = NSAlert(); alert.messageText = "Sign out of Agora.Build?"
        alert.informativeText = "Account features and Agora projects will require sign-in again. Device keys, Recovery Kit, pairings and encrypted data are retained."
        alert.addButton(withTitle: "Sign Out"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            do {
                try await hub.signOutAccount()
                refresh()
            }
            catch { status.stringValue = error.localizedDescription; status.textColor = .systemRed }
        }
    }
}
