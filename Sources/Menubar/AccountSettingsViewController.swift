import AppKit
import AstationRemote

final class AccountSettingsViewController: NSViewController {
    private let hub: AstationHubManager
    private let forRelayRecovery: Bool
    private var auth: AstationAccountAuth? { forRelayRecovery ? hub.accountAuth : hub.portalAuth }
    private let identity = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let connection = NSTextField(wrappingLabelWithString: "")
    private lazy var signIn = NSButton(title: "Sign in to agora.build", target: self, action: #selector(login))
    private lazy var signOut = NSButton(title: "Sign out", target: self, action: #selector(logout))
    private lazy var manage = NSButton(title: "Connect Agora Account...", target: self, action: #selector(openConnections))
    private lazy var refreshProjects = NSButton(title: "Refresh Projects", target: self, action: #selector(reloadProjects))
    private var busy = false
    private var loginTask: Task<Void, Never>?
    private var loginAuth: AstationAccountAuth?

    init(hub: AstationHubManager, forRelayRecovery: Bool = false) {
        self.hub = hub; self.forRelayRecovery = forRelayRecovery; super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionChanged), name: .accountLoginChanged, object: nil)
    }
    deinit { loginTask?.cancel(); NotificationCenter.default.removeObserver(self) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        let title = NSTextField(labelWithString: forRelayRecovery ? "Account Recovery" : "agora.build Account")
        title.font = .boldSystemFont(ofSize: 17)
        let description = NSTextField(wrappingLabelWithString: forRelayRecovery
            ? "Authorize account recovery and your signed device list with the same agora.build account. Device enrollment and recovery still require security verification. Configure the main account and servers in General."
            : "Sign in with agora.build. Connect your Agora account in the portal to use its projects and service credentials. Device verification is still required for encrypted data and remote control.")
        description.textColor = .secondaryLabelColor
        identity.font = .systemFont(ofSize: 13, weight: .medium); identity.isSelectable = true
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        connection.font = .systemFont(ofSize: 12); connection.textColor = .secondaryLabelColor
        let actions = NSStackView(views: [signIn, signOut]); actions.spacing = 10
        let services = NSStackView(views: [manage, refreshProjects]); services.spacing = 10
        [signIn, signOut, manage, refreshProjects].forEach { $0.bezelStyle = .rounded }
        [title, description, identity, actions, status, connection, services].forEach { stack.addArrangedSubview($0) }
        connection.isHidden = forRelayRecovery; services.isHidden = forRelayRecovery
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: forRelayRecovery ? 24 : 0),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: forRelayRecovery ? -24 : 0),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: forRelayRecovery ? 28 : 0)
        ])
        if !forRelayRecovery { stack.bottomAnchor.constraint(equalTo: view.bottomAnchor).isActive = true }
        for label in [description, identity, status, connection] {
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
        guard isViewLoaded, !busy else { return }
        Task { @MainActor in
            do {
                let currentAuth = auth
                let record = try await currentAuth?.current()
                guard currentAuth === auth, !busy else { return }
                identity.stringValue = record.map { $0.session.subject } ?? "Not signed in"
                status.stringValue = record?.refreshPending == true
                    ? "The last token refresh was interrupted. Sign in again to continue safely."
                    : record == nil ? "Sign in using your browser." : "Account credentials are saved in this device's Keychain."
                status.textColor = .secondaryLabelColor
                signIn.title = record == nil ? "Sign in to agora.build" : "Sign in again"
                signIn.isEnabled = auth?.configuration != nil; signOut.isEnabled = record != nil
                if forRelayRecovery, auth?.configuration == nil {
                    status.stringValue = "Account recovery needs a registered relay API resource and scope. Configure ASTATION_ACCOUNT_RESOURCE and ASTATION_ACCOUNT_SCOPE for this build."
                }
                let agora = hub.agoraConnection
                connection.stringValue = agora?.connected == true
                    ? "Agora connected\(agora?.name.map { " (\($0))" } ?? ""). \(hub.projects.count) projects."
                    : "Agora projects become available after you connect an Agora account in the portal."
                if record != nil, hub.usingSavedProjects {
                    let date = hub.projectCacheUpdatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "an earlier session"
                    connection.stringValue = "Using \(hub.projects.count) saved Agora projects from \(date). Tokens can be generated offline."
                } else if record != nil, let error = hub.projectLoadError { connection.stringValue = error }
                manage.title = agora?.connected == true ? "Manage Agora Connection..." : "Connect Agora Account..."
                manage.isEnabled = hub.portalSettings != nil; refreshProjects.isEnabled = record != nil
            } catch {
                identity.stringValue = "Sign in to agora.build"
                status.stringValue = error.localizedDescription; status.textColor = .secondaryLabelColor
                signIn.isEnabled = auth?.configuration != nil; signOut.isEnabled = true
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
                if forRelayRecovery { try await hub.signInRelayAccount() }
                else { try await hub.signInAccount() }
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
        let alert = NSAlert(); alert.messageText = "Sign out of agora.build?"
        alert.informativeText = forRelayRecovery
            ? "Account recovery will require sign-in again. Device keys, Recovery Kit, pairings and your portal login are retained."
            : "Account features and Agora projects will require sign-in again. Device keys, Recovery Kit, pairings and encrypted data are retained."
        alert.addButton(withTitle: "Sign Out"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            do {
                if forRelayRecovery { try await hub.accountAuth.clearSession(); hub.accountSessionChanged() }
                else { try await hub.signOutAccount() }
                refresh()
            }
            catch { status.stringValue = error.localizedDescription; status.textColor = .systemRed }
        }
    }
    @objc private func openConnections() {
        guard let url = hub.portalSettings?.accountURL else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func reloadProjects() { hub.refreshProjects() }
}
