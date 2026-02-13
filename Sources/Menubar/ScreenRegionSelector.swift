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
        isMovableByWindowBackground = true
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

    private enum DragMode {
        case none
        case creating
        case moving
        case resizing(ResizeHandle)
    }

    private enum ResizeHandle {
        case topLeft
        case top
        case topRight
        case right
        case bottomRight
        case bottom
        case bottomLeft
        case left
    }

    private var startPoint: CGPoint?
    private var startRect: CGRect?
    private var selectionRect: CGRect?
    private var dragMode: DragMode = .none
    private var didFinish = false

    private let minSize: CGFloat = 20
    private let handleSize: CGFloat = 8

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let rect = selectionRect {
            didFinish = true
            onSelection?(rect)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point

        if let rect = selectionRect {
            if let handle = resizeHandle(at: point, in: rect) {
                dragMode = .resizing(handle)
                startRect = rect
            } else if rect.contains(point) {
                dragMode = .moving
                startRect = rect
            } else {
                dragMode = .creating
                selectionRect = nil
                startRect = nil
            }
        } else {
            dragMode = .creating
        }
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didFinish else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch dragMode {
        case .creating:
            selectionRect = rectFrom(start: startPoint, end: point)
        case .moving:
            if let startRect, let startPoint {
                let deltaX = point.x - startPoint.x
                let deltaY = point.y - startPoint.y
                selectionRect = clamp(rect: startRect.offsetBy(dx: deltaX, dy: deltaY))
            }
        case .resizing(let handle):
            if let startRect, let startPoint {
                selectionRect = clamp(rect: resize(rect: startRect, from: startPoint, to: point, handle: handle))
            }
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if didFinish { return }
        if case .creating = dragMode {
            let point = convert(event.locationInWindow, from: nil)
            selectionRect = rectFrom(start: startPoint, end: point)
        }
        dragMode = .none
        if let rect = selectionRect, rect.width >= minSize, rect.height >= minSize {
            return
        }
        selectionRect = nil
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            if didFinish { return }
            didFinish = true
            onCancel?()
        } else if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
            guard let rect = selectionRect else { return }
            if didFinish { return }
            didFinish = true
            onSelection?(rect)
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

    private func rectFrom(start: CGPoint?, end: CGPoint) -> CGRect? {
        guard let start else { return nil }
        let x = min(start.x, end.x)
        let y = min(start.y, end.y)
        let width = abs(start.x - end.x)
        let height = abs(start.y - end.y)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func clamp(rect: CGRect) -> CGRect {
        let bounds = self.bounds
        var r = rect
        if r.width < minSize { r.size.width = minSize }
        if r.height < minSize { r.size.height = minSize }
        if r.origin.x < bounds.minX { r.origin.x = bounds.minX }
        if r.origin.y < bounds.minY { r.origin.y = bounds.minY }
        if r.maxX > bounds.maxX { r.origin.x = bounds.maxX - r.width }
        if r.maxY > bounds.maxY { r.origin.y = bounds.maxY - r.height }
        return r
    }

    private func resizeHandle(at point: CGPoint, in rect: CGRect) -> ResizeHandle? {
        let left = abs(point.x - rect.minX) <= handleSize
        let right = abs(point.x - rect.maxX) <= handleSize
        let bottom = abs(point.y - rect.minY) <= handleSize
        let top = abs(point.y - rect.maxY) <= handleSize

        if left && bottom { return .bottomLeft }
        if right && bottom { return .bottomRight }
        if left && top { return .topLeft }
        if right && top { return .topRight }
        if left { return .left }
        if right { return .right }
        if bottom { return .bottom }
        if top { return .top }
        return nil
    }

    private func resize(rect: CGRect,
                        from start: CGPoint,
                        to current: CGPoint,
                        handle: ResizeHandle) -> CGRect {
        var r = rect
        let dx = current.x - start.x
        let dy = current.y - start.y
        switch handle {
        case .topLeft:
            r.origin.x += dx
            r.size.width -= dx
            r.size.height += dy
        case .top:
            r.size.height += dy
        case .topRight:
            r.size.width += dx
            r.size.height += dy
        case .right:
            r.size.width += dx
        case .bottomRight:
            r.size.width += dx
            r.origin.y += dy
            r.size.height -= dy
        case .bottom:
            r.origin.y += dy
            r.size.height -= dy
        case .bottomLeft:
            r.origin.x += dx
            r.size.width -= dx
            r.origin.y += dy
            r.size.height -= dy
        case .left:
            r.origin.x += dx
            r.size.width -= dx
        }
        return r
    }
}
