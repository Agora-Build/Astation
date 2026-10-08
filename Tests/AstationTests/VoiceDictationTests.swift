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
    private func outputDefaults(typing: Bool = false, atem: Bool = true) -> UserDefaults {
        let storage = defaults()
        var settings = DictationSettings(); settings.typeInActiveTextField = typing; settings.sendToAtem = atem
        storage.set(try! JSONEncoder().encode(settings), forKey: VoiceDictationManager.defaultsKey)
        return storage
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
            showStatus: { _ in }, defaults: outputDefaults(), polish: { text, _ in polishCalls += 1; return text })
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
            resolveTarget: { "target" }, sendText: { text, _ in sent.append(text); return true }, showStatus: { _ in }, defaults: outputDefaults(),
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
        let captions = transcription(recorder), field = DictationTestTextTarget(); await engine.setFinish([segment("raw dictation")])
        var sent = 0
        let dictation = VoiceDictationManager(transcription: captions, captureFactory: { _ in mic }, permission: { true }, engineFactory: { engine },
            resolveTarget: { "atem" }, sendText: { _, _ in sent += 1; return true }, showStatus: { _ in }, defaults: outputDefaults(typing: true),
            polish: { _, _ in throw DictationError.message("Polish test failure") }, captureTextTarget: { field })
        dictation.setPolishing(true); dictation.startPTT(); try await waitUntilAsync { await engine.started }; dictation.stopPTT()
        try await waitUntil { dictation.mode == .off }
        XCTAssertEqual(sent, 0); XCTAssertEqual(dictation.lastRawDictationText, "raw dictation")
        XCTAssertTrue(field.inserted.isEmpty)
        XCTAssertNil(dictation.lastPolishedDictationText); XCTAssertEqual(dictation.message, "Polish test failure")
        XCTAssertEqual(captions.floatingCaptionBuffer.lines.last?.segment.text, "raw dictation")
    }
    func testHandsFreePolishingIsOrderedAndDuplicateFinalsAreNotSentTwice() async throws {
        let engine = DictationTestEngine(), pending = PendingDictationPolish(), recorder = AudioRecordingManager(defaults: defaults()), mic = SharedTestMicrophone()
        let captions = transcription(recorder), field = DictationTestTextTarget(); var sent: [String] = []
        let dictation = VoiceDictationManager(transcription: captions, captureFactory: { _ in mic }, permission: { true }, engineFactory: { engine },
            resolveTarget: { "atem" }, sendText: { text, _ in sent.append(text); return true }, showStatus: { _ in }, defaults: outputDefaults(typing: true),
            polish: { text, _ in await pending.polish(text) }, captureTextTarget: { field })
        dictation.setPolishing(true); dictation.startHandsFree(); try await waitUntilAsync { await engine.started }
        await engine.emit(segment("first", id: "1")); await engine.emit(segment("first", id: "1")); await engine.emit(segment("second", id: "2"))
        try await waitUntilAsync { await pending.texts.count == 1 }
        XCTAssertTrue(sent.isEmpty); XCTAssertTrue(dictation.isPolishing)
        await pending.resolve("First."); try await waitUntilAsync { await pending.texts.count == 2 }
        XCTAssertEqual(sent, ["First."])
        dictation.stopHandsFree(); await pending.resolve("Second.")
        try await waitUntil { dictation.mode == .off }
        XCTAssertEqual(sent, ["First.", "Second."]); XCTAssertEqual(mic.stopCount, 1)
        XCTAssertEqual(field.inserted, sent)
    }
    func testCancelDuringPolishRejectsLateResult() async throws {
        let engine = DictationTestEngine(), pending = PendingDictationPolish(), recorder = AudioRecordingManager(defaults: defaults()), mic = SharedTestMicrophone()
        let captions = transcription(recorder); await engine.setFinish([segment("unfinished")]); var sent: [String] = []
        let dictation = VoiceDictationManager(transcription: captions, captureFactory: { _ in mic }, permission: { true }, engineFactory: { engine },
            resolveTarget: { "atem" }, sendText: { text, _ in sent.append(text); return true }, showStatus: { _ in }, defaults: outputDefaults(),
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
        let field = DictationTestTextTarget()
        await engine.setFinish([segment("hello")]); var target = "first", sent = 0
        let dictation = VoiceDictationManager(transcription: transcription(recorder), captureFactory: { _ in mic }, permission: { true }, engineFactory: { engine },
            resolveTarget: { target }, sendText: { _, _ in sent += 1; return true }, showStatus: { _ in }, defaults: outputDefaults(typing: true),
            polish: { text, _ in await pending.polish(text) }, captureTextTarget: { field })
        dictation.setPolishing(true); dictation.startPTT(); try await waitUntilAsync { await engine.started }; dictation.stopPTT()
        try await waitUntilAsync { await pending.texts.count == 1 }
        target = "second"; await pending.resolve("Hello."); try await waitUntil { dictation.mode == .off }
        XCTAssertEqual(sent, 0); XCTAssertTrue(dictation.message!.contains("no longer active"))
        XCTAssertEqual(field.inserted, ["Hello."])
    }
    func testTextInsertionOnlyUsesCapturedTargetAndPolishedText() async throws {
        let engine = DictationTestEngine(), recorder = AudioRecordingManager(defaults: defaults()), mic = SharedTestMicrophone(), field = DictationTestTextTarget()
        await engine.setFinish([segment("um type this")]); var atemSends = 0
        let dictation = VoiceDictationManager(transcription: transcription(recorder), captureFactory: { _ in mic }, permission: { true }, engineFactory: { engine },
            sendText: { _, _ in atemSends += 1; return true }, showStatus: { _ in }, defaults: defaults(), polish: { _, _ in "Type this." }, captureTextTarget: { field })
        dictation.setPolishing(true)
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
        dictation.setPolishing(true)
        dictation.startPTT(); try await waitUntilAsync { await engine.started }; dictation.stopPTT(); try await waitUntil { dictation.mode == .off }
        XCTAssertTrue(field.inserted.isEmpty); XCTAssertEqual(captions.floatingCaptionBuffer.lines.last?.segment.text, "Hello.")
        XCTAssertEqual(dictation.message, "Focus moved")
    }
    func testAllOutputCombinationsDeliverTheSameResultWithoutAccessingDisabledOutputs() async throws {
        for polishing in [false, true] {
            for typing in [false, true] {
                for atem in [false, true] {
                    let engine = DictationTestEngine(), recorder = AudioRecordingManager(defaults: defaults())
                    let captions = transcription(recorder), field = DictationTestTextTarget()
                    await engine.setFinish([segment("um hello world")])
                    var sent: [String] = [], captures = 0, resolutions = 0, polishCalls = 0
                    let dictation = VoiceDictationManager(transcription: captions, captureFactory: { _ in SharedTestMicrophone() },
                        permission: { true }, engineFactory: { engine }, resolveTarget: { resolutions += 1; return "original-atem" },
                        sendText: { text, target in XCTAssertEqual(target, "original-atem"); sent.append(text); return true },
                        showStatus: { _ in }, defaults: outputDefaults(typing: typing, atem: atem),
                        polish: { _, _ in polishCalls += 1; return "Hello, world." }, captureTextTarget: { captures += 1; return field })
                    dictation.setPolishing(polishing)
                    dictation.startPTT(); try await waitUntilAsync { await engine.started }
                    dictation.stopPTT(); try await waitUntil { dictation.mode == .off }
                    let expected = polishing ? "Hello, world." : "um hello world"
                    XCTAssertEqual(field.inserted, typing ? [expected] : [])
                    XCTAssertEqual(sent, atem ? [expected] : [])
                    XCTAssertEqual(captures, typing ? 1 : 0)
                    XCTAssertEqual(resolutions, atem ? 2 : 0)
                    XCTAssertEqual(polishCalls, polishing ? 1 : 0, "Polish once before fanning out to outputs")
                    XCTAssertEqual(captions.floatingCaptionBuffer.lines.map(\.segment.text), [expected])
                }
            }
        }
    }
    func testUnavailableOrChangedTextFieldDoesNotBlockSelectedAtemOutput() async throws {
        for failureAtCapture in [true, false] {
            let engine = DictationTestEngine(), recorder = AudioRecordingManager(defaults: defaults())
            let captions = transcription(recorder), field = DictationTestTextTarget()
            field.error = DictationError.message("The original field changed")
            await engine.setFinish([segment("um send this")]); var sent: [String] = []
            let dictation = VoiceDictationManager(transcription: captions, captureFactory: { _ in SharedTestMicrophone() },
                permission: { true }, engineFactory: { engine }, resolveTarget: { "atem" },
                sendText: { text, _ in sent.append(text); return true }, showStatus: { _ in }, defaults: outputDefaults(typing: true),
                polish: { _, _ in "Send this." }, captureTextTarget: {
                    if failureAtCapture { throw DictationError.message("Accessibility permission unavailable") }
                    return field
                })
            dictation.setPolishing(true)
            dictation.startPTT(); try await waitUntilAsync { await engine.started }
            dictation.stopPTT(); try await waitUntil { dictation.mode == .off }
            XCTAssertTrue(field.inserted.isEmpty); XCTAssertEqual(sent, ["Send this."])
            XCTAssertEqual(captions.floatingCaptionBuffer.lines.map(\.segment.text), ["Send this."])
            XCTAssertTrue(dictation.message?.contains(failureAtCapture ? "Accessibility permission unavailable" : "The original field changed") == true)
            XCTAssertTrue(dictation.message?.contains("sent to the active Atem") == true)
        }
    }
    func testAtemSendFailureDoesNotBlockTypingOrLoseCaptions() async throws {
        let engine = DictationTestEngine(), recorder = AudioRecordingManager(defaults: defaults())
        let captions = transcription(recorder), field = DictationTestTextTarget(); var attempts = 0
        await engine.setFinish([segment("hello")])
        let dictation = VoiceDictationManager(transcription: captions, captureFactory: { _ in SharedTestMicrophone() },
            permission: { true }, engineFactory: { engine }, resolveTarget: { "atem" },
            sendText: { _, _ in attempts += 1; return false }, showStatus: { _ in }, defaults: outputDefaults(typing: true), captureTextTarget: { field })
        dictation.startPTT(); try await waitUntilAsync { await engine.started }
        dictation.stopPTT(); try await waitUntil { dictation.mode == .off }
        XCTAssertEqual(attempts, 1); XCTAssertEqual(field.inserted, ["hello"])
        XCTAssertEqual(captions.floatingCaptionBuffer.lines.map(\.segment.text), ["hello"])
        XCTAssertTrue(dictation.message?.contains("inserted in the original text field") == true)
    }
    func testChangingOutputsDuringPolishingCancelsLateDeliveryToBothOutputs() async throws {
        let engine = DictationTestEngine(), pending = PendingDictationPolish(), recorder = AudioRecordingManager(defaults: defaults())
        let captions = transcription(recorder), field = DictationTestTextTarget(); var sends = 0
        await engine.setFinish([segment("unfinished")])
        let dictation = VoiceDictationManager(transcription: captions, captureFactory: { _ in SharedTestMicrophone() },
            permission: { true }, engineFactory: { engine }, resolveTarget: { "atem" }, sendText: { _, _ in sends += 1; return true },
            showStatus: { _ in }, defaults: outputDefaults(typing: true), polish: { text, _ in await pending.polish(text) }, captureTextTarget: { field })
        dictation.setPolishing(true); dictation.startPTT(); try await waitUntilAsync { await engine.started }; dictation.stopPTT()
        try await waitUntilAsync { await pending.texts.count == 1 }
        var settings = dictation.settings; settings.sendToAtem = false; dictation.updateSettings(settings)
        XCTAssertEqual(dictation.mode, .off); XCTAssertTrue(dictation.message?.contains("outputs changed") == true)
        await pending.resolve("Must not be used."); try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(sends, 0); XCTAssertTrue(field.inserted.isEmpty)
        XCTAssertFalse(captions.floatingCaptionBuffer.lines.contains { $0.segment.text == "Must not be used." })
    }
    func testLegacySavedDestinationLoadsAndIsPersistedAsIndependentOutputs() throws {
        let storage = defaults(), recorder = AudioRecordingManager(defaults: defaults())
        storage.set(Data(#"{"destination":"captions","polishing":true}"#.utf8), forKey: VoiceDictationManager.defaultsKey)
        let dictation = VoiceDictationManager(transcription: transcription(recorder), showStatus: { _ in }, defaults: storage)
        XCTAssertTrue(dictation.settings.polishing)
        XCTAssertFalse(dictation.settings.typeInActiveTextField); XCTAssertFalse(dictation.settings.sendToAtem)
        var settings = dictation.settings; settings.typeInActiveTextField = true; settings.sendToAtem = true
        dictation.updateSettings(settings)
        let stored = try XCTUnwrap(storage.data(forKey: VoiceDictationManager.defaultsKey))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: stored) as? [String: Any])
        XCTAssertNil(object["destination"])
        XCTAssertEqual(try JSONDecoder().decode(DictationSettings.self, from: stored), settings)
    }
    func testMicTranscriptionCancelsDictationAndBlocksBothModesWhileSystemAllowsThem() async throws {
        let mic = SharedTestMicrophone(), engine = DictationTestEngine()
        let recorder = AudioRecordingManager(defaults: defaults(), captureFactory: { _ in SharedTestMicrophone() }, microphonePermission: { true })
        var recording = recorder.settings; recording.outputMode = .system; recorder.updateSettings(recording)
        let captions = transcription(recorder); var sends = 0
        let dictation = VoiceDictationManager(transcription: captions, captureFactory: { _ in mic }, permission: { true }, engineFactory: { engine },
            sendText: { _, _ in sends += 1; return true }, showStatus: { _ in }, defaults: outputDefaults(atem: false))
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
            permission: { try? await Task.sleep(nanoseconds: 50_000_000); return true }, showStatus: { _ in }, defaults: outputDefaults(atem: false))
        dictation.startPTT(); dictation.stopPTT(); try await waitUntil { dictation.mode == .off }
        XCTAssertEqual(starts, 0); XCTAssertEqual(dictation.message, "No speech detected.")
    }
    func testCaptionOnlyDestinationNeverSendsAndSettingsKeysStaySeparate() async throws {
        let storage = defaults(), secrets = DictationTestSecrets(), engine = DictationTestEngine(), recorder = AudioRecordingManager(defaults: defaults())
        await engine.setFinish([segment("captions only")]); var sends = 0
        let dictation = VoiceDictationManager(transcription: transcription(recorder), captureFactory: { _ in SharedTestMicrophone() }, permission: { true }, engineFactory: { engine },
            resolveTarget: { "atem" }, sendText: { _, _ in sends += 1; return true }, showStatus: { _ in }, defaults: storage, secrets: secrets)
        var config = dictation.settings; config.typeInActiveTextField = false; config.provider = .cloud; dictation.updateSettings(config)
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
    func testOutputCheckboxesAllowEveryCombinationAndPersistWithoutApplyingModelEdits() throws {
        _ = NSApplication.shared
        let storage = defaults(), recorder = AudioRecordingManager(defaults: defaults())
        let manager = VoiceDictationManager(transcription: transcription(recorder), showStatus: { _ in }, defaults: storage)
        var config = manager.settings; config.provider = .localServer; manager.updateSettings(config)
        let controller = VoiceDictationViewController(manager: manager)
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let content = views(controller.view)
        let typing = try XCTUnwrap(content.compactMap { $0 as? NSButton }.first { $0.title == "Type in active text field" })
        let atem = try XCTUnwrap(content.compactMap { $0 as? NSButton }.first { $0.title == "Send to active Atem" })
        let model = try XCTUnwrap(content.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Model" })
        XCTAssertEqual(typing.state, .on); XCTAssertEqual(atem.state, .off)
        model.stringValue = "unapplied-model-edit"
        atem.performClick(nil)
        XCTAssertTrue(manager.settings.typeInActiveTextField); XCTAssertTrue(manager.settings.sendToAtem)
        typing.performClick(nil)
        XCTAssertFalse(manager.settings.typeInActiveTextField); XCTAssertTrue(manager.settings.sendToAtem)
        atem.performClick(nil)
        XCTAssertFalse(manager.settings.typeInActiveTextField); XCTAssertFalse(manager.settings.sendToAtem)
        typing.performClick(nil)
        XCTAssertTrue(manager.settings.typeInActiveTextField); XCTAssertFalse(manager.settings.sendToAtem)
        XCTAssertEqual(model.stringValue, "unapplied-model-edit")
        XCTAssertEqual(manager.settings.localModel, "qwen3:4b")
        let stored = try JSONDecoder().decode(DictationSettings.self, from: XCTUnwrap(storage.data(forKey: VoiceDictationManager.defaultsKey)))
        XCTAssertEqual(stored, manager.settings)
        var external = manager.settings; external.typeInActiveTextField = false; external.sendToAtem = true
        manager.updateSettings(external)
        XCTAssertEqual(typing.state, .off); XCTAssertEqual(atem.state, .on)
    }
}
