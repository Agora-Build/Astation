import AppKit
import Combine

@MainActor
final class PairRemoteAtemWindowController: NSObject, NSWindowDelegate {
    private let hub: AstationHubManager
    private var window: NSWindow?
    private let code = NSTextField()
    private let station = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let connect = NSButton(title: "Connect", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel Pairing", target: nil, action: nil)
    private var subscription: AnyCancellable?

    init(hub: AstationHubManager) { self.hub = hub; super.init() }

    func showWindow(code initialCode: String? = nil) {
        if window == nil { buildWindow() }
        station.stringValue = "Station: \(hub.stationRelayUrl)"
        render(hub.pairingState)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !hub.pairingState.active { window?.makeFirstResponder(code) }
        if let initialCode { code.stringValue = initialCode; begin() }
    }

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pair Remote Atem"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        let title = NSTextField(labelWithString: "Pair Atem with this account")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString:
            "Enter the temporary code from Atem. You will compare safety codes and confirm device trust next.")
        detail.textColor = .secondaryLabelColor
        station.textColor = .secondaryLabelColor
        station.isSelectable = true
        code.placeholderString = "ABCD-2345"
        code.font = .monospacedSystemFont(ofSize: 18, weight: .medium)
        code.setAccessibilityLabel("Atem pairing code")
        connect.target = self; connect.action = #selector(begin)
        connect.keyEquivalent = "\r"
        cancel.target = self; cancel.action = #selector(cancelPairing)
        progress.style = .spinning; progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let entry = NSStackView(views: [code, connect]); entry.spacing = 10
        let feedback = NSStackView(views: [progress, status]); feedback.spacing = 10
        feedback.alignment = .top
        let stack = NSStackView(views: [title, detail, station, entry, feedback, cancel])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        guard let content = window.contentView else { return }
        content.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            entry.widthAnchor.constraint(equalTo: stack.widthAnchor),
            feedback.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            station.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        code.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.window = window
        subscription = hub.$pairingState.receive(on: DispatchQueue.main).sink { [weak self] state in
            self?.render(state)
        }
    }

    private func render(_ state: NativePairingState) {
        status.stringValue = state.message
        if case .failed = state { status.textColor = .systemRed }
        else { status.textColor = .secondaryLabelColor }
        code.isEnabled = !state.active
        connect.isEnabled = !state.active
        cancel.isHidden = !state.active
        if state.active { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    @objc private func begin() { hub.connectToRelay(code: code.stringValue) }
    @objc private func cancelPairing() { hub.cancelRemotePairing() }
    func windowWillClose(_ notification: Notification) { hub.cancelRemotePairing() }
}
