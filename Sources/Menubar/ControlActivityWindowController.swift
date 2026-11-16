import AppKit
import AstationRemote

@MainActor
final class ControlActivityWindowController: NSWindowController, NSWindowDelegate {
    private let hub: AstationHubManager
    private let text = NSTextView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let refresh = NSButton(title: "Refresh", target: nil, action: nil)
    private var generation = UUID()
    private var task: Task<Void, Never>?

    init(hub: AstationHubManager) {
        self.hub = hub
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Control Activity"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let intro = NSTextField(wrappingLabelWithString:
            "Saved stops from this Mac, at the selected Station. Station reports do not confirm delivery to other Stations or guarantee that a running task stopped. A fresh manager review always needs a new owner confirmation.")
        text.isEditable = false; text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.documentView = text
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = .width
        text.textContainer?.widthTracksTextView = true
        let footer = NSStackView(views: [status, refresh]); footer.spacing = 12
        let stack = NSStackView(views: [intro, scroll, footer])
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
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        refresh.target = self; refresh.action = #selector(reload)
        for name in [Notification.Name.accountLoginChanged, .serverInfoChanged, .relayIdentityKeyChanged] {
            NotificationCenter.default.addObserver(self, selector: #selector(contextChanged), name: name, object: nil)
        }
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
    }

    @objc private func contextChanged() {
        generation = UUID(); task?.cancel(); text.string = ""
        status.stringValue = "Account or Station access changed. Refresh to review current records."
    }

    static func description(_ row: RemoteControlActivity) -> String {
        let action = row.body.action == "revoke" ? "Revoke" : "Interrupt"
        let portal = row.portalPending ? "\nPortal mirror is still pending." : ""
        return "\(action) \(row.body.principal)\n\(row.summary)\nRecord: \(row.body.recordId)\nSigner: \(row.body.signer)\(portal)"
    }

    @objc private func reload() {
        guard task == nil else { return }
        generation = UUID()
        let epoch = generation, origin = hub.stationRelayUrl
        text.string = ""; status.stringValue = "Loading saved control activity..."; refresh.isEnabled = false
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil; refresh.isEnabled = true }
            do {
                try await hub.prepareAccountSecurityAccess()
                guard generation == epoch, window?.isVisible == true,
                      let owner = hub.signedInAccount, let issuer = hub.portalSettings?.issuer else { return }
                let accountEpoch = hub.integrationAccountGeneration
                let current: () -> Bool = { [weak self] in
                    guard let self else { return false }
                    return generation == epoch && window?.isVisible == true && hub.stationRelayUrl == origin &&
                        hub.integrationAccountGeneration == accountEpoch && hub.signedInAccount == owner &&
                        hub.portalSettings?.issuer == issuer && !hub.accountSignInRequired
                }
                guard current(), !Task.isCancelled else { return }
                let coordinator = try hub.recoveryCoordinator()
                _ = try await coordinator.hostSenderMembership()
                guard current(), !Task.isCancelled else { return }
                let local = try coordinator.localControlActivity()
                text.string = local.isEmpty ? "No saved stops on this Mac for this Station." : local.map(Self.description).joined(separator: "\n\n")
                guard coordinator.delegatedControlsAvailable, !local.isEmpty else {
                    status.stringValue = "Station: " + origin + "\nHost application has not been checked."
                    return
                }
                do {
                    let activity = try await coordinator.refreshControlActivity(current: current)
                    guard current(), !Task.isCancelled else { return }
                    text.string = activity.map(Self.description).joined(separator: "\n\n")
                    status.stringValue = "Station: " + origin + "\nSelected Station reports refreshed."
                } catch {
                    guard current(), !Task.isCancelled else { return }
                    status.stringValue = "Saved records shown. Station reports unavailable; retry Refresh."
                }
            } catch {
                guard generation == epoch, window?.isVisible == true, !Task.isCancelled else { return }
                status.stringValue = error.localizedDescription
            }
        }
    }
}
