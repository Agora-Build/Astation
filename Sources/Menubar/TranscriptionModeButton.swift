import AppKit

enum TranscriptionMode: String, CaseIterable {
    case off, mic, system, all, apps
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .off: return "waveform.slash"
        case .mic: return "mic.fill"
        case .system: return "speaker.wave.2.fill"
        case .all: return "waveform"
        case .apps: return "app.badge.fill"
        }
    }
    func advanced(by steps: Int) -> Self {
        let modes = Self.allCases
        let index = modes.firstIndex(of: self)!
        return modes[((index + steps) % modes.count + modes.count) % modes.count]
    }
    static func selected(by ids: [String]) -> Self {
        if ids.isEmpty { return .off }
        if ids == ["microphone"] { return .mic }
        if ids == ["system"] { return .system }
        if ids.contains(where: { !["microphone", "system"].contains($0) }) { return .apps }
        return ids.contains("microphone") ? .all : .apps
    }
}

/// A preview is deliberately separate from capture intent: scrolling never acquires audio.
struct TranscriptionModeSelection {
    var selected: TranscriptionMode = .off
    private(set) var preview: TranscriptionMode?
    private var scrollDelta: CGFloat = 0
    private var scrollIsPrecise: Bool?
    var displayed: TranscriptionMode { preview ?? selected }
    mutating func scroll(delta: CGFloat, precise: Bool, momentum: Bool) {
        guard !momentum, delta.isFinite, delta != 0 else { return }
        if scrollIsPrecise != precise || scrollDelta * delta < 0 { scrollDelta = 0 }
        scrollIsPrecise = precise
        scrollDelta += delta
        if abs(scrollDelta) >= (precise ? 60 : 3) {
            preview = displayed.advanced(by: scrollDelta > 0 ? -1 : 1)
            scrollDelta = 0
        }
    }
    mutating func beginScrollGesture() { scrollDelta = 0; scrollIsPrecise = nil }
    mutating func advancePreview(by steps: Int) {
        preview = displayed.advanced(by: steps)
        beginScrollGesture()
    }
    mutating func resetPreview() { preview = nil; beginScrollGesture() }
    mutating func click() -> TranscriptionMode {
        let value = preview ?? selected.advanced(by: 1)
        resetPreview()
        return value
    }
}

