import AppKit

final class ScreenRegionSelector {
    private static var activeWindow: ScreenRegionSelectionWindow?
    private static let defaults = UserDefaults.standard
    private static let defaultsPrefix = "screenShare.region"

    static func selectRegion(on screen: NSScreen,
                             displayId: Int64,
                             completion: @escaping (CGRect?) -> Void) {
        DispatchQueue.main.async {
            activeWindow?.close()
            let initialRect = loadStoredRect(for: screen, displayId: displayId)
                ?? defaultRect(for: screen)
            let window = ScreenRegionSelectionWindow(screen: screen) { rectPoints in
                if let rectPoints {
                    saveStoredRect(rectPoints, for: screen, displayId: displayId)
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
                DispatchQueue.main.async {
                    activeWindow = nil
                }
            }
            window.setInitialSelection(initialRect)
            activeWindow = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private static func defaultRect(for screen: NSScreen) -> CGRect {
        let size = screen.frame.size
        return CGRect(
            x: size.width * 0.25,
            y: size.height * 0.25,
            width: size.width * 0.5,
            height: size.height * 0.5
        )
    }

    private static func loadStoredRect(for screen: NSScreen, displayId: Int64) -> CGRect? {
        let key = "\(defaultsPrefix).\(displayId)"
        guard let dict = defaults.dictionary(forKey: key),
              let x = dict["x"] as? Double,
              let y = dict["y"] as? Double,
              let w = dict["w"] as? Double,
              let h = dict["h"] as? Double else {
            return nil
        }
        let size = screen.frame.size
        guard size.width > 0, size.height > 0 else { return nil }
        return CGRect(
            x: CGFloat(x) * size.width,
            y: CGFloat(y) * size.height,
            width: CGFloat(w) * size.width,
            height: CGFloat(h) * size.height
        )
    }

    private static func saveStoredRect(_ rect: CGRect, for screen: NSScreen, displayId: Int64) {
        let size = screen.frame.size
        guard size.width > 0, size.height > 0 else { return }
        let dict: [String: Double] = [
            "x": Double(rect.origin.x / size.width),
            "y": Double(rect.origin.y / size.height),
            "w": Double(rect.size.width / size.width),
            "h": Double(rect.size.height / size.height)
        ]
        let key = "\(defaultsPrefix).\(displayId)"
        defaults.set(dict, forKey: key)
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
        isMovableByWindowBackground = false
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
            self.orderOut(nil)
            self.onComplete(rect)
        }
    }

    func setInitialSelection(_ rect: CGRect) {
        if let view = contentView as? ScreenRegionSelectionView {
            view.setSelection(rect)
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
    private var pendingStart: DispatchWorkItem?

    private let minSize: CGFloat = 20
    private let handleSize: CGFloat = 8
    private let instructions =
        "Drag to select. Drag inside to move, edges to resize. Release to start (auto), or Enter/double-click. Esc to cancel."

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
        pendingStart?.cancel()
        pendingStart = nil
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
        pendingStart?.cancel()
        pendingStart = nil
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
            scheduleAutoStart(for: rect)
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

        drawInstructions()

        guard let rect = selectionRect else { return }
        NSColor.clear.setFill()
        NSBezierPath(rect: rect).fill()

        NSColor.systemGreen.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 6
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

    func setSelection(_ rect: CGRect) {
        selectionRect = clamp(rect: rect)
        needsDisplay = true
    }

    private func scheduleAutoStart(for rect: CGRect) {
        pendingStart?.cancel()
        let pending = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.didFinish else { return }
            guard let current = self.selectionRect else { return }
            if current.equalTo(rect) {
                self.didFinish = true
                self.onSelection?(current)
            }
        }
        pendingStart = pending
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: pending)
    }

    private func drawInstructions() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let text = NSAttributedString(string: instructions, attributes: attrs)
        let textSize = text.size()
        let padding: CGFloat = 12
        let rect = CGRect(
            x: (bounds.width - textSize.width) / 2.0,
            y: bounds.height - textSize.height - padding,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: rect)
    }
}
