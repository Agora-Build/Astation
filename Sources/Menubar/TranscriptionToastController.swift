import AppKit

final class TranscriptionCaptionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
private final class CaptionTextView: NSTextView {
    var copyPasteboard: NSPasteboard = .general
    override var mouseDownCanMoveWindow: Bool { false }
    override var needsPanelToBecomeKey: Bool { true }

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard isSelectable, range.length > 0, NSMaxRange(range) <= (string as NSString).length else { return }
        copyPasteboard.clearContents()
        copyPasteboard.setString((string as NSString).substring(with: range), forType: .string)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // A nonactivating panel must handle these even while another app owns the menu bar.
        if isSelectable, event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": copy(nil); return true
            case "a": selectAll(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isSelectable else { return nil }
        let menu = NSMenu()
        let copyItem = menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
        copyItem.target = self
        let selectAllItem = menu.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a")
        selectAllItem.target = self
        return menu
    }
}

/// A nonactivating caption surface. Only the initial placement is automatic;
/// dragging, including between monitors, owns its position thereafter.
final class TranscriptionToastController: NSObject, NSTextViewDelegate {
    private static let segmentKey = NSAttributedString.Key("AstationCaptionSegmentKey")
    private weak var manager: AudioTranscriptionManager?
    private var observer: NSObjectProtocol?
    private weak var dictation: VoiceDictationManager?
    private var dictationObserver: NSObjectProtocol?
    let polishKnob = PolishKnob(frame: .zero)
    private var timer: Timer?
    private(set) var panel: TranscriptionCaptionPanel?
    private let textView = CaptionTextView()
    private let scroll = NSScrollView()
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private var rendered: [TranscriptSegment] = []
    private var renderedWaitingMessage: String?
    private var waitingForCaption = false
    private let showWindow: Bool
    var isMonitoringCaptions: Bool { timer != nil }

    init(manager: AudioTranscriptionManager, showWindow: Bool = true, pasteboard: NSPasteboard = .general) {
        self.manager = manager
        self.showWindow = showWindow
        super.init()
        polishKnob.compact = true; polishKnob.target = self; polishKnob.action = #selector(togglePolish)
        textView.copyPasteboard = pasteboard
        observer = NotificationCenter.default.addObserver(forName: .transcriptionChanged, object: manager, queue: .main) { [weak self] notification in
            if notification.userInfo?["showFloatingCaptions"] as? Bool == true { self?.waitingForCaption = true }
            self?.refresh()
        }
    }
    deinit {
        timer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let dictationObserver { NotificationCenter.default.removeObserver(dictationObserver) }
        panel?.orderOut(nil)
        manager?.updateFloatingCaptionVisibility(false)
    }
    func attachDictation(_ dictation: VoiceDictationManager) {
        if let dictationObserver { NotificationCenter.default.removeObserver(dictationObserver) }
        self.dictation = dictation
        dictationObserver = NotificationCenter.default.addObserver(forName: .voiceDictationChanged, object: dictation, queue: .main) { [weak self] _ in self?.refreshPolishKnob() }
        refreshPolishKnob()
    }
    private func refreshPolishKnob() {
        polishKnob.state = dictation?.settings.polishing == true ? .on : .off
        polishKnob.isHidden = dictation == nil
        polishKnob.toolTip = dictation?.isPolishing == true ? "Polishing this utterance. Turning off affects the next finalized utterance."
            : "Polish microphone dictation with the selected LLM. Configure its model in Voice Dictation settings. Live system/app captions are unchanged."
    }
    @objc private func togglePolish() { dictation?.setPolishing(polishKnob.state == .on) }

