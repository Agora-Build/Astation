import AppKit
import XCTest
@testable import Menubar

private actor DictationTestEngine: LiveTranscribing {
    private var callback: (@Sendable (TranscriptSegment) -> Void)?
    var started = false
    var cancelled = false
    var finishSegments: [TranscriptSegment] = []
    func start(onSegment: @escaping @Sendable (TranscriptSegment) -> Void) { callback = onSegment; started = true }
    func consume(_ samples: [Float]) {}
    func finish() { for segment in finishSegments { callback?(segment) } }
    func cancel() { cancelled = true }
    func setFinish(_ segments: [TranscriptSegment]) { finishSegments = segments }
    func emit(_ segment: TranscriptSegment) { callback?(segment) }
}

private actor PendingDictationPolish {
    var texts: [String] = []
    private var continuations: [CheckedContinuation<String, Never>] = []
    func polish(_ text: String) async -> String {
        texts.append(text)
        return await withCheckedContinuation { continuations.append($0) }
    }
    func resolve(_ text: String) { continuations.removeFirst().resume(returning: text) }
}

private final class DictationTestTextTarget: DictationTextTarget {
    var inserted: [String] = []
    var error: Error?
    func insert(_ text: String) throws { if let error { throw error }; inserted.append(text) }
}

@MainActor
final class VoiceDictationTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "astation-dictation-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }; return defaults
    }
    private func segment(_ text: String, id: String = "one", final: Bool = true) -> TranscriptSegment {
        TranscriptSegment(id: id, sourceID: "microphone", language: "en-US", text: text, isFinal: final, offset: 0)
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Dictation state did not settle")
    }
    private func waitUntilAsync(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 { if await predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Dictation worker did not settle")
    }
    private func transcription(_ recorder: AudioRecordingManager) -> AudioTranscriptionManager {
        AudioTranscriptionManager(recorder: recorder, defaults: defaults(), engineFactory: { _ in DictationTestEngine() })
    }
    func testUnchangedPolishResultAfterCaptionExpiryGetsItsOwnTwentySecondDisplay() {
        let raw = segment("Already polished text.")
        var captions = FloatingCaptionBuffer()
        captions.update(raw, now: 100); captions.expire(now: 121)
        XCTAssertTrue(captions.lines.isEmpty)
        captions.update(raw, now: 122)
        XCTAssertTrue(captions.lines.isEmpty, "Provider duplicates do not replay expired speech")
        captions.update(raw, now: 122, refreshReceipt: true)
        XCTAssertEqual(captions.lines.first?.segment.text, raw.text)
        captions.expire(now: 141); XCTAssertEqual(captions.lines.count, 1)
        captions.expire(now: 142); XCTAssertTrue(captions.lines.isEmpty)
    }
    func testPTTAggregatesASRFinishAndDoesNotCallLLMWhenDisabled() async throws {
        let mic = SharedTestMicrophone(), engine = DictationTestEngine(), recorder = AudioRecordingManager(defaults: defaults())
        let captions = transcription(recorder)
        await engine.setFinish([segment("hello", id: "first"), segment("world", id: "second")])
        var sent: [String] = [], polishCalls = 0
        let dictation = VoiceDictationManager(transcription: captions, captureFactory: { _ in mic }, permission: { true },
            engineFactory: { engine }, resolveTarget: { "atem-1" }, sendText: { text, target in XCTAssertEqual(target, "atem-1"); sent.append(text); return true },
            showStatus: { _ in }, defaults: defaults(), polish: { text, _ in polishCalls += 1; return text })
        dictation.startPTT(); try await waitUntilAsync { await engine.started }
        await engine.emit(segment("hello", id: "first", final: false))
        dictation.stopPTT(); try await waitUntil { dictation.mode == .off }
        XCTAssertEqual(sent, ["hello world"]); XCTAssertEqual(polishCalls, 0)
        XCTAssertEqual(dictation.lastRawDictationText, "hello world"); XCTAssertNil(dictation.lastPolishedDictationText)
        XCTAssertEqual(captions.floatingCaptionBuffer.lines.map(\.segment.text), ["hello world"])
        XCTAssertTrue(captions.transcript.segments.isEmpty); XCTAssertEqual(mic.stopCount, 1)
    }
    func testSelectedLLMPolishesBeforeCaptionsAndAtemDelivery() async throws {
        let mic = SharedTestMicrophone(), engine = DictationTestEngine(), recorder = AudioRecordingManager(defaults: defaults())
        let captions = transcription(recorder)
        await engine.setFinish([segment("um hello world")])
        var sent: [String] = [], providers: [DictationLLMProvider] = []
        let dictation = VoiceDictationManager(transcription: captions, captureFactory: { _ in mic }, permission: { true }, engineFactory: { engine },
            resolveTarget: { "target" }, sendText: { text, _ in sent.append(text); return true }, showStatus: { _ in }, defaults: defaults(),
            polish: { text, config in XCTAssertEqual(text, "um hello world"); providers.append(config.provider); return "Hello, world." })
        var config = dictation.settings; config.polishing = true; config.provider = .localServer; dictation.updateSettings(config)
        dictation.startPTT(); try await waitUntilAsync { await engine.started }; dictation.stopPTT()
        try await waitUntil { dictation.mode == .off }
        XCTAssertEqual(providers, [.localServer]); XCTAssertEqual(sent, ["Hello, world."])
        XCTAssertEqual(dictation.lastRawDictationText, "um hello world"); XCTAssertEqual(dictation.lastPolishedDictationText, "Hello, world.")
        XCTAssertEqual(captions.floatingCaptionBuffer.lines.map(\.segment.text), ["Hello, world."])
    }
    func testPolishingFailureKeepsRawLocallyWithoutExternalFallback() async throws {
        let engine = DictationTestEngine(), recorder = AudioRecordingManager(defaults: defaults()), mic = SharedTestMicrophone()
        let captions = transcription(recorder); await engine.setFinish([segment("raw dictation")])
        var sent = 0
        let dictation = VoiceDictationManager(transcription: captions, captureFactory: { _ in mic }, permission: { true }, engineFactory: { engine },
            resolveTarget: { "atem" }, sendText: { _, _ in sent += 1; return true }, showStatus: { _ in }, defaults: defaults(),
            polish: { _, _ in throw DictationError.message("Polish test failure") })
        dictation.setPolishing(true); dictation.startPTT(); try await waitUntilAsync { await engine.started }; dictation.stopPTT()
        try await waitUntil { dictation.mode == .off }
        XCTAssertEqual(sent, 0); XCTAssertEqual(dictation.lastRawDictationText, "raw dictation")
        XCTAssertNil(dictation.lastPolishedDictationText); XCTAssertEqual(dictation.message, "Polish test failure")
        XCTAssertEqual(captions.floatingCaptionBuffer.lines.last?.segment.text, "raw dictation")
    }
    func testHandsFreePolishingIsOrderedAndDuplicateFinalsAreNotSentTwice() async throws {
        let engine = DictationTestEngine(), pending = PendingDictationPolish(), recorder = AudioRecordingManager(defaults: defaults()), mic = SharedTestMicrophone()
        let captions = transcription(recorder); var sent: [String] = []
        let dictation = VoiceDictationManager(transcription: captions, captureFactory: { _ in mic }, permission: { true }, engineFactory: { engine },
            resolveTarget: { "atem" }, sendText: { text, _ in sent.append(text); return true }, showStatus: { _ in }, defaults: defaults(),
            polish: { text, _ in await pending.polish(text) })
        dictation.setPolishing(true); dictation.startHandsFree(); try await waitUntilAsync { await engine.started }
        await engine.emit(segment("first", id: "1")); await engine.emit(segment("first", id: "1")); await engine.emit(segment("second", id: "2"))
        try await waitUntilAsync { await pending.texts.count == 1 }
        XCTAssertTrue(sent.isEmpty); XCTAssertTrue(dictation.isPolishing)
        await pending.resolve("First."); try await waitUntilAsync { await pending.texts.count == 2 }
        XCTAssertEqual(sent, ["First."])
        dictation.stopHandsFree(); await pending.resolve("Second.")
        try await waitUntil { dictation.mode == .off }
        XCTAssertEqual(sent, ["First.", "Second."]); XCTAssertEqual(mic.stopCount, 1)
    }
    func testCancelDuringPolishRejectsLateResult() async throws {
        let engine = DictationTestEngine(), pending = PendingDictationPolish(), recorder = AudioRecordingManager(defaults: defaults()), mic = SharedTestMicrophone()
        let captions = transcription(recorder); await engine.setFinish([segment("unfinished")]); var sent: [String] = []
        let dictation = VoiceDictationManager(transcription: captions, captureFactory: { _ in mic }, permission: { true }, engineFactory: { engine },
            resolveTarget: { "atem" }, sendText: { text, _ in sent.append(text); return true }, showStatus: { _ in }, defaults: defaults(),
            polish: { text, _ in await pending.polish(text) })
        dictation.setPolishing(true); dictation.startPTT(); try await waitUntilAsync { await engine.started }; dictation.stopPTT()
        try await waitUntilAsync { await pending.texts.count == 1 }
        dictation.cancel(); await pending.resolve("Must not send.")
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertTrue(sent.isEmpty); XCTAssertFalse(dictation.isPolishing); XCTAssertEqual(dictation.mode, .off)
        XCTAssertFalse(captions.floatingCaptionBuffer.lines.contains { $0.segment.text == "Must not send." })
    }
    func testOriginalAtemMustRemainActiveAfterPolishing() async throws {
        let engine = DictationTestEngine(), pending = PendingDictationPolish(), recorder = AudioRecordingManager(defaults: defaults()), mic = SharedTestMicrophone()
        await engine.setFinish([segment("hello")]); var target = "first", sent = 0
        let dictation = VoiceDictationManager(transcription: transcription(recorder), captureFactory: { _ in mic }, permission: { true }, engineFactory: { engine },
            resolveTarget: { target }, sendText: { _, _ in sent += 1; return true }, showStatus: { _ in }, defaults: defaults(),
            polish: { text, _ in await pending.polish(text) })
        dictation.setPolishing(true); dictation.startPTT(); try await waitUntilAsync { await engine.started }; dictation.stopPTT()
        try await waitUntilAsync { await pending.texts.count == 1 }
        target = "second"; await pending.resolve("Hello."); try await waitUntil { dictation.mode == .off }
        XCTAssertEqual(sent, 0); XCTAssertTrue(dictation.message!.contains("no longer active"))
    }
    func testTextInsertionOnlyUsesCapturedTargetAndPolishedText() async throws {
        let engine = DictationTestEngine(), recorder = AudioRecordingManager(defaults: defaults()), mic = SharedTestMicrophone(), field = DictationTestTextTarget()
        await engine.setFinish([segment("um type this")]); var atemSends = 0
        let dictation = VoiceDictationManager(transcription: transcription(recorder), captureFactory: { _ in mic }, permission: { true }, engineFactory: { engine },
            sendText: { _, _ in atemSends += 1; return true }, showStatus: { _ in }, defaults: defaults(), polish: { _, _ in "Type this." }, captureTextTarget: { field })
        var config = dictation.settings; config.polishing = true; config.destination = .activeText; dictation.updateSettings(config)
        dictation.startPTT(); try await waitUntilAsync { await engine.started }; dictation.stopPTT()
        try await waitUntil { dictation.mode == .off }
        XCTAssertEqual(field.inserted, ["Type this."]); XCTAssertEqual(atemSends, 0)
    }
    func testChangedTextFieldRejectsInsertionAndLeavesPolishedCaption() async throws {
        let engine = DictationTestEngine(), recorder = AudioRecordingManager(defaults: defaults()), mic = SharedTestMicrophone(), field = DictationTestTextTarget()
        field.error = DictationError.message("Focus moved")
        let captions = transcription(recorder); await engine.setFinish([segment("hello")])
        let dictation = VoiceDictationManager(transcription: captions, captureFactory: { _ in mic }, permission: { true }, engineFactory: { engine },
            showStatus: { _ in }, defaults: defaults(), polish: { _, _ in "Hello." }, captureTextTarget: { field })
        var config = dictation.settings; config.polishing = true; config.destination = .activeText; dictation.updateSettings(config)
        dictation.startPTT(); try await waitUntilAsync { await engine.started }; dictation.stopPTT(); try await waitUntil { dictation.mode == .off }
        XCTAssertTrue(field.inserted.isEmpty); XCTAssertEqual(captions.floatingCaptionBuffer.lines.last?.segment.text, "Hello.")
        XCTAssertEqual(dictation.message, "Focus moved")
    }
    func testMicTranscriptionCancelsDictationAndBlocksBothModesWhileSystemAllowsThem() async throws {
        let mic = SharedTestMicrophone(), engine = DictationTestEngine()
        let recorder = AudioRecordingManager(defaults: defaults(), captureFactory: { _ in SharedTestMicrophone() }, microphonePermission: { true })
        var recording = recorder.settings; recording.outputMode = .system; recorder.updateSettings(recording)
        let captions = transcription(recorder); var sends = 0
        let dictation = VoiceDictationManager(transcription: captions, captureFactory: { _ in mic }, permission: { true }, engineFactory: { engine },
            sendText: { _, _ in sends += 1; return true }, showStatus: { _ in }, defaults: defaults())
        dictation.startPTT(); try await waitUntilAsync { await engine.started }; await engine.emit(segment("discard this", final: false))
        captions.start(); XCTAssertEqual(dictation.mode, .off); XCTAssertFalse(dictation.isAvailable)
        dictation.startPTT(); XCTAssertEqual(dictation.mode, .off); dictation.startHandsFree(); XCTAssertEqual(dictation.mode, .off)
        XCTAssertEqual(sends, 0); captions.stop(); try await waitUntil { !captions.isActive }
        var settings = captions.settings; settings.sourceID = "system"; captions.updateSettings(settings)
        captions.start(); XCTAssertTrue(dictation.isAvailable)
        dictation.startHandsFree(); XCTAssertEqual(dictation.mode, .handsFree)
        captions.stop(); try await waitUntil { !captions.isActive }; XCTAssertEqual(dictation.mode, .handsFree)
        dictation.cancel(); recorder.shutdown()
    }
    func testReleaseDuringPermissionDoesNotOpenMicrophoneLater() async throws {
        let recorder = AudioRecordingManager(defaults: defaults()); var starts = 0
        let dictation = VoiceDictationManager(transcription: transcription(recorder), captureFactory: { _ in starts += 1; return SharedTestMicrophone() },
            permission: { try? await Task.sleep(nanoseconds: 50_000_000); return true }, showStatus: { _ in }, defaults: defaults())
        dictation.startPTT(); dictation.stopPTT(); try await waitUntil { dictation.mode == .off }
        XCTAssertEqual(starts, 0); XCTAssertEqual(dictation.message, "No speech detected.")
    }
    func testCaptionOnlyDestinationNeverSendsAndSettingsKeysStaySeparate() async throws {
        let storage = defaults(), secrets = DictationTestSecrets(), engine = DictationTestEngine(), recorder = AudioRecordingManager(defaults: defaults())
        await engine.setFinish([segment("captions only")]); var sends = 0
        let dictation = VoiceDictationManager(transcription: transcription(recorder), captureFactory: { _ in SharedTestMicrophone() }, permission: { true }, engineFactory: { engine },
            resolveTarget: { "atem" }, sendText: { _, _ in sends += 1; return true }, showStatus: { _ in }, defaults: storage, secrets: secrets)
        var config = dictation.settings; config.destination = .captions; config.provider = .cloud; dictation.updateSettings(config)
        dictation.saveKey("test-only-llm-key")
        XCTAssertEqual(secrets.values[config.endpoint], "test-only-llm-key")
        XCTAssertFalse(String(decoding: storage.data(forKey: VoiceDictationManager.defaultsKey)!, as: UTF8.self).contains("test-only-llm-key"))
        XCTAssertNotEqual(KeychainTranscriptionSecrets().service, KeychainTranscriptionSecrets(service: "build.agora.astation.dictation-llm").service)
        dictation.startPTT(); try await waitUntilAsync { await engine.started }; dictation.stopPTT(); try await waitUntil { dictation.mode == .off }
        XCTAssertEqual(sends, 0); XCTAssertEqual(dictation.lastDictationText, "captions only")
    }
    func testSettingsAndFloatingPanelKnobsStayInSyncAndRender() throws {
        _ = NSApplication.shared
        let recorder = AudioRecordingManager(defaults: defaults()), storage = defaults(), captions = transcription(recorder)
        let dictation = VoiceDictationManager(transcription: captions, showStatus: { _ in }, defaults: storage)
        let settings = VoiceDictationViewController(manager: dictation)
        let toast = TranscriptionToastController(manager: captions, showWindow: false)
        toast.attachDictation(dictation)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = settings.view
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(settings.polishKnob.state, .off); XCTAssertEqual(toast.polishKnob.state, .off)
        settings.polishKnob.performClick(nil)
        XCTAssertTrue(dictation.settings.polishing); XCTAssertEqual(toast.polishKnob.state, .on)
        toast.polishKnob.performClick(nil)
        XCTAssertFalse(dictation.settings.polishing); XCTAssertEqual(settings.polishKnob.state, .off)
        dictation.setPolishing(true)
        let stored = try JSONDecoder().decode(DictationSettings.self, from: XCTUnwrap(storage.data(forKey: VoiceDictationManager.defaultsKey)))
        XCTAssertTrue(stored.polishing)
        captions.setFloatingCaptions(true)
        captions.displayDictationCaption(segment("Polished dictation appears here.\nSelect words, or copy everything."))
        toast.refresh(); toast.panel?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(toast.polishKnob.frame.width, 60)
        if let path = ProcessInfo.processInfo.environment["ASTATION_DICTATION_UI_SNAPSHOT"] {
            let view = settings.view
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
        if let path = ProcessInfo.processInfo.environment["ASTATION_POLISH_TOAST_SNAPSHOT"], let view = toast.panel?.contentView {
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
        window.close()
    }
    func testProviderChoicesAndEndpointEditsDoNotCarryUploadConsentOrDiscardModelEdits() throws {
        _ = NSApplication.shared
        let recorder = AudioRecordingManager(defaults: defaults())
        let manager = VoiceDictationManager(transcription: transcription(recorder), showStatus: { _ in }, defaults: defaults())
        var config = manager.settings; config.provider = .custom
        config.customEndpoint = "https://one.example.test/v1/chat/completions"; config.consentEndpoint = config.endpoint
        manager.updateSettings(config)
        let controller = VoiceDictationViewController(manager: manager)
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let content = views(controller.view)
        let endpoint = try XCTUnwrap(content.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Endpoint" })
        let model = try XCTUnwrap(content.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Model" })
        let consent = try XCTUnwrap(content.compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("Allow dictation text uploads") })
        let apply = try XCTUnwrap(content.compactMap { $0 as? NSButton }.first { $0.title == "Apply Model Settings" })
        XCTAssertEqual(consent.state, .on)
        endpoint.stringValue = "https://two.example.test/v1/chat/completions"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: endpoint))
        XCTAssertEqual(consent.state, .off)
        model.stringValue = "my-edited-model"
        manager.setPolishing(true)
        XCTAssertEqual(model.stringValue, "my-edited-model")
        apply.performClick(nil)
        XCTAssertEqual(manager.settings.endpoint, endpoint.stringValue); XCTAssertNil(manager.settings.consentEndpoint)
        XCTAssertFalse(manager.settings.hasUploadConsent)
        consent.performClick(nil)
        XCTAssertEqual(manager.settings.consentEndpoint, endpoint.stringValue)
        let provider = try XCTUnwrap(content.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Polishing LLM" })
        XCTAssertEqual(provider.itemTitles, DictationLLMProvider.allCases.map(\.title))
        provider.selectItem(at: DictationLLMProvider.allCases.firstIndex(of: .localServer)!)
        NSApp.sendAction(provider.action!, to: provider.target, from: provider)
        XCTAssertEqual(manager.settings.provider, .localServer)
        XCTAssertEqual(endpoint.stringValue, "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(model.stringValue, "qwen3:4b")
        XCTAssertFalse(manager.settings.requiresUploadConsent)
    }
}
