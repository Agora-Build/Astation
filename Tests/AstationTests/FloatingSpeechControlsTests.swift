import AppKit
import XCTest
@testable import Menubar

private actor SpeechControlEngine: LiveTranscribing {
    let source: String
    var started = false
    var cancelled = false
    var cancelling = false
    var finishes = 0
    var consumed: [Float] = []
    private var callback: (@Sendable (TranscriptSegment) -> Void)?
    private var cancellationGate: CheckedContinuation<Void, Never>?
    var holdCancellation = false
    init(source: String = "microphone") { self.source = source }
    func start(onSegment: @escaping @Sendable (TranscriptSegment) -> Void) { started = true; callback = onSegment }
    func consume(_ samples: [Float]) { consumed.append(contentsOf: samples) }
    func finish() { finishes += 1 }
    func cancel() async {
        cancelling = true
        if holdCancellation { await withCheckedContinuation { cancellationGate = $0 } }
        cancelled = true
    }
    func hold() { holdCancellation = true }
    func release() { holdCancellation = false; cancellationGate?.resume(); cancellationGate = nil }
    func emit(_ text: String, id: String = "one", final: Bool = true) {
        callback?(TranscriptSegment(id: id, sourceID: source, language: "en-US", text: text, isFinal: final, offset: 0))
    }
}

private actor SpeechPreparationGate {
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class SpeechCaptureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(String, SharedTestMicrophone)] = []
    func make(_ source: AudioSourceSelection) -> NativeAudioCapturing {
        let capture = SharedTestMicrophone()
        lock.withLock { entries.append((source.id, capture)) }
        return capture
    }
    var ids: [String] { lock.withLock { entries.map { $0.0 } } }
    var captures: [SharedTestMicrophone] { lock.withLock { entries.map { $0.1 } } }
}

