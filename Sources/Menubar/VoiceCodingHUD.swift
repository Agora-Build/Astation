import AppKit

final class VoiceCodingHUD {
    static let shared = VoiceCodingHUD()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWorkItem: DispatchWorkItem?

    private init() {}

    func show(_ text: String, autoHideAfter: TimeInterval? = nil) {
        DispatchQueue.main.async {
            self.ensurePanel()
            self.label?.stringValue = text
            self.panel?.alphaValue = 1.0
            self.panel?.orderFrontRegardless()

            self.hideWorkItem?.cancel()
            if let delay = autoHideAfter {
                let work = DispatchWorkItem { [weak self] in
                    self?.hide()
                }
                self.hideWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
    }

    func hide() {
        DispatchQueue.main.async {
            self.hideWorkItem?.cancel()
            self.panel?.orderOut(nil)
        }
    }

    private func ensurePanel() {
        if panel != nil { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 56),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effect = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true

        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = NSColor.labelColor.withAlphaComponent(0.9)
        label.frame = NSRect(x: 12, y: 18, width: 236, height: 20)
        label.lineBreakMode = .byTruncatingTail

        effect.addSubview(label)
        panel.contentView = effect

        if let screen = NSScreen.main?.visibleFrame {
            let x = screen.maxX - panel.frame.width - 24
            let y = screen.maxY - panel.frame.height - 24
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        self.panel = panel
        self.label = label
    }
}
