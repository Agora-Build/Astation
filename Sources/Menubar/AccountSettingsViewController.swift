import AppKit
import AstationRemote

final class AccountSettingsViewController: NSViewController {
    private let hub: AstationHubManager
    private let identity = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private lazy var signIn = NSButton(title: "Sign in to agora.build", target: self, action: #selector(login))
    private lazy var signOut = NSButton(title: "Sign out", target: self, action: #selector(logout))
    private var busy = false

    init(hub: AstationHubManager) { self.hub = hub; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView()
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        let title = NSTextField(labelWithString: "agora.build Account"); title.font = .boldSystemFont(ofSize: 17)
        let description = NSTextField(wrappingLabelWithString: "Use your agora.build account for account recovery and your signed device list. Adding or restoring a device still requires security verification.")
        description.textColor = .secondaryLabelColor
        identity.font = .systemFont(ofSize: 13, weight: .medium); identity.isSelectable = true
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        let actions = NSStackView(views: [signIn, signOut]); actions.spacing = 10
        signIn.bezelStyle = .rounded; signOut.bezelStyle = .rounded
        let services = NSTextField(wrappingLabelWithString: "Your Agora service connection in General is separate. It continues to provide projects and service credentials to paired Atems.")
        services.font = .systemFont(ofSize: 12); services.textColor = .secondaryLabelColor
        [title, description, identity, actions, status, services].forEach { stack.addArrangedSubview($0) }
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28)])
    }
    override func viewWillAppear() { super.viewWillAppear(); refresh() }
    private func refresh() {
        guard !busy else { return }
        Task { @MainActor in
            do {
                let record = try await hub.accountAuth.current()
                identity.stringValue = record.map { $0.session.subject } ?? "Not signed in"
                status.stringValue = record?.refreshPending == true
                    ? "The last token refresh was interrupted. Sign in again to continue safely."
                    : record == nil ? "Sign in to set up or restore account recovery." : "Account credentials are saved in this device's Keychain."
                status.textColor = .secondaryLabelColor
                signIn.title = record == nil ? "Sign in to agora.build" : "Sign in again"
                signIn.isEnabled = true; signOut.isEnabled = record != nil
            } catch {
                identity.stringValue = "Account unavailable"
                status.stringValue = error.localizedDescription; status.textColor = .secondaryLabelColor
                signIn.isEnabled = hub.accountAuth.configuration != nil; signOut.isEnabled = false
            }
        }
    }
    @objc private func login() {
        guard !busy else { return }; busy = true; signIn.isEnabled = false
        status.stringValue = "Continue sign-in in your browser..."; status.textColor = .secondaryLabelColor
        Task { @MainActor in
            do {
                try await hub.accountAuth.signIn()
                hub.accountSessionChanged()
                busy = false; refresh()
            } catch {
                busy = false; status.stringValue = error.localizedDescription; status.textColor = .systemRed
                signIn.isEnabled = true
            }
        }
    }
    @objc private func logout() {
        let alert = NSAlert(); alert.messageText = "Sign out of agora.build?"
        alert.informativeText = "Account recovery storage will require sign-in again. Your device keys, Recovery Kit, paired Atems and Agora service connection are retained."
        alert.addButton(withTitle: "Sign Out"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            do { try await hub.accountAuth.signOut(); hub.accountSessionChanged(); refresh() }
            catch { status.stringValue = error.localizedDescription; status.textColor = .systemRed }
        }
    }
}
