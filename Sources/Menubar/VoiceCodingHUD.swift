import AppKit

final class VoiceCodingHUD {
    static let shared = VoiceCodingHUD()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideWorkItem: DispatchWorkItem?
    private let minimumAutoHideSeconds: TimeInterval = 4.0
    private let topMargin: CGFloat = 28.0

    private init() {}

    func show(_ text: String, autoHideAfter: TimeInterval? = nil) {
        DispatchQueue.main.async {
            self.ensurePanel()
            self.positionOnActiveScreen()
            self.label?.stringValue = text
            self.panel?.alphaValue = 1.0
            self.panel?.orderFrontRegardless()

            self.hideWorkItem?.cancel()
            if let delay = autoHideAfter {
                let effectiveDelay = max(delay, self.minimumAutoHideSeconds)
                let work = DispatchWorkItem { [weak self] in
                    self?.hide()
                }
                self.hideWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDelay, execute: work)
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
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 56),
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
        label.textColor = NSColor.labelColor.withAlphaComponent(0.92)
        label.frame = NSRect(x: 12, y: 18, width: 256, height: 20)
        label.lineBreakMode = .byTruncatingTail

        effect.addSubview(label)
        panel.contentView = effect

        self.panel = panel
        self.label = label
    }

    private func positionOnActiveScreen() {
        guard let panel = panel, let frame = activeScreenVisibleFrame() else {
            return
        }
        let x = frame.midX - panel.frame.width / 2.0
        let y = frame.maxY - panel.frame.height - topMargin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func activeScreenVisibleFrame() -> NSRect? {
        if let keyScreen = NSApp.keyWindow?.screen?.visibleFrame {
            return keyScreen
        }
        if let mainScreen = NSApp.mainWindow?.screen?.visibleFrame {
            return mainScreen
        }
        let mouseLocation = NSEvent.mouseLocation
        if let pointerScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return pointerScreen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
    }
}
