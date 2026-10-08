import AppKit

/// A binary dial, not a strength slider: polishing is always either on or off.
final class PolishKnob: NSButton {
    var compact = false { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    override var intrinsicContentSize: NSSize { compact ? NSSize(width: 106, height: 32) : NSSize(width: 170, height: 56) }
    override var state: NSControl.StateValue { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setButtonType(.toggle)
        isBordered = false
        title = "Polish"
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("Polish voice dictation")
        toolTip = "Polish finalized microphone dictation with the selected LLM. Does not change live system/app transcription."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let on = state == .on
        let diameter: CGFloat = compact ? 26 : 44
        let dial = NSRect(x: 3, y: (bounds.height - diameter) / 2, width: diameter, height: diameter)
        let accent = on ? NSColor.systemTeal : NSColor.secondaryLabelColor
        let alpha: CGFloat = isEnabled ? 1 : 0.45
        NSGraphicsContext.saveGraphicsState()
        let halo = NSBezierPath(ovalIn: dial.insetBy(dx: -2, dy: -2))
        accent.withAlphaComponent(on ? 0.24 * alpha : 0.08 * alpha).setFill(); halo.fill()
        let ring = NSBezierPath(ovalIn: dial)
        NSColor.black.withAlphaComponent(0.25 * alpha).setFill(); ring.fill()
        accent.withAlphaComponent(0.65 * alpha).setStroke(); ring.lineWidth = 1; ring.stroke()
        let face = NSBezierPath(ovalIn: dial.insetBy(dx: 3, dy: 3))
        NSGradient(starting: NSColor(calibratedWhite: 0.40, alpha: alpha), ending: NSColor(calibratedWhite: 0.13, alpha: alpha))?.draw(in: face, angle: -90)
        NSColor.white.withAlphaComponent(0.16 * alpha).setStroke(); face.lineWidth = 0.5; face.stroke()
        let angle: CGFloat = on ? .pi / 4 : 3 * .pi / 4
        let pointer = NSBezierPath()
        let radius = diameter * 0.32
        pointer.move(to: NSPoint(x: dial.midX + cos(angle) * radius * 0.48, y: dial.midY + sin(angle) * radius * 0.48))
        pointer.line(to: NSPoint(x: dial.midX + cos(angle) * radius, y: dial.midY + sin(angle) * radius))
        pointer.lineWidth = compact ? 2 : 3; pointer.lineCapStyle = .round
        (on ? NSColor.systemTeal : NSColor.white.withAlphaComponent(0.7)).setStroke(); pointer.stroke()
        let labelX = dial.maxX + (compact ? 8 : 14)
        let titleFont = NSFont.systemFont(ofSize: compact ? 10 : 13, weight: .semibold)
        let subtitleFont = NSFont.monospacedSystemFont(ofSize: compact ? 9 : 10, weight: .medium)
        ("Polish" as NSString).draw(at: NSPoint(x: labelX, y: bounds.midY + 1), withAttributes: [
            .font: titleFont, .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha)])
        ((on ? "ON" : "OFF") as NSString).draw(at: NSPoint(x: labelX, y: bounds.midY - (compact ? 11 : 14)), withAttributes: [
            .font: subtitleFont, .foregroundColor: accent.withAlphaComponent(alpha)])
        NSGraphicsContext.restoreGraphicsState()
    }
}
