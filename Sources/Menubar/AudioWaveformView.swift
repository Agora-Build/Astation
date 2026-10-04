import AppKit

final class AudioWaveformView: NSView {
    var snapshot = AudioMeterSnapshot() { didSet { needsDisplay = true } }
    var tint: NSColor = .systemTeal
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let panel = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        panel.addClip()
        NSGradient(starting: tint.withAlphaComponent(0.06), ending: NSColor.controlBackgroundColor)?.draw(in: bounds, angle: 90)
        let lanes = snapshot.lanes.isEmpty ? [[]] : snapshot.lanes
        let height = bounds.height / CGFloat(lanes.count)
        for (index, bins) in lanes.enumerated() {
            let lane = NSRect(x: 0, y: CGFloat(index) * height, width: bounds.width, height: height)
            let middle = lane.midY
            let grid = NSBezierPath()
            for fraction in [CGFloat(0.25), 0.5, 0.75] {
                let y = lane.minY + height * fraction
                grid.move(to: NSPoint(x: 0, y: y))
                grid.line(to: NSPoint(x: bounds.width, y: y))
            }
            for second in 1..<5 {
                let x = bounds.width * CGFloat(second) / 5
                grid.move(to: NSPoint(x: x, y: lane.minY))
                grid.line(to: NSPoint(x: x, y: lane.maxY))
            }
            NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
            grid.lineWidth = 0.5
            grid.stroke()
            let center = NSBezierPath()
            center.move(to: NSPoint(x: 0, y: middle))
            center.line(to: NSPoint(x: bounds.width, y: middle))
            tint.withAlphaComponent(0.25).setStroke()
            center.lineWidth = 0.7
            center.stroke()
            guard !bins.isEmpty else { continue }
            let step = bounds.width / 150
            let origin = bounds.width - step * CGFloat(bins.count)
            let bars = NSBezierPath()
            for (position, bin) in bins.enumerated() {
                guard bin.minimum != 0 || bin.maximum != 0 else { continue }
                let x = origin + CGFloat(position) * step
                let top = middle - CGFloat(min(1, max(-1, bin.maximum))) * height * 0.43
                let bottom = middle - CGFloat(min(1, max(-1, bin.minimum))) * height * 0.43
                bars.move(to: NSPoint(x: x, y: top))
                bars.line(to: NSPoint(x: x, y: bottom))
            }
            tint.setStroke()
            bars.lineWidth = max(1, step * 0.6)
            bars.lineCapStyle = .butt
            bars.stroke()
            if lanes.count > 1 {
                let text = index == 0 ? "L" : "R"
                (text as NSString).draw(at: NSPoint(x: 7, y: lane.minY + 5), withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor
                ])
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class AudioLevelMeterView: NSView {
    var rmsDB: Double = -120
    var peakDB: Double = -120
    var tint: NSColor = .systemTeal

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        let level = CGFloat(max(0, min(1, (rmsDB + 60) / 60)))
        let rect = NSRect(x: 0, y: 0, width: bounds.width * level, height: bounds.height)
        if rect.width > 0 {
            tint.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        }
        if peakDB > -60 {
            let peak = CGFloat(max(0, min(1, (peakDB + 60) / 60)))
            (peakDB >= -0.1 ? NSColor.systemRed : NSColor.labelColor.withAlphaComponent(0.7)).setFill()
            NSRect(x: max(0, min(bounds.width - 2, bounds.width * peak)), y: 0, width: 2, height: bounds.height).fill()
        }
    }
}

final class AudioSourceCardView: NSView {
    let waveform = AudioWaveformView()
    private let status = NSTextField(labelWithString: "Preview off")
    private let levels = NSTextField(labelWithString: "RMS --   PEAK --")
    private let meter = AudioLevelMeterView()
    private let badge = NSTextField(labelWithString: "ORIGINAL")
    private var activityTracker = AudioSourceActivityTracker()
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor.controlBackgroundColor.setFill()
        panel.fill()
        NSColor.separatorColor.setStroke()
        panel.lineWidth = 1
        panel.stroke()
    }

    init(source: AudioSourceSelection, icon: NSImage?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // Direct constraints avoid NSBox's separately resized content frame drifting on relayout.
        heightAnchor.constraint(equalToConstant: 180).isActive = true
        let tint: NSColor
        switch source.kind {
        case .microphone: tint = .systemTeal
        case .system: tint = .systemBlue
        case .application: tint = .systemOrange
        }
        waveform.tint = tint
        meter.tint = tint
        let title = NSTextField(labelWithString: source.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        let iconView = NSImageView(image: icon ?? NSImage(systemSymbolName: source.id == "microphone" ? "mic.fill" : "speaker.wave.2.fill", accessibilityDescription: nil)!)
        iconView.contentTintColor = tint
        iconView.widthAnchor.constraint(equalToConstant: 20).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let spacer = NSView()
        badge.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        badge.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [iconView, title, spacer, badge])
        heading.spacing = 8
        heading.setHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        levels.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        levels.textColor = .secondaryLabelColor
        levels.alignment = .right
        levels.setContentCompressionResistancePriority(.required, for: .horizontal)
        let levelWidth = ceil(("RMS -120.0   PEAK -120.0 dBFS" as NSString).size(withAttributes: [.font: levels.font!]).width) + 4
        levels.widthAnchor.constraint(equalToConstant: levelWidth).isActive = true
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [status, footerSpacer, levels])
        footer.distribution = .fill
        let stack = NSStackView(views: [heading, waveform, meter, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            heading.heightAnchor.constraint(equalToConstant: 20),
            waveform.widthAnchor.constraint(equalTo: stack.widthAnchor),
            waveform.heightAnchor.constraint(equalToConstant: 84),
            meter.widthAnchor.constraint(equalTo: stack.widthAnchor),
            meter.heightAnchor.constraint(equalToConstant: 6),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.heightAnchor.constraint(equalToConstant: 15)
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel("\(source.title) audio activity")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ snapshot: AudioMeterSnapshot, capturing: Bool, message: String?,
                now: TimeInterval = AudioRecordingManager.hostSeconds) {
        waveform.snapshot = capturing ? snapshot : AudioMeterSnapshot()
        let activity = activityTracker.update(snapshot, capturing: capturing, now: now)
        let statusText = message ?? activity.title
        if status.stringValue != statusText { status.stringValue = statusText }
        let color: NSColor = message == nil && activity == .clipping ? .systemRed : .secondaryLabelColor
        if status.textColor != color { status.textColor = color }
        let showLevels = capturing && snapshot.hasRecentAudio(at: now)
        meter.rmsDB = showLevels ? snapshot.rmsDB : -120
        meter.peakDB = showLevels ? snapshot.peakDB : -120
        meter.needsDisplay = true
        let rms = showLevels && snapshot.rmsDB > -120 ? String(format: "%.1f", snapshot.rmsDB) : "--"
        let peak = showLevels && snapshot.peakDB > -120 ? String(format: "%.1f", snapshot.peakDB) : "--"
        let levelText = "RMS \(rms)   PEAK \(peak) dBFS"
        if levels.stringValue != levelText { levels.stringValue = levelText }
        let accessibilityText = "\(statusText). \(levelText)"
        if accessibilityValue() as? String != accessibilityText { setAccessibilityValue(accessibilityText) }
    }
}
