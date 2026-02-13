import AppKit

final class ScreenRegionSelector {
    private static var activeWindow: ScreenRegionSelectionWindow?

    static func selectRegion(on screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
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

private final class ScreenRegionSelectionWindow: NSWindow {
    private let onComplete: (CGRect?) -> Void

    init(screen: NSScreen, onComplete: @escaping (CGRect?) -> Void) {
        self.onComplete = onComplete
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let overlay = ScreenRegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        overlay.autoresizingMask = [.width, .height]
        overlay.onSelection = { [weak self] rect in
            self?.close()
            self?.onComplete(rect)
        }
        overlay.onCancel = { [weak self] in
            self?.close()
            self?.onComplete(nil)
        }
        contentView = overlay
        makeFirstResponder(overlay)
    }
}

private final class ScreenRegionSelectionView: NSView {
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: CGPoint?
    private var currentPoint: CGPoint?

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

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = selectionRect else {
            onCancel?()
            return
        }
        if rect.width < 10 || rect.height < 10 {
            onCancel?()
            return
        }
        onSelection?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
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