@MainActor
final class FloatingSpeechControlsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "astation-speech-control-\(UUID())"
        let storage = UserDefaults(suiteName: name)!
        addTeardownBlock { storage.removePersistentDomain(forName: name) }
        return storage
    }
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("astation-speech-files-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Speech control state did not settle")
    }
    private func waitAsync(_ predicate: () async -> Bool) async throws {
        for _ in 0..<300 { if await predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Speech control worker did not settle")
    }
    private func setup(_ log: SpeechCaptureLog, permission: @escaping () async -> Bool = { true }) -> AudioRecordingManager {
        let recorder = AudioRecordingManager(defaults: defaults(), captureFactory: { log.make($0) }, microphonePermission: permission)
        var recording = recorder.settings; recording.applicationBundleIDs = ["test.selected-app"]
        recorder.updateSettings(recording)
        return recorder
    }
    private func dictation(_ manager: AudioTranscriptionManager, engine: SpeechControlEngine,
                           permission: @escaping () async -> Bool = { true },
                           capture: @escaping (String?) throws -> NativeAudioCapturing = { _ in SharedTestMicrophone() }) -> VoiceDictationManager {
        let storage = defaults()
        var settings = DictationSettings(); settings.typeInActiveTextField = false
        storage.set(try! JSONEncoder().encode(settings), forKey: VoiceDictationManager.defaultsKey)
        return VoiceDictationManager(transcription: manager, captureFactory: capture, permission: permission,
            engineFactory: { engine }, showStatus: { _ in }, defaults: storage)
    }

    func testScrollOnlyPreviewsAndIgnoresMomentumUntilClick() {
        var selection = TranscriptionModeSelection()
        selection.scroll(delta: -30, precise: true, momentum: false)
        XCTAssertEqual(selection.displayed, .off)
        selection.scroll(delta: -30, precise: true, momentum: false)
        XCTAssertEqual(selection.displayed, .mic); XCTAssertEqual(selection.selected, .off)
        selection.scroll(delta: -80, precise: true, momentum: true)
        XCTAssertEqual(selection.displayed, .mic)
        XCTAssertEqual(selection.click(), .mic); XCTAssertNil(selection.preview)
        selection.selected = .mic
        XCTAssertEqual(selection.click(), .system)
        selection.selected = .off
        for _ in 0..<3 { selection.scroll(delta: 1, precise: false, momentum: false) }
        XCTAssertEqual(selection.click(), .apps)
    }

    func testSmallTrackpadMovementsAndSingleWheelNotchesDoNotChangePreview() {
        var selection = TranscriptionModeSelection()
        for _ in 0..<5 { selection.scroll(delta: -10, precise: true, momentum: false) }
        XCTAssertEqual(selection.displayed, .off)
        selection.scroll(delta: -10, precise: true, momentum: false)
        XCTAssertEqual(selection.displayed, .mic)
        selection.resetPreview()
        for _ in 0..<2 { selection.scroll(delta: -1, precise: false, momentum: false) }
        XCTAssertEqual(selection.displayed, .off)
        selection.scroll(delta: -1, precise: false, momentum: false)
        XCTAssertEqual(selection.displayed, .mic)
        XCTAssertEqual(selection.selected, .off)
    }

    func testReversingScrollDirectionRequiresFreshTravel() {
        var selection = TranscriptionModeSelection()
        selection.scroll(delta: -40, precise: true, momentum: false)
        selection.scroll(delta: 30, precise: true, momentum: false)
        XCTAssertEqual(selection.displayed, .off)
        selection.scroll(delta: 30, precise: true, momentum: false)
        XCTAssertEqual(selection.displayed, .apps)
    }

    func testNewGestureAndInputDeviceDiscardPartialScrollWithoutLosingPreview() {
        var selection = TranscriptionModeSelection()
        selection.scroll(delta: -40, precise: true, momentum: false)
        selection.beginScrollGesture()
        selection.scroll(delta: -30, precise: true, momentum: false)
        XCTAssertEqual(selection.displayed, .off)
        selection.scroll(delta: -30, precise: true, momentum: false)
        selection.beginScrollGesture()
        XCTAssertEqual(selection.displayed, .mic)
        selection.scroll(delta: -40, precise: true, momentum: false)
        selection.scroll(delta: -1, precise: false, momentum: false)
        XCTAssertEqual(selection.displayed, .mic)
    }

    private func scrollEvent(delta: Int32, momentum: Bool = false) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        if momentum { event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1) }
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func mouseEvent(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    }

    func testRightClickReopensAppsWithCurrentChecksAndOnlyUseAppsReplacesCapture() async throws {
        _ = NSApplication.shared
        let log = SpeechCaptureLog()
        let apps = [RecordingApplication(bundleID: "test.music", name: "Music", icon: nil, processIDs: []),
                    RecordingApplication(bundleID: "test.browser", name: "Browser", icon: nil, processIDs: [])]
        let recorder = AudioRecordingManager(defaults: defaults(), captureFactory: { log.make($0) },
            microphonePermission: { XCTFail("Apps must not request a microphone"); return false }, applicationCatalog: { apps })
        var recording = recorder.settings; recording.applicationBundleIDs = [apps[0].bundleID]; recorder.updateSettings(recording)
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { SpeechControlEngine(source: $0.sourceID) })
        let toast = TranscriptionToastController(manager: manager, showWindow: false)
        defer { manager.stop() }
        manager.selectMode(.apps); try await wait { manager.state == .running }
        toast.modeButton.rightMouseDown(with: try mouseEvent(.rightMouseDown))
        let picker = try XCTUnwrap(toast.appPicker)
        XCTAssertEqual(picker.appButtons[apps[0].bundleID]?.state, .on)
        XCTAssertEqual(picker.appButtons[apps[1].bundleID]?.state, .off)
        try XCTUnwrap(picker.appButtons[apps[0].bundleID]).performClick(nil)
        try XCTUnwrap(picker.appButtons[apps[1].bundleID]).performClick(nil)
        XCTAssertEqual(manager.settings.selectedSourceIDs, [apps[0].bundleID])
        XCTAssertEqual(log.ids, [apps[0].bundleID])
        picker.applyButton.performClick(nil)
        try await wait { manager.state == .running && manager.settings.selectedSourceIDs == [apps[1].bundleID] }
        XCTAssertEqual(log.ids, apps.map(\.bundleID))
        XCTAssertEqual(recorder.settings, recording)
        toast.modeButton.rightMouseDown(with: try mouseEvent(.rightMouseDown))
        let reopened = try XCTUnwrap(toast.appPicker)
        XCTAssertEqual(reopened.appButtons[apps[1].bundleID]?.state, .on)
        try XCTUnwrap(reopened.appButtons[apps[0].bundleID]).performClick(nil)
        reopened.onCancel?()
        XCTAssertNil(toast.appPicker)
        XCTAssertEqual(manager.settings.selectedSourceIDs, [apps[1].bundleID])
        XCTAssertEqual(log.ids, apps.map(\.bundleID))
    }

    func testControlClickAppsPreviewReopensPickerAndCancelsPendingAutomaticApply() async throws {
        _ = NSApplication.shared
        let recorder = setup(SpeechCaptureLog())
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { SpeechControlEngine(source: $0.sourceID) })
        let toast = TranscriptionToastController(manager: manager, showWindow: false)
        defer { manager.stop() }
        manager.selectMode(.mic); try await wait { manager.state == .running }
        for _ in 0..<3 { toast.modeButton.scrollWheel(with: try scrollEvent(delta: -60)) }
        XCTAssertEqual(toast.modeButton.selection.displayed, .apps)
        XCTAssertNil(toast.appPicker)
        toast.modeButton.mouseDown(with: try mouseEvent(.leftMouseDown, modifiers: .control))
        let picker = try XCTUnwrap(toast.appPicker)
        XCTAssertEqual(picker.appButtons["test.selected-app"]?.state, .on)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(manager.desiredMode, .mic)
        XCTAssertEqual(manager.settings.selectedSourceIDs, ["microphone"])
        picker.onCancel?()
        XCTAssertEqual(toast.modeButton.selection.displayed, .mic)
    }

    func testMicrophonePrefixStaysHiddenAcrossAllModesWithoutAnotherSegment() async throws {
        _ = NSApplication.shared
        let recorder = setup(SpeechCaptureLog())
        var engines: [SpeechControlEngine] = []
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: {
            let engine = SpeechControlEngine(source: $0.sourceID); engines.append(engine); return engine
        })
        let toast = TranscriptionToastController(manager: manager, showWindow: false)
        defer { manager.stop() }
        manager.selectMode(.all); try await wait { manager.state == .running }
        let microphone = try XCTUnwrap(engines.first { $0.source == "microphone" })
        await microphone.emit("Hello from my mic")
        try await wait { manager.floatingCaptionBuffer.lines.count == 1 }
        let content = try XCTUnwrap(toast.panel?.contentView)
        let text = try XCTUnwrap(content.subviews.compactMap { $0 as? NSScrollView }.first?.documentView as? NSTextView)
        XCTAssertEqual(text.string, "Hello from my mic")
        XCTAssertTrue(manager.sourceTitles.keys.contains("system"))
        for mode in TranscriptionMode.allCases {
            manager.selectMode(mode)
            XCTAssertEqual(text.string, "Hello from my mic")
            try await wait { mode == .off ? manager.state == .idle : manager.state == .running }
            XCTAssertEqual(text.string, "Hello from my mic")
        }
        let engine = SpeechControlEngine(), voice = dictation(manager, engine: engine)
        toast.attachDictation(voice)
        voice.startHandsFree(); try await waitAsync { await engine.started }
        XCTAssertEqual(text.string, "Hello from my mic")
        voice.cancel(); try await wait { !manager.isDictating }
        XCTAssertEqual(text.string, "Hello from my mic")
    }

    private func captionViews(_ toast: TranscriptionToastController) throws -> (NSScrollView, NSTextView) {
        let content = try XCTUnwrap(toast.panel?.contentView)
        content.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(content.subviews.compactMap { $0 as? NSScrollView }.first)
        return (scroll, try XCTUnwrap(scroll.documentView as? NSTextView))
    }

    private func scrollCaptions(_ scroll: NSScrollView, delta: Int32) async throws {
        scroll.scrollWheel(with: try scrollEvent(delta: delta))
        var previous = scroll.contentView.bounds.origin, settled = 0
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 10_000_000)
            let current = scroll.contentView.bounds.origin
            settled = current == previous ? settled + 1 : 0
            previous = current
            if settled >= 5 { return }
        }
        XCTFail("Native caption scrolling did not settle")
    }

    func testManualCaptionScrollHoldsSnapshotFor15SecondsAndResumesWithoutNewSpeech() async throws {
        _ = NSApplication.shared
        let recorder = setup(SpeechCaptureLog()), engine = SpeechControlEngine()
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { _ in engine })
        var now: TimeInterval = 100
        let toast = TranscriptionToastController(manager: manager, showWindow: false, clock: { now })
        defer { manager.stop() }
        manager.selectMode(.mic); try await wait { manager.state == .running }
        await engine.emit(Array(repeating: "Earlier caption for review.", count: 40).joined(separator: "\n"))
        try await wait { manager.floatingCaptionBuffer.lines.count == 1 }
        let (scroll, text) = try captionViews(toast)
        XCTAssertGreaterThan(text.bounds.height, scroll.contentView.bounds.height)
        try await scrollCaptions(scroll, delta: 60)
        let position = scroll.contentView.bounds.origin, snapshot = text.string
        XCTAssertLessThan(scroll.contentView.bounds.maxY, text.bounds.maxY - 1)
        text.setSelectedRange((text.string as NSString).range(of: "Earlier caption"))
        await engine.emit("Latest speech arrives while reviewing.", id: "latest")
        try await wait { manager.floatingCaptionBuffer.lines.count == 2 }
        XCTAssertEqual(text.string, snapshot)
        XCTAssertEqual(scroll.contentView.bounds.origin, position)
        now = 114.999; toast.refresh()
        XCTAssertEqual(text.string, snapshot)
        now = 115; toast.refresh()
        XCTAssertTrue(text.string.contains("Latest speech arrives while reviewing."))
        try await wait { abs(scroll.contentView.bounds.maxY - text.bounds.maxY) <= 1 }
        XCTAssertEqual(scroll.contentView.bounds.maxY, text.bounds.maxY, accuracy: 1)
        XCTAssertGreaterThan(text.selectedRange().length, 0)
    }

    func testDictationScrollResetsReviewTimeoutAndReturningToBottomResumesImmediately() async throws {
        _ = NSApplication.shared
        let recorder = setup(SpeechCaptureLog()), manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults())
        let engine = SpeechControlEngine(), voice = dictation(manager, engine: engine)
        var now: TimeInterval = 100
        let toast = TranscriptionToastController(manager: manager, showWindow: false, clock: { now })
        toast.attachDictation(voice)
        defer { voice.cancel() }
        voice.startHandsFree(); try await waitAsync { await engine.started }
        await engine.emit(Array(repeating: "Dictation caption for review.", count: 40).joined(separator: "\n"))
        try await wait { manager.floatingCaptionBuffer.lines.count == 1 }
        let (scroll, text) = try captionViews(toast)
        try await scrollCaptions(scroll, delta: 60)
        now = 108; try await scrollCaptions(scroll, delta: 60)
        let snapshot = text.string
        await engine.emit("New dictation while reading.", id: "latest")
        try await wait { manager.floatingCaptionBuffer.lines.count == 2 }
        now = 115; toast.refresh()
        XCTAssertEqual(text.string, snapshot, "A second scroll starts a fresh 15-second review")
        now = 122.999; toast.refresh()
        XCTAssertEqual(text.string, snapshot)
        try await scrollCaptions(scroll, delta: -10_000)
        XCTAssertTrue(text.string.contains("New dictation while reading."))
        XCTAssertEqual(scroll.contentView.bounds.maxY, text.bounds.maxY, accuracy: 1)
        try await scrollCaptions(scroll, delta: -60)
        await engine.emit("Dictation continues at the bottom.", id: "third")
        try await wait { manager.floatingCaptionBuffer.lines.count == 3 }
        XCTAssertTrue(text.string.contains("Dictation continues at the bottom."))
    }

    func testReviewTimeoutDoesNotJumpAfterCaptureStopsAndHideClearsReview() async throws {
        _ = NSApplication.shared
        let recorder = setup(SpeechCaptureLog()), engine = SpeechControlEngine()
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { _ in engine })
        var now: TimeInterval = 100
        let toast = TranscriptionToastController(manager: manager, showWindow: false, clock: { now })
        defer { manager.stop() }
        manager.selectMode(.mic); try await wait { manager.state == .running }
        await engine.emit(Array(repeating: "Caption history for review.", count: 40).joined(separator: "\n"))
        try await wait { manager.floatingCaptionBuffer.lines.count == 1 }
        let (scroll, text) = try captionViews(toast)
        try await scrollCaptions(scroll, delta: 60)
        let position = scroll.contentView.bounds.origin
        manager.stop(); try await wait { manager.state == .idle }
        now = 115; toast.refresh()
        XCTAssertEqual(scroll.contentView.bounds.origin, position)
        try await scrollCaptions(scroll, delta: 60)
        manager.setFloatingCaptions(false)
        XCTAssertFalse(toast.isMonitoringCaptions)
        manager.displayDictationCaption(TranscriptSegment(id: "new", sourceID: "microphone", language: "en-US", text: "Speech after hiding", isFinal: true, offset: 0))
        manager.setFloatingCaptions(true)
        XCTAssertTrue(text.string.contains("Speech after hiding"))
        try await wait { abs(scroll.contentView.bounds.maxY - text.bounds.maxY) <= 1 }
        XCTAssertEqual(scroll.contentView.bounds.maxY, text.bounds.maxY, accuracy: 1)
    }

    func testMicAutomaticallyAppliesAfterDelayAndNeverReturnsToAll() async throws {
        _ = NSApplication.shared
        let log = SpeechCaptureLog(), recorder = setup(log)
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { SpeechControlEngine(source: $0.sourceID) })
        let toast = TranscriptionToastController(manager: manager, showWindow: false)
        defer { manager.stop() }
        manager.selectMode(.all); try await wait { manager.state == .running }
        let scroll = try scrollEvent(delta: 60)
        XCTAssertTrue(scroll.hasPreciseScrollingDeltas)
        toast.modeButton.scrollWheel(with: scroll); toast.modeButton.scrollWheel(with: scroll)
        XCTAssertEqual(toast.modeButton.selection.displayed, .mic)
        try await Task.sleep(nanoseconds: 550_000_000)
        toast.refresh()
        XCTAssertEqual(toast.modeButton.selection.displayed, .mic)
        XCTAssertEqual(toast.modeButton.title, "Mic")
        XCTAssertEqual(manager.desiredMode, .all, "Preview must not change capture")
        XCTAssertEqual(Set(log.ids), ["microphone", "system"])
        let momentum = try scrollEvent(delta: -600, momentum: true)
        XCTAssertFalse(momentum.momentumPhase.isEmpty)
        toast.modeButton.scrollWheel(with: momentum)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(manager.desiredMode, .mic, "Momentum must not restart the one-second delay")
        try await wait { manager.state == .running && manager.desiredMode == .mic }
        try await Task.sleep(nanoseconds: 3_250_000_000)
        toast.refresh()
        XCTAssertEqual(toast.modeButton.selection.displayed, .mic)
        XCTAssertEqual(toast.modeButton.selection.selected, .mic)
        XCTAssertEqual(manager.settings.selectedSourceIDs, ["microphone"])
    }

    func testAutomaticApplyWaitsForLastScrollAndExternalModeChangesCancelIt() async throws {
        let button = TranscriptionModeButton(frame: .zero)
        var applied: [TranscriptionMode] = []
        button.onSelect = { [weak button] mode in applied.append(mode); button?.reflect(mode) }
        button.reflect(.all)
        button.scrollWheel(with: try scrollEvent(delta: 60))
        try await Task.sleep(nanoseconds: 600_000_000)
        button.scrollWheel(with: try scrollEvent(delta: 60))
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(applied.isEmpty)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(applied, [.mic])
        button.scrollWheel(with: try scrollEvent(delta: -60))
        button.reflect(.off)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(applied, [.mic])
        XCTAssertEqual(button.selection.displayed, .off)
    }

    func testEscapeCancelsPreviewWithoutChangingCaptureIntent() throws {
        let button = TranscriptionModeButton(frame: .zero)
        button.reflect(.all)
        button.scrollWheel(with: try scrollEvent(delta: 120))
        XCTAssertEqual(button.selection.displayed, .system)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
        button.keyDown(with: escape)
        XCTAssertEqual(button.selection.displayed, .all)
        XCTAssertNil(button.selection.preview)
    }

    func testEmptyAppsPreviewOpensPickerAndApplyingPreservesIndependentRecording() async throws {
        _ = NSApplication.shared
        let log = SpeechCaptureLog(), storage = defaults(), root = try folder()
        let icon = try XCTUnwrap(NSImage(systemSymbolName: "music.note", accessibilityDescription: nil))
        let app = RecordingApplication(bundleID: "test.music", name: "Music", icon: icon, processIDs: [])
        var permissions = 0
        let recorder = AudioRecordingManager(defaults: defaults(), captureFactory: { log.make($0) },
            microphonePermission: { permissions += 1; return true }, applicationCatalog: { [app] })
        var recording = recorder.settings; recording.folderPath = root.path
        recorder.updateSettings(recording)
        recorder.startRecording(); try await wait { recorder.isRecording }
        let original = recorder.settings
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: storage, engineFactory: { SpeechControlEngine(source: $0.sourceID) })
        let toast = TranscriptionToastController(manager: manager, showWindow: false)
        defer { manager.stop(); recorder.shutdown() }
        manager.setFloatingCaptions(true)
        toast.modeButton.scrollWheel(with: try scrollEvent(delta: 60))
        XCTAssertEqual(toast.modeButton.selection.displayed, .apps)
        let picker = try XCTUnwrap(toast.appPicker)
        XCTAssertFalse(picker.applyButton.isEnabled)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(toast.modeButton.selection.displayed, .apps, "Wait for app selection instead of applying an empty source")
        XCTAssertEqual(manager.desiredMode, .off)
        XCTAssertEqual(log.ids, ["microphone"])
        try XCTUnwrap(picker.appButtons[app.bundleID]).performClick(nil)
        XCTAssertTrue(picker.applyButton.isEnabled)
        if let path = ProcessInfo.processInfo.environment["ASTATION_APP_PICKER_SNAPSHOT"] {
            picker.view.frame = NSRect(origin: .zero, size: picker.preferredContentSize)
            picker.view.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(picker.view.bitmapImageRepForCachingDisplay(in: picker.view.bounds))
            picker.view.cacheDisplay(in: picker.view.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
        XCTAssertTrue(manager.selectedApplicationIDs.isEmpty, "Checkbox edits must wait for Use Apps")
        picker.applyButton.performClick(nil)
        try await wait { manager.state == .running }
        XCTAssertNil(toast.appPicker)
        XCTAssertEqual(manager.desiredMode, .apps)
        XCTAssertEqual(manager.settings.selectedSourceIDs, [app.bundleID])
        XCTAssertEqual(permissions, 1, "Only the original recording acquires its microphone")
        XCTAssertEqual(log.ids, ["microphone", app.bundleID])
        XCTAssertEqual(recorder.settings, original)
        XCTAssertTrue(recorder.isRecording)
        XCTAssertTrue(toast.modeButton.applications.first?.icon === icon)
        let restored = AudioTranscriptionManager(recorder: recorder, defaults: storage)
        XCTAssertEqual(restored.selectedApplicationIDs, [app.bundleID])
        XCTAssertEqual(try restored.settings(for: .apps).selectedSourceIDs, [app.bundleID])
    }

    func testSavedAppsSkipPickerAndUpdateIconsInCompactButton() throws {
        _ = NSApplication.shared
        let firstIcon = try XCTUnwrap(NSImage(systemSymbolName: "music.note", accessibilityDescription: nil))
        let nextIcon = try XCTUnwrap(NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil))
        var icon = firstIcon
        let recorder = AudioRecordingManager(defaults: defaults(), applicationCatalog: {
            [RecordingApplication(bundleID: "test.music", name: "Music", icon: icon, processIDs: [])]
        })
        var recording = recorder.settings; recording.applicationBundleIDs = ["test.music"]; recorder.updateSettings(recording)
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults())
        let toast = TranscriptionToastController(manager: manager, showWindow: false)
        manager.setFloatingCaptions(true)
        toast.modeButton.scrollWheel(with: try scrollEvent(delta: 60))
        XCTAssertEqual(toast.modeButton.selection.displayed, .apps)
        XCTAssertNil(toast.appPicker)
        XCTAssertTrue(toast.modeButton.applications.first?.icon === firstIcon)
        icon = nextIcon; manager.refreshApplicationChoices(); toast.refresh()
        XCTAssertTrue(toast.modeButton.applications.first?.icon === nextIcon)
        XCTAssertEqual(toast.modeButton.selection.displayed, .apps)
        XCTAssertEqual(toast.modeButton.intrinsicContentSize, NSSize(width: 92, height: 28))
        XCTAssertTrue((toast.modeButton.accessibilityValue() as? String)?.contains("Music") == true)
        if let path = ProcessInfo.processInfo.environment["ASTATION_APPS_TOAST_SNAPSHOT"], let view = toast.panel?.contentView {
            view.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    func testFloatingPolishIsOnlyAvailableDuringDictationAndHidesOnResume() async throws {
        _ = NSApplication.shared
        let recorder = setup(SpeechCaptureLog())
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { SpeechControlEngine(source: $0.sourceID) })
        let toast = TranscriptionToastController(manager: manager, showWindow: false)
        defer { manager.stop() }
        for mode in TranscriptionMode.allCases {
            manager.selectMode(mode)
            if mode != .off { try await wait { manager.state == .running } }
            for handsFree in [false, true] {
                let engine = SpeechControlEngine(), voice = dictation(manager, engine: engine)
                toast.attachDictation(voice)
                XCTAssertTrue(toast.polishKnob.isHidden); XCTAssertFalse(toast.polishKnob.isEnabled)
                if handsFree { voice.startHandsFree() } else { voice.startPTT() }
                try await waitAsync { await engine.started }
                XCTAssertFalse(toast.polishKnob.isHidden); XCTAssertTrue(toast.polishKnob.isEnabled)
                toast.polishKnob.performClick(nil)
                XCTAssertTrue(voice.settings.polishing)
                voice.cancel()
                try await wait { mode == .off ? !manager.isDictating : manager.state == .running }
                XCTAssertTrue(toast.polishKnob.isHidden); XCTAssertFalse(toast.polishKnob.isEnabled)
            }
        }
    }

    func testRetiringStoppedDictationManagerDoesNotReleaseAnotherActiveSession() async throws {
        let recorder = setup(SpeechCaptureLog())
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { SpeechControlEngine(source: $0.sourceID) })
        var retired: VoiceDictationManager? = dictation(manager, engine: SpeechControlEngine())
        retired?.cancel()
        let engine = SpeechControlEngine(), active = dictation(manager, engine: engine)
        defer { active.cancel() }
        active.startHandsFree(); try await waitAsync { await engine.started }
        XCTAssertTrue(manager.isDictating)
        retired = nil
        XCTAssertTrue(manager.isDictating, "A stopped manager no longer owns dictation priority")
    }

    func testEveryModeCapturesExactSourcesWithoutChangingRecordingSettings() async throws {
        for (mode, ids) in [(TranscriptionMode.mic, ["microphone"]), (.system, ["system"]),
                            (.all, ["microphone", "system"]), (.apps, ["test.selected-app"])] {
            let log = SpeechCaptureLog(); var permissions = 0
            let recorder = setup(log, permission: { permissions += 1; return true })
            let original = recorder.settings
            let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { SpeechControlEngine(source: $0.sourceID) })
            manager.selectMode(mode); try await wait { manager.state == .running }
            XCTAssertEqual(Set(log.ids), Set(ids))
            XCTAssertEqual(permissions, ids.contains("microphone") ? 1 : 0)
            XCTAssertEqual(recorder.settings, original)
            manager.selectMode(.off); try await wait { manager.state == .idle }
            XCTAssertTrue(log.captures.allSatisfy { $0.stopCount == 1 })
            XCTAssertEqual(manager.desiredMode, .off)
        }
    }
    func testManualMicPlusAppsSelectionClearlyShowsMicrophoneAndNeverSaysAllSystem() async throws {
        let log = SpeechCaptureLog(), recorder = setup(log)
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { SpeechControlEngine(source: $0.sourceID) })
        var settings = manager.settings; settings.additionalSourceIDs = ["test.selected-app"]; manager.updateSettings(settings)
        manager.start(); try await wait { manager.state == .running }
        XCTAssertEqual(manager.desiredMode, .apps); XCTAssertEqual(manager.sourceButtonTitle, "Apps + Mic")
        XCTAssertEqual(Set(log.ids), ["microphone", "test.selected-app"])
        manager.stop(); try await wait { manager.state == .idle }
    }

    func testAppsWithNoSavedSelectionGivesGuidanceWithoutOpeningCapture() {
        let log = SpeechCaptureLog()
        let recorder = setup(log)
        var value = recorder.settings; value.applicationBundleIDs = []; recorder.updateSettings(value)
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { SpeechControlEngine(source: $0.sourceID) })
        manager.selectMode(.apps)
        XCTAssertEqual(manager.desiredMode, .off); XCTAssertTrue(log.ids.isEmpty)
        XCTAssertTrue(manager.message?.contains("Choose applications") == true)
    }

    func testBothDictationModesPreemptEverySourceAndResumeFreshCapture() async throws {
        for mode in [TranscriptionMode.mic, .system, .all, .apps] {
            for handsFree in [false, true] {
                let log = SpeechCaptureLog(), recorder = setup(log)
                let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { SpeechControlEngine(source: $0.sourceID) })
                manager.selectMode(mode); try await wait { manager.state == .running }
                let captures = log.captures, count = log.ids.count
                let engine = SpeechControlEngine(), voice = dictation(manager, engine: engine)
                if handsFree { voice.startHandsFree() } else { voice.startPTT() }
                try await waitAsync { await engine.started }
                XCTAssertTrue(manager.isDictating); XCTAssertFalse(manager.isActive)
                XCTAssertEqual(manager.desiredMode, mode)
                XCTAssertTrue(captures.allSatisfy { $0.stopCount == 1 })
                try await Task.sleep(nanoseconds: 50_000_000)
                XCTAssertEqual(log.ids.count, count, "Quiet Hands-Free must not resume transcription")
                if handsFree { voice.stopHandsFree() } else { voice.stopPTT() }
                try await wait { manager.state == .running && voice.mode == .off }
                XCTAssertGreaterThan(log.ids.count, count); XCTAssertFalse(manager.isDictating)
                manager.stop(); try await wait { manager.state == .idle }
            }
        }
    }

    func testPauseRejectsLateCallbacksAndPreservesTranscriptAndSameSavedHistory() async throws {
        let log = SpeechCaptureLog(), recorder = setup(log), root = try folder()
        var engines: [SpeechControlEngine] = []
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: {
            let engine = SpeechControlEngine(source: $0.sourceID); engines.append(engine); return engine
        })
        var settings = manager.settings; settings.autoSaveTranscript = true; settings.transcriptFolderPath = root.path
        manager.updateSettings(settings); manager.start(); try await wait { manager.state == .running }
        let first = try XCTUnwrap(engines.first)
        await first.emit("Before dictation"); try await wait { manager.transcript.segments.count == 1 }
        let saved = try XCTUnwrap(manager.lastTranscriptFolder)
        let engine = SpeechControlEngine(), voice = dictation(manager, engine: engine)
        voice.startHandsFree(); try await waitAsync { await engine.started }
        await first.emit("Late old callback", id: "late")
        voice.stopHandsFree(); try await wait { manager.state == .running && engines.count == 2 }
        await engines[1].emit("After dictation")
        try await wait { manager.transcript.segments.count == 2 }
        XCTAssertEqual(manager.transcript.segments.map(\.text), ["Before dictation", "After dictation"])
        XCTAssertEqual(manager.lastTranscriptFolder, saved)
        manager.stop(); try await wait { manager.state == .idle }
        let text = try String(contentsOf: saved.appendingPathComponent("transcript.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("Before dictation")); XCTAssertTrue(text.contains("After dictation"))
        XCTAssertFalse(text.contains("Late old callback"))
    }

    func testPendingModeChangeDuringDictationAndOffPreventUnwantedCaptures() async throws {
        for next in [TranscriptionMode.system, .apps, .off] {
            let log = SpeechCaptureLog(), recorder = setup(log)
            let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { SpeechControlEngine(source: $0.sourceID) })
            manager.selectMode(.mic); try await wait { manager.state == .running }
            let engine = SpeechControlEngine(), voice = dictation(manager, engine: engine)
            voice.startHandsFree(); try await waitAsync { await engine.started }
            manager.selectMode(next)
            XCTAssertEqual(manager.desiredMode, next); XCTAssertEqual(log.ids, ["microphone"])
            voice.cancel()
            try await wait { next == .off ? !manager.isActive : manager.state == .running }
            XCTAssertEqual(log.ids, next == .off ? ["microphone"] : ["microphone", next == .system ? "system" : "test.selected-app"])
            manager.stop(); try await wait { manager.state == .idle }
        }
    }

    func testPTTReleaseDuringDelayedSuspensionNeverOpensDictationMicrophone() async throws {
        let log = SpeechCaptureLog(), recorder = setup(log), held = SpeechControlEngine()
        await held.hold()
        var creations = 0, microphoneStarts = 0
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { _ in
            creations += 1; return creations == 1 ? held : SpeechControlEngine()
        })
        manager.start(); try await wait { manager.state == .running }
        let engine = SpeechControlEngine()
        let voice = dictation(manager, engine: engine, capture: { _ in microphoneStarts += 1; return SharedTestMicrophone() })
        voice.startPTT(); try await waitAsync { await held.cancelling }
        voice.stopPTT()
        await held.release()
        try await wait { voice.mode == .off && manager.state == .running }
        XCTAssertEqual(microphoneStarts, 0)
        manager.stop(); try await wait { manager.state == .idle }
    }

    func testPermissionFailureAndCancellationResumeRememberedMode() async throws {
        for deny in [false, true] {
            let log = SpeechCaptureLog(), recorder = setup(log)
            let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { SpeechControlEngine(source: $0.sourceID) })
            manager.selectMode(.system); try await wait { manager.state == .running }
            let voice = dictation(manager, engine: SpeechControlEngine(), permission: { !deny })
            voice.startHandsFree()
            if !deny { voice.cancel() }
            try await wait { voice.mode == .off && manager.state == .running && log.ids.count == 2 }
            XCTAssertEqual(manager.desiredMode, .system)
            manager.stop(); try await wait { manager.state == .idle }
        }
    }

    func testDictationCaptureSetupFailureReleasesPriorityAndResumes() async throws {
        let log = SpeechCaptureLog(), recorder = setup(log)
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { SpeechControlEngine(source: $0.sourceID) })
        manager.selectMode(.apps); try await wait { manager.state == .running }
        let voice = dictation(manager, engine: SpeechControlEngine(), capture: { _ in throw AudioCaptureError.message("Test setup failure") })
        voice.startPTT()
        try await wait { voice.mode == .off && manager.state == .running && log.ids.count == 2 }
        XCTAssertEqual(voice.message, "Test setup failure")
        manager.stop(); try await wait { manager.state == .idle }
    }

    func testCancellationDuringDelayedTranscriptionPreparationCannotOpenStaleCapture() async throws {
        let log = SpeechCaptureLog(), recorder = setup(log), gate = SpeechPreparationGate()
        let old = SpeechControlEngine(); var creations = 0, microphoneStarts = 0
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { _ in
            creations += 1
            if creations == 1 { await gate.wait(); return old }
            return SpeechControlEngine()
        })
        manager.start(); try await waitAsync { await gate.waiting }
        let voice = dictation(manager, engine: SpeechControlEngine(), capture: { _ in microphoneStarts += 1; return SharedTestMicrophone() })
        voice.startPTT(); voice.cancel()
        await gate.release()
        try await wait { manager.state == .running }
        XCTAssertEqual(microphoneStarts, 0); XCTAssertEqual(log.ids, ["microphone"])
        let cancelled = await old.cancelled; XCTAssertTrue(cancelled)
        manager.stop(); try await wait { manager.state == .idle }
    }

    func testResumeNeverConsumesAudioTimestampedDuringPauseFromSharedRecording() async throws {
        let log = SpeechCaptureLog(), recorder = setup(log)
        var recording = recorder.settings; recording.folderPath = try folder().path; recorder.updateSettings(recording)
        recorder.startRecording(); try await wait { recorder.isRecording }
        let capture = try XCTUnwrap(log.captures.first)
        var engines: [SpeechControlEngine] = []
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: {
            let engine = SpeechControlEngine(source: $0.sourceID); engines.append(engine); return engine
        })
        manager.start(); try await wait { manager.state == .running }
        let engine = SpeechControlEngine(), voice = dictation(manager, engine: engine)
        voice.startHandsFree(); try await waitAsync { await engine.started }
        let oldTime = mach_absolute_time()
        voice.cancel(); try await wait { manager.state == .running && engines.count == 2 }
        capture.feed([0.9], time: oldTime)
        try await Task.sleep(nanoseconds: 70_000_000)
        capture.feed([0.25])
        try await waitAsync { await !engines[1].consumed.isEmpty }
        let samples = await engines[1].consumed
        XCTAssertTrue(samples.allSatisfy { abs($0) < 0.5 }, "Samples captured during the pause must never enter the resumed ASR")
        manager.stop(); try await wait { manager.state == .idle }; recorder.stopRecording()
    }

    func testDisablingAutoSaveWhileDictatingClosesTheSavedHistory() async throws {
        let log = SpeechCaptureLog(), recorder = setup(log), root = try folder()
        var engines: [SpeechControlEngine] = []
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: {
            let engine = SpeechControlEngine(source: $0.sourceID); engines.append(engine); return engine
        })
        var settings = manager.settings; settings.autoSaveTranscript = true; settings.transcriptFolderPath = root.path
        manager.updateSettings(settings); manager.start(); try await wait { manager.state == .running }
        await engines[0].emit("Save before pause"); try await wait { manager.transcript.segments.count == 1 }
        let saved = try XCTUnwrap(manager.lastTranscriptFolder)
        let engine = SpeechControlEngine(), voice = dictation(manager, engine: engine)
        voice.startHandsFree(); try await waitAsync { await engine.started }
        settings.autoSaveTranscript = false; manager.updateSettings(settings)
        voice.cancel(); try await wait { manager.state == .running && engines.count == 2 }
        await engines[1].emit("Do not save after pause"); try await wait { manager.transcript.segments.count == 2 }
        manager.stop(); try await wait { manager.state == .idle }
        let text = try String(contentsOf: saved.appendingPathComponent("transcript.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("Save before pause")); XCTAssertFalse(text.contains("Do not save after pause"))
    }

    func testIndependentRecordingContinuesWhenSelectingMissingSourceAndDictating() async throws {
        let log = SpeechCaptureLog(), recorder = setup(log)
        var settings = recorder.settings; settings.folderPath = try folder().path; recorder.updateSettings(settings)
        recorder.startRecording(); try await wait { recorder.isRecording }
        let original = try XCTUnwrap(log.captures.first)
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { SpeechControlEngine(source: $0.sourceID) })
        manager.selectMode(.system); try await wait { manager.state == .running }
        let voice = dictation(manager, engine: SpeechControlEngine())
        voice.startHandsFree(); try await wait { manager.isDictating && !manager.isActive }
        XCTAssertTrue(recorder.isRecording); XCTAssertEqual(original.stopCount, 0)
        manager.selectMode(.off); voice.cancel()
        XCTAssertTrue(recorder.isRecording); XCTAssertEqual(original.stopCount, 0)
        recorder.stopRecording()
        XCTAssertEqual(original.stopCount, 1)
    }

    func testRapidModeChangesOnlyStartLatestSelection() async throws {
        let log = SpeechCaptureLog(), recorder = setup(log)
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { SpeechControlEngine(source: $0.sourceID) })
        manager.selectMode(.mic); manager.selectMode(.all); manager.selectMode(.apps); manager.selectMode(.system)
        try await wait { manager.state == .running }
        XCTAssertEqual(log.ids, ["system"]); XCTAssertEqual(manager.desiredMode, .system)
        manager.stop(); try await wait { manager.state == .idle }
    }

    func testRemoteConsentIsBoundToSourcesAndResumeReusesOnlySameContext() async throws {
        let log = SpeechCaptureLog(), recorder = setup(log)
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { SpeechControlEngine(source: $0.sourceID) })
        var settings = manager.settings; settings.provider = .agora; manager.updateSettings(settings)
        manager.selectMode(.system)
        XCTAssertTrue(log.ids.isEmpty); XCTAssertEqual(manager.desiredMode, .off)
        manager.selectMode(.system, cloudConsent: true); try await wait { manager.state == .running }
        let voice = dictation(manager, engine: SpeechControlEngine())
        voice.startHandsFree(); try await wait { manager.isDictating && !manager.isActive }
        XCTAssertFalse(manager.requiresConsent(for: try manager.settings(for: .system)))
        XCTAssertTrue(manager.requiresConsent(for: try manager.settings(for: .all)))
        manager.selectMode(.all)
        XCTAssertEqual(manager.desiredMode, .system)
        voice.cancel(); try await wait { manager.state == .running && log.ids.count == 2 }
        XCTAssertEqual(log.ids, ["system", "system"])
        manager.stop(); try await wait { manager.state == .idle }
    }

    func testOffKeepsFloatingControlAvailableUntilHide() throws {
        _ = NSApplication.shared
        let recorder = setup(SpeechCaptureLog()), manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults())
        let toast = TranscriptionToastController(manager: manager, showWindow: false)
        manager.selectMode(.off); toast.refresh()
        XCTAssertNotNil(toast.panel); XCTAssertTrue(manager.floatingCaptionsVisible)
        XCTAssertEqual(toast.modeButton.selection.selected, .off)
        XCTAssertFalse(toast.modeButton.needsPanelToBecomeKey)
        manager.setFloatingCaptions(false)
        XCTAssertFalse(manager.floatingCaptionsVisible)
    }
    func testFloatingButtonPreviewsWithoutCaptureAndShowsDictationWhilePaused() async throws {
        _ = NSApplication.shared
        let log = SpeechCaptureLog(), recorder = setup(log)
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { SpeechControlEngine(source: $0.sourceID) })
        let toast = TranscriptionToastController(manager: manager, showWindow: false)
        let engine = SpeechControlEngine(), voice = dictation(manager, engine: engine)
        toast.attachDictation(voice); manager.setFloatingCaptions(true)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125))
        toast.modeButton.keyDown(with: event); toast.modeButton.keyDown(with: event)
        XCTAssertEqual(toast.modeButton.selection.displayed, .system)
        XCTAssertEqual(manager.desiredMode, .off); XCTAssertTrue(log.ids.isEmpty)
        toast.modeButton.performClick(nil); try await wait { manager.state == .running }
        XCTAssertEqual(manager.desiredMode, .system)
        let content = try XCTUnwrap(toast.panel?.contentView); content.layoutSubtreeIfNeeded()
        XCTAssertTrue(toast.polishKnob.isHidden)
        XCTAssertFalse(toast.modeButton.isHidden); XCTAssertTrue(toast.dictationIndicator.isHidden)
        XCTAssertEqual(toast.modeButton.frame.height, 28, accuracy: 1)
        XCTAssertFalse(toast.modeButton.needsPanelToBecomeKey); XCTAssertFalse(toast.modeButton.mouseDownCanMoveWindow)
        voice.startHandsFree(); try await waitAsync { await engine.started }
        XCTAssertTrue(toast.modeButton.paused)
        XCTAssertTrue(toast.modeButton.isHidden); XCTAssertFalse(toast.dictationIndicator.isHidden)
        toast.panel?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(toast.dictationIndicator.frame.midY, toast.polishKnob.frame.midY, accuracy: 1)
        manager.selectMode(.all)
        XCTAssertEqual(manager.desiredMode, .all); XCTAssertEqual(log.ids, ["system"])
        XCTAssertTrue((toast.modeButton.accessibilityValue() as? String)?.contains("paused") == true)
        voice.cancel(); try await wait { manager.state == .running }
        XCTAssertFalse(toast.modeButton.paused)
        XCTAssertFalse(toast.modeButton.isHidden); XCTAssertTrue(toast.dictationIndicator.isHidden)
        XCTAssertEqual(toast.modeButton.selection.selected, .all)
        manager.stop(); try await wait { manager.state == .idle }
    }
}