    func refresh() {
        guard let manager else { return }
        manager.expireFloatingCaptions()
        let segments = manager.floatingCaptionBuffer.lines.map(\.segment)
        if !manager.settings.floatingCaptions { waitingForCaption = false }
        // An explicit Show must work even after every caption expired. Resume normal
        // 20-second auto-hide as soon as a real caption is displayed.
        if !segments.isEmpty { waitingForCaption = false }
        updateRefreshTimer(shouldRun: manager.settings.floatingCaptions
            && (manager.isActive || manager.isDictating || !segments.isEmpty || waitingForCaption))
        guard manager.settings.floatingCaptions, !segments.isEmpty || waitingForCaption else {
            panel?.orderOut(nil)
            textView.isSelectable = false
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            copyButton.isEnabled = false
            manager.updateFloatingCaptionVisibility(false)
            return
        }
        if panel == nil { createPanel() }
        let waitingMessage = segments.isEmpty ? (manager.isDictating ? "Listening for microphone dictation..." : manager.isActive
            ? "Waiting for speech from your selected sources..."
            : "Transcription is off. Start it in Live Transcription settings.") : nil
        if rendered != segments || renderedWaitingMessage != waitingMessage {
            rendered = segments
            renderedWaitingMessage = waitingMessage
            let content = waitingMessage.map { NSAttributedString(string: $0, attributes: [
                .font: NSFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.75)
            ]) } ?? Self.captionText(segments, sourceTitles: manager.sourceTitles)
            let selection = textView.textStorage.flatMap {
                Self.preservedSelection(textView.selectedRange(), from: $0, to: content)
            }
            textView.textStorage?.setAttributedString(content)
            textView.isSelectable = !segments.isEmpty
            textView.setSelectedRange(selection ?? NSRange(location: 0, length: 0))
            resizeToContent()
            if selection == nil { textView.scrollToEndOfDocument(nil) }
        }
        textView.isSelectable = !segments.isEmpty
        copyButton.isEnabled = !segments.isEmpty
        updateCopyTooltip()
        if showWindow { panel?.orderFrontRegardless() }
        manager.updateFloatingCaptionVisibility(true)
    }

    private func updateRefreshTimer(shouldRun: Bool) {
        if !shouldRun {
            timer?.invalidate(); timer = nil
        } else if timer == nil {
            // Keep watching while transcription is live, even when the empty panel is
            // hidden, so subsequent speech can restore it without a manual toggle.
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    static func captionText(_ segments: [TranscriptSegment], sourceTitles: [String: String] = [:]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.paragraphSpacing = 10
        for (index, segment) in segments.enumerated() {
            let source = sourceTitles.count > 1 ? "\(sourceTitles[segment.sourceID] ?? segment.sourceID)  " : ""
            let prefix = source + (segment.isTranslation ? "\(segment.language)  " : "")
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(NSAttributedString(string: prefix + segment.text, attributes: [
                segmentKey: segment.key,
                .font: NSFont.systemFont(ofSize: segment.isTranslation ? 17 : 20, weight: .medium),
                .foregroundColor: segment.isTranslation ? NSColor.systemTeal
                    : NSColor.white.withAlphaComponent(segment.isFinal ? 1 : 0.75),
                .paragraphStyle: paragraph
            ]))
        }
        return result
    }

    /// Anchor both ends to caption identities so updates or earlier expirations do
    /// not move a selection to unrelated words. Changed/expired selections clear.
    static func preservedSelection(_ selection: NSRange, from old: NSAttributedString, to new: NSAttributedString) -> NSRange? {
        guard selection.length > 0, selection.location != NSNotFound, NSMaxRange(selection) <= old.length else { return nil }
        func mappedIndex(_ index: Int) -> Int? {
            var oldRange = NSRange()
            guard let key = old.attribute(segmentKey, at: index, effectiveRange: &oldRange) as? String else { return nil }
            var match: NSRange?
            new.enumerateAttribute(segmentKey, in: NSRange(location: 0, length: new.length)) { value, range, stop in
                if value as? String == key { match = range; stop.pointee = true }
            }
            guard let match, index - oldRange.location < match.length else { return nil }
            return match.location + index - oldRange.location
        }
        guard let start = mappedIndex(selection.location), let end = mappedIndex(NSMaxRange(selection) - 1), end >= start else { return nil }
        let mapped = NSRange(location: start, length: end - start + 1)
        guard (old.string as NSString).substring(with: selection) == (new.string as NSString).substring(with: mapped) else { return nil }
        return mapped
    }

    func textViewDidChangeSelection(_ notification: Notification) { updateCopyTooltip() }

    private func updateCopyTooltip() {
        copyButton.toolTip = textView.selectedRange().length > 0
            ? "Copy selected caption text. You can also use Command-C or right-click > Copy."
            : "Copy all visible captions. Select words to copy only that text."
    }

    private func createPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = min(620, bounds.width - 48)
        let frame = NSRect(x: bounds.midX - width / 2, y: bounds.minY + 72, width: width, height: 140)
        let panel = TranscriptionCaptionPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Astation Live Captions"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.appearance = NSAppearance(named: .darkAqua)
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 16
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        panel.contentView = backdrop
        let header = NSTextField(labelWithString: "LIVE CAPTIONS")
        header.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        header.textColor = .systemTeal
        header.setAccessibilityLabel("Live captions. Drag this header to move the window to any display.")
        copyButton.target = self
        copyButton.action = #selector(copyCaptions)
        copyButton.bezelStyle = .inline
        copyButton.font = .systemFont(ofSize: 10)
        copyButton.contentTintColor = .white.withAlphaComponent(0.8)
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copyButton.imagePosition = .imageLeading
        copyButton.setAccessibilityLabel("Copy captions")
        let hide = NSButton(title: "Hide", target: self, action: #selector(hideCaptions))
        hide.bezelStyle = .inline
        hide.font = .systemFont(ofSize: 10)
        hide.contentTintColor = .white.withAlphaComponent(0.8)
        hide.toolTip = "Hide this window without stopping transcription. Use Show Floating Captions in the Astation menu or settings to restore it."
        polishKnob.compact = true
        polishKnob.target = self; polishKnob.action = #selector(togglePolish)
        refreshPolishKnob()
        let top = NSStackView(views: [header, NSView(), polishKnob, copyButton, hide])
        top.spacing = 10
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.delegate = self
        textView.selectedTextAttributes = [.backgroundColor: NSColor.systemTeal.withAlphaComponent(0.4), .foregroundColor: NSColor.white]
        textView.isContinuousSpellCheckingEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Transcription captions. Select text to copy words or passages.")
        scroll.documentView = textView
        for child in [top, scroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            backdrop.addSubview(child)
        }
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 20),
            top.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -20),
            top.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 12),
            top.heightAnchor.constraint(equalToConstant: 32),
            scroll.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -16)
        ])
        self.panel = panel
    }

    private func resizeToContent() {
        guard let panel else { return }
        let width = panel.frame.width - 40
        textView.frame.size.width = width
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        let contentHeight = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 40
        let limit = min(360, (panel.screen?.visibleFrame.height ?? 800) * 0.6)
        // Preserve the user's origin on any monitor as captions wrap or expire.
        var frame = panel.frame
        frame.size.height = min(limit, max(112, ceil(contentHeight) + 68))
        panel.setFrame(frame, display: true)
        textView.frame.size.height = contentHeight
    }
    @objc private func copyCaptions() {
        refresh()
        guard copyButton.isEnabled else { return }
        if textView.selectedRange().length > 0 {
            textView.copy(nil)
        } else {
            textView.copyPasteboard.clearContents()
            textView.copyPasteboard.setString(textView.string, forType: .string)
        }
    }
    @objc private func hideCaptions() { manager?.setFloatingCaptions(false) }
}
