import AppKit

final class ScreenRegionSelector {
    private static var activeWindow: ScreenRegionSelectionWindow?

    static func selectRegion(on screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        DispatchQueue.main.async {
            activeWindow?.close()
            let window = ScreenRegionSelectionWindow(screen: screen) { rectPoints in
                if let rectPoints {
                    let scale = screen.backingScaleFactor
                    let pixelRect = CGRect(
                        x: rectPoints.origin.x * scale,
                        y: rectPoints.origin.y * scale,
                        width: rectPoints.size.width * scale,
                        height: rectPoints.size.height * scale
                    )
                    completion(pixelRect)
                } else {
                    completion(nil)
                }
                activeWindow = nil
            }
            activeWindow = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private final class ScreenRegionSelectionWindow: NSWindow {
    private let onComplete: (CGRect?) -> Void
    private var didComplete = false

    init(screen: NSScreen, onComplete: @escaping (CGRect?) -> Void) {
        self.onComplete = onComplete
        let screenSize = screen.frame.size
        super.init(
            contentRect: NSRect(origin: .zero, size: screenSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: true)
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let overlay = ScreenRegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        overlay.autoresizingMask = [.width, .height]
        overlay.onSelection = { [weak self] rect in
            self?.complete(rect)
        }
        overlay.onCancel = { [weak self] in
            self?.complete(nil)
        }
        contentView = overlay
        makeFirstResponder(overlay)
    }

    override var canBecomeKey: Bool { true }

    private func complete(_ rect: CGRect?) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.didComplete else { return }
            self.didComplete = true
            self.close()
            self.onComplete(rect)
        }
    }
}

private final class ScreenRegionSelectionView: NSView {
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?
    private var didFinish = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        currentPoint = point
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if didFinish { return }
        guard let rect = selectionRect else {
            didFinish = true
            onCancel?()
            return
        }
        if rect.width < 10 || rect.height < 10 {
            didFinish = true
            onCancel?()
            return
        }
        didFinish = true
        onSelection?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            if didFinish { return }
            didFinish = true
            onCancel?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        dirtyRect.fill()

        guard let rect = selectionRect else { return }
        NSColor.clear.setFill()
        NSBezierPath(rect: rect).fill()

        NSColor.white.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
    }

    private var selectionRect: CGRect? {
        guard let start = startPoint, let current = currentPoint else { return nil }
        let x = min(start.x, current.x)
        let y = min(start.y, current.y)
        let width = abs(start.x - current.x)
        let height = abs(start.y - current.y)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