final class TranscriptionModeButton: NSButton {
    private(set) var selection = TranscriptionModeSelection()
    private(set) var applications: [RecordingApplication] = []
    private var selectedTitle: String?
    var paused = false { didSet { updatePresentation() } }
    var changing = false { didSet { updatePresentation() } }
    var onSelect: ((TranscriptionMode) -> Void)?
    var onPreview: ((TranscriptionMode) -> Void)?
    var onReselectApps: (() -> Void)?
    var canApplyPreview: ((TranscriptionMode) -> Bool)?
    private var pendingApply: DispatchWorkItem?
    private var previewGeneration = UUID()
    override var intrinsicContentSize: NSSize { NSSize(width: 92, height: 28) }
    override var mouseDownCanMoveWindow: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        target = self; action = #selector(applyMode)
        setAccessibilityLabel("Transcription source")
        updatePresentation()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { pendingApply?.cancel() }
    func reflect(_ mode: TranscriptionMode, title: String? = nil, applications: [RecordingApplication] = []) {
        if selection.selected != mode {
            cancelPendingApply()
            selection.selected = mode; selection.resetPreview()
        }
        selectedTitle = title
        self.applications = applications
        updatePresentation()
    }
    override func scrollWheel(with event: NSEvent) {
        guard event.momentumPhase.isEmpty else { return }
        let previous = selection.displayed
        if event.phase.contains(.began) { selection.beginScrollGesture() }
        selection.scroll(delta: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
                         momentum: !event.momentumPhase.isEmpty)
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { selection.beginScrollGesture() }
        updatePresentation()
        if selection.displayed != previous { onPreview?(selection.displayed) }
        if event.phase.contains(.cancelled) { cancelPreview() }
        else if event.scrollingDeltaY != 0 { schedulePreviewApply() }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126: selection.advancePreview(by: -1)
        case 124, 125: selection.advancePreview(by: 1)
        case 53: cancelPreview(); return
        default: super.keyDown(with: event); return
        }
        updatePresentation()
        onPreview?(selection.displayed)
        schedulePreviewApply()
    }
    override func rightMouseDown(with event: NSEvent) {
        guard selection.displayed == .apps else { super.rightMouseDown(with: event); return }
        reselectApplications()
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), selection.displayed == .apps {
            reselectApplications()
        } else { super.mouseDown(with: event) }
    }
    private func reselectApplications() {
        cancelPendingApply()
        onReselectApps?()
        updatePresentation()
    }
    func cancelPreview() {
        cancelPendingApply()
        selection.resetPreview()
        updatePresentation()
        onPreview?(selection.displayed)
    }
    private func cancelPendingApply() {
        pendingApply?.cancel(); pendingApply = nil
        previewGeneration = UUID()
    }
    private func schedulePreviewApply() {
        cancelPendingApply()
        guard let mode = selection.preview else { return }
        let generation = previewGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.previewGeneration == generation, self.selection.preview == mode else { return }
            self.pendingApply = nil
            // Empty Apps selection waits for the picker; it must never fall back to system audio.
            if self.canApplyPreview?(mode) != false { self.applyMode() }
        }
        pendingApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
    @objc private func applyMode() {
        cancelPendingApply()
        let mode = selection.click()
        onSelect?(mode)
        updatePresentation()
    }
    private func updatePresentation() {
        title = selection.preview == nil ? selectedTitle ?? selection.displayed.title : selection.displayed.title
        let status = selection.preview != nil ? (canApplyPreview?(selection.displayed) == false ? "choose apps" : "applies after 1 second")
            : paused ? "paused for dictation" : changing ? "changing" : "selected"
        let apps = selection.displayed == .apps && !applications.isEmpty ? " (\(applications.map(\.name).joined(separator: ", ")))" : ""
        setAccessibilityValue("\(title)\(apps), \(status)")
        toolTip = "\(title)\(apps): \(status). Scroll to choose; applies after 1 second. Escape cancels. Click to cycle Off, Mic, System, All, Apps."
        if selection.displayed == .apps { toolTip! += " Right-click or Control-click to change apps." }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let mode = selection.displayed
        let accent: NSColor = mode == .off ? .white.withAlphaComponent(0.55) : .systemTeal
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        NSGradient(starting: accent.withAlphaComponent(0.17), ending: NSColor.black.withAlphaComponent(0.2))?.draw(in: shape, angle: -90)
        accent.withAlphaComponent(selection.preview == nil ? 0.35 : 0.8).setStroke()
        shape.lineWidth = 1; shape.stroke()
        let symbol = NSImage(systemSymbolName: mode.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [accent])))
        let showsApps = mode == .apps && !applications.isEmpty
        if showsApps {
            for (index, app) in applications.prefix(2).enumerated() {
                let icon = app.icon?.isTemplate == true ? app.icon?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [accent])) ?? app.icon : app.icon
                (icon ?? symbol)?.draw(in: NSRect(x: CGFloat(7 + index * 6), y: 6, width: 16, height: 16))
            }
        } else { symbol?.draw(in: NSRect(x: 8, y: 8, width: 13, height: 13)) }
        let includesMic = mode == .apps && selection.preview == nil && selectedTitle == "Apps + Mic"
        let label = includesMic ? "Apps" : title
        (label as NSString).draw(at: NSPoint(x: showsApps ? 33 : 27, y: 8), withAttributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ])
        let indicator = selection.preview != nil ? "circle.dotted" : paused ? "pause.fill" : changing ? "ellipsis" : includesMic ? "mic.fill" : "arrow.up.arrow.down"
        NSImage(systemSymbolName: indicator, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [paused ? .systemOrange : accent]))?
            .draw(in: NSRect(x: bounds.width - 21, y: 9, width: 10, height: 10))
    }
}
