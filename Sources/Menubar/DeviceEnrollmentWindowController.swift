import AppKit
import AstationRemote
import CoreImage

/// Private QR and owner consent stay in AppKit; no enrollment secret is sent to Flutter.
@MainActor
final class DeviceEnrollmentWindowController: NSWindowController, NSWindowDelegate {
    private let hub: AstationHubManager
    private let qr = NSImageView()
    private let status = NSTextField(wrappingLabelWithString: "Create a private setup code for your phone or tablet.")
    private let device = NSTextField(wrappingLabelWithString: "")
    private let code = NSTextField(labelWithString: "")
    private let permissions = NSPopUpButton()
    private let start = NSButton(title: "Show Setup Code", target: nil, action: nil)
    private let approve = NSButton(title: "Approve Device...", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel Setup", target: nil, action: nil)
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var review: RemoteNativeEnrollment?
    private var handoffPublished = false
    private var coordinator: AstationRecoveryCoordinator?
    private var current: (() -> Bool)?
    private var scope: (issuer: String, owner: String)?
    private var observers: [NSObjectProtocol] = []

    init(hub: AstationHubManager) {
        self.hub = hub
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 660),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Add Phone or Tablet"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let title = NSTextField(labelWithString: "Add a trusted device")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString:
            "Sign in to the same Agora.Build account on your phone, then scan this code directly from this Mac. Keep the code private.")
        intro.textColor = .secondaryLabelColor
        permissions.addItems(withTitles: ["View and control agents", "View only"])
        permissions.setAccessibilityLabel("New device permissions")
        qr.setAccessibilityLabel("Private device setup QR code")
        qr.imageScaling = .scaleProportionallyUpOrDown
        code.font = .monospacedSystemFont(ofSize: 22, weight: .semibold)
        device.font = .systemFont(ofSize: 14, weight: .medium)
        status.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [start, approve, cancel])
        buttons.spacing = 8
        let stack = NSStackView(views: [title, intro, permissions, qr, device, code, buttons, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        guard let content = window.contentView else { return }
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            qr.widthAnchor.constraint(equalTo: stack.widthAnchor), qr.heightAnchor.constraint(equalToConstant: 280),
            intro.widthAnchor.constraint(equalTo: stack.widthAnchor), status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            device.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        for (button, action) in [(start, #selector(showCode)), (approve, #selector(approveDevice)), (cancel, #selector(cancelSetup))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        approve.isEnabled = false; cancel.isEnabled = false
        for name in [NSApplication.didResignActiveNotification, NSApplication.willTerminateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hidePrivateState() }
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { task?.cancel(); for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center(); window?.makeKeyAndOrderFront(sender)
    }

    func windowWillClose(_ notification: Notification) { hidePrivateState() }

    private func hidePrivateState() {
        generation = UUID(); task?.cancel(); task = nil
        current = nil; review = nil; qr.image = nil; code.stringValue = ""; device.stringValue = ""
        approve.isEnabled = false; cancel.isEnabled = false; start.isEnabled = true
        status.stringValue = "Setup is saved on this Mac. Show the code again to continue."
    }

    @objc private func showCode() {
        let previous = task
        hidePrivateState()
        let epoch = generation
        let origin = hub.stationRelayUrl
        handoffPublished = false; cancel.title = "Cancel Setup"
        start.isEnabled = false; permissions.isEnabled = false
        status.stringValue = "Preparing a private setup code..."
        task = Task { [weak self] in
            guard let self else { return }
            do {
                await previous?.value
                guard epoch == generation, !Task.isCancelled else { return }
                try await hub.prepareAccountSecurityAccess()
                guard let issuer = hub.portalSettings?.issuer, let owner = hub.signedInAccount,
                      epoch == generation, origin == hub.stationRelayUrl else { throw AccountLoginError.changed }
                let accountEpoch = hub.integrationAccountGeneration
                let active: () -> Bool = { [weak self] in
                    guard let self else { return false }
                    return generation == epoch && window?.isVisible == true && NSApp.isActive &&
                        hub.integrationAccountGeneration == accountEpoch && hub.stationRelayUrl == origin &&
                        hub.signedInAccount == owner && hub.portalSettings?.issuer == issuer && !hub.accountSignInRequired
                }
                let coordinator = try hub.recoveryCoordinator()
                self.coordinator = coordinator; current = active; scope = (issuer, owner)
                let roles = permissions.indexOfSelectedItem == 1 ? ["view"] : ["control", "view"]
                let invitation = try await coordinator.startDeviceEnrollment(issuer: issuer, owner: owner, roles: roles, current: active)
                guard active() else { throw AccountLoginError.changed }
                qr.image = try Self.qrImage(invitation.qrJSON())
                cancel.isEnabled = true
                status.stringValue = "Scan this code in Astation on your phone. It expires in five minutes."
                while active() && !Task.isCancelled {
                    let state = try await coordinator.readDeviceEnrollment(issuer: issuer, owner: owner, current: active)
                    guard active() else { return }
                    if state.handedOff {
                        qr.image = nil
                        handoffPublished = true; cancel.title = "Done"
                        status.stringValue = "Access is approved. Finish setup on your phone."
                        return
                    }
                    if let request = state.request {
                        review = try await coordinator.prepareDeviceEnrollment(issuer: issuer, owner: owner, request: request, current: active)
                        guard active() else { return }
                        qr.image = nil; device.stringValue = request.deviceName
                        code.stringValue = try request.safetyCode
                        status.stringValue = "Check that this code matches your phone. It will receive \(request.roles.contains("control") ? "view and control" : "view-only") access, without account management."
                        approve.isEnabled = true
                        return
                    }
                    try await Task.sleep(for: .seconds(2))
                }
            } catch { fail(error, epoch: epoch) }
        }
    }

    @objc private func approveDevice() {
        guard let coordinator, let current, current(), let scope, let review else { return }
        let alert = NSAlert()
        alert.messageText = "Does this code match your phone?"
        alert.informativeText = "\(device.stringValue)\n\(code.stringValue)\n\nApprove only the device you just scanned."
        alert.addButton(withTitle: "Codes Match - Approve..."); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, current() else { return }
        let epoch = generation
        approve.isEnabled = false; cancel.isEnabled = false
        status.stringValue = "Confirm with Touch ID or your Mac password..."
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await coordinator.approveDeviceEnrollment(review, issuer: scope.issuer, owner: scope.owner, current: current)
                guard current() else { return }
                self.review = nil; code.stringValue = ""
                handoffPublished = true; cancel.title = "Done"
                status.stringValue = "Access is approved. Finish setup on your phone."
                cancel.isEnabled = true
            } catch { fail(error, epoch: epoch) }
        }
    }

    @objc private func cancelSetup() {
        if handoffPublished { window?.performClose(nil); return }
        guard let coordinator, let scope, let current, current() else { return }
        let previous = task
        previous?.cancel()
        let epoch = generation
        approve.isEnabled = false; cancel.isEnabled = false
        task = Task { [weak self] in
            guard let self else { return }
            do {
                await previous?.value
                guard current(), !Task.isCancelled else { return }
                try await coordinator.cancelDeviceEnrollment(issuer: scope.issuer, owner: scope.owner, current: current)
                guard current() else { return }
                hidePrivateState(); permissions.isEnabled = true; cancel.isEnabled = false
                status.stringValue = "Setup cancelled. An already approved device keeps its membership."
            } catch { fail(error, epoch: epoch) }
        }
    }

    private func fail(_ error: Error, epoch: UUID) {
        guard epoch == generation else { return }
        qr.image = nil; status.stringValue = error.localizedDescription
        start.isEnabled = true; cancel.isEnabled = coordinator != nil && current?() == true
        approve.isEnabled = review != nil && current?() == true
    }

    static func qrImage(_ secret: String) throws -> NSImage {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw RemoteDeviceEnrollmentError.invalidMessage }
        filter.setValue(Data(secret.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
              let cg = CIContext().createCGImage(image, from: image.extent) else { throw RemoteDeviceEnrollmentError.invalidMessage }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width), height: CGFloat(cg.height)))
    }
}
