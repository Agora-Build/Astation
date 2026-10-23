import AppKit
import AstationRemote

final class AccountSettingsViewController: NSViewController {
    private let hub: AstationHubManager
    private let forRelayRecovery: Bool
    private var auth: AstationAccountAuth? { forRelayRecovery ? hub.accountAuth : hub.portalAuth }
    private let identity = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private lazy var signIn = NSButton(title: "Sign in to Agora.Build", target: self, action: #selector(login))
    private lazy var signOut = NSButton(title: "Sign out", target: self, action: #selector(logout))
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
        let title = NSTextField(labelWithString: forRelayRecovery ? "Account Recovery" : "Agora.Build Account")
        title.font = .boldSystemFont(ofSize: 17)
        let description = NSTextField(wrappingLabelWithString: forRelayRecovery
            ? "Authorize recovery and your signed device list with the same Agora.Build account. Device enrollment and recovery still require security verification."
            : "Sign in with Agora.Build. Manage your linked Agora account in Agora Projects. Device verification is still required for encrypted data and remote control.")
        description.textColor = .secondaryLabelColor
        identity.font = .systemFont(ofSize: 13, weight: .medium); identity.isSelectable = true
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        let actions = NSStackView(views: [signIn, signOut]); actions.spacing = 10
        [signIn, signOut].forEach { $0.bezelStyle = .rounded }
        [title, description, identity, actions, status].forEach { stack.addArrangedSubview($0) }
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
                signIn.title = record == nil ? "Sign in to Agora.Build" : "Sign in again"
                signIn.isEnabled = auth?.configuration != nil; signOut.isEnabled = record != nil
                if forRelayRecovery, auth?.configuration == nil {
                    status.stringValue = "Account recovery needs a registered relay API resource and scope. Configure ASTATION_ACCOUNT_RESOURCE and ASTATION_ACCOUNT_SCOPE for this build."
                }
            } catch {
                identity.stringValue = "Sign in to Agora.Build"
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
        let alert = NSAlert(); alert.messageText = "Sign out of Agora.Build?"
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
}
