import AppKit
import AVFoundation
import CryptoKit
import XCTest
@testable import Menubar

final class TranscriptionTests: XCTestCase {
    private func segment(_ text: String, id: String = "1", final: Bool = false, translation: Bool = false) -> TranscriptSegment {
        TranscriptSegment(id: id, sourceID: "microphone", language: translation ? "es-ES" : "en-US", text: text,
                          isFinal: final, offset: 2, isTranslation: translation)
    }
    func testDefaultAndLegacySettingsKeepEnglishAndEnableToast() throws {
        let settings = try JSONDecoder().decode(TranscriptionSettings.self, from: Data("{\"provider\":\"agora\",\"sourceID\":\"system\"}".utf8))
        XCTAssertEqual(settings.provider, .agora)
        XCTAssertEqual(settings.sourceID, "system")
        XCTAssertEqual(settings.selectedSourceIDs, ["system"])
        XCTAssertTrue(settings.additionalSourceIDs.isEmpty)
        XCTAssertEqual(settings.language, "en-US")
        XCTAssertTrue(settings.floatingCaptions)
        var saved = settings; saved.floatingCaptions = false
        XCTAssertEqual(try JSONDecoder().decode(TranscriptionSettings.self, from: JSONEncoder().encode(saved)), saved)
    }
    func testMultipleSourceSettingsRoundTripAndDeduplicateWithoutInventingSources() throws {
        var settings = TranscriptionSettings()
        settings.additionalSourceIDs = ["system", "", "microphone", "system", "test.selected-app"]
        XCTAssertEqual(settings.selectedSourceIDs, ["microphone", "system", "test.selected-app"])
        XCTAssertEqual(try JSONDecoder().decode(TranscriptionSettings.self, from: JSONEncoder().encode(settings)), settings)
        settings.sourceID = ""; settings.additionalSourceIDs = []
        let restored = try JSONDecoder().decode(TranscriptionSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(restored.selectedSourceIDs.isEmpty)
    }
    func testSameSentenceIDFromDifferentSourcesDoesNotOverwriteCaptions() {
        let mic = segment("Microphone speech", final: true)
        let app = TranscriptSegment(id: mic.id, sourceID: "test.selected-app", language: mic.language,
                                    text: "App speech", isFinal: true, offset: mic.offset)
        var transcript = TranscriptBuffer(), captions = FloatingCaptionBuffer()
        for value in [mic, app] { transcript.update(value); captions.update(value, now: 100) }
        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(captions.lines.count, 2)
        XCTAssertEqual(transcript.text, "[00:02 microphone en-US final] Microphone speech\n[00:02 test.selected-app en-US final] App speech")
        captions.expire(now: 120)
        XCTAssertTrue(captions.lines.isEmpty)
    }
    func testToastRetainsEachMultilineCaptionForExactlyTwentySeconds() {
        var buffer = FloatingCaptionBuffer()
        buffer.update(segment("First line\nsecond line", final: true), now: 100)
        buffer.update(segment("New sentence", id: "2", final: true), now: 109)
        buffer.expire(now: 119.999)
        XCTAssertEqual(buffer.lines.count, 2)
        XCTAssertEqual(buffer.lines.first?.segment.text, "First line\nsecond line")
        buffer.expire(now: 120)
        XCTAssertEqual(buffer.lines.map(\.segment.text), ["New sentence"])
        buffer.expire(now: 129)
        XCTAssertTrue(buffer.lines.isEmpty)
    }
    func testToastPartialUpdatesReplaceInPlaceAndFinalRejectsLatePartial() {
        var buffer = FloatingCaptionBuffer()
        buffer.update(segment("Hi"), now: 100)
        buffer.update(segment("Hi there", final: true), now: 105)
        buffer.update(segment("Hi"), now: 106)
        XCTAssertEqual(buffer.lines.count, 1)
        XCTAssertEqual(buffer.lines.first?.segment.text, "Hi there")
        buffer.expire(now: 124.999)
        XCTAssertEqual(buffer.lines.count, 1)
        buffer.expire(now: 125)
        XCTAssertTrue(buffer.lines.isEmpty)
    }
    func testDuplicatePacketsDoNotExtendExpiryOrResurrectExpiredCaptions() {
        var buffer = FloatingCaptionBuffer()
        let value = segment("Hello", final: true)
        buffer.update(value, now: 100)
        buffer.update(value, now: 119)
        buffer.expire(now: 120)
        XCTAssertTrue(buffer.lines.isEmpty)
        buffer.update(value, now: 121)
        XCTAssertTrue(buffer.lines.isEmpty)
    }
    func testTranslationGetsItsOwnMultilineCaptionAndTimestamp() {
        var buffer = FloatingCaptionBuffer()
        buffer.update(segment("Hello", final: true), now: 100)
        buffer.update(segment("Hola", final: true, translation: true), now: 105)
        buffer.expire(now: 120)
        XCTAssertEqual(buffer.lines.map(\.segment.text), ["Hola"])
        XCTAssertTrue(buffer.lines[0].segment.isTranslation)
    }
    func testInvalidAndOversizedCaptionsAreIgnoredAndBuffersAreBounded() {
        var buffer = TranscriptBuffer()
        buffer.update(segment("  \n"))
        buffer.update(segment(String(repeating: "a", count: 65_537)))
        buffer.update(TranscriptSegment(id: "bad", sourceID: "mic", language: "en-US", text: "x", isFinal: true, offset: .infinity))
        XCTAssertTrue(buffer.segments.isEmpty)
        for index in 0..<2_010 { buffer.update(segment("sentence", id: String(index), final: true)) }
        XCTAssertEqual(buffer.segments.count, 2_000)
        XCTAssertTrue(buffer.wasTruncated)
        var captions = FloatingCaptionBuffer()
        for index in 0..<200 { captions.update(segment("sentence", id: String(index)), now: 100) }
        XCTAssertEqual(captions.lines.count, 128)
    }
    func testTranscriptFinalCannotBeOverwrittenByLatePartial() {
        var buffer = TranscriptBuffer()
        buffer.update(segment("hello"))
        buffer.update(segment("hello world", final: true))
        buffer.update(segment("hello"))
        XCTAssertEqual(buffer.segments.count, 1)
        XCTAssertEqual(buffer.text, "[00:02 en-US final] hello world")
    }
    func testPCMConverterResamplesStereoWithoutChangingOriginals() throws {
        let converter = TranscriptionAudioConverter()
        let original = (0..<4_800).flatMap { _ in [Float(0.25), Float(0.25)] }
        let pcm = TranscriptionPCM(samples: original, sampleRate: 48_000, channels: 2)
        let converted = try converter.convert(pcm)
        XCTAssertGreaterThan(converted.count, 1_200)
        XCTAssertLessThanOrEqual(converted.count, 1_856)
        XCTAssertTrue(converted.suffix(1_000).allSatisfy { abs($0 - 0.25) < 0.02 })
        XCTAssertEqual(pcm.samples, original)
        let second = try converter.convert(pcm)
        let tail = try converter.finish()
        XCTAssertEqual(converted.count + second.count + tail.count, 3_200, accuracy: 2)
        let sanitized = try converter.convert(TranscriptionPCM(samples: [.nan, .infinity, 2, -2, 0.5], sampleRate: 16_000, channels: 1))
        XCTAssertEqual(sanitized, [0, 0, 1, -1, 0.5])
    }
    func testPCMConverterRejectsInvalidFormats() {
        let converter = TranscriptionAudioConverter()
        for pcm in [TranscriptionPCM(samples: [1], sampleRate: 0, channels: 1),
                    TranscriptionPCM(samples: [1], sampleRate: 48_000, channels: 2),
                    TranscriptionPCM(samples: [], sampleRate: 16_000, channels: 1)] {
            XCTAssertThrowsError(try converter.convert(pcm))
        }
    }
    func testThreeChannelAggregateConvertsToMonoWithoutChangingOriginals() throws {
        let converter = TranscriptionAudioConverter()
        let original = (0..<4_410).flatMap { _ in [Float(0.25), Float(0.25), Float(0.25)] }
        let converted = try converter.convert(TranscriptionPCM(samples: original, sampleRate: 44_100, channels: 3))
        let tail = try converter.finish()
        XCTAssertEqual(converted.count + tail.count, 1_600, accuracy: 2)
        XCTAssertTrue(converted.suffix(1_000).allSatisfy { abs($0 - 0.25) < 0.02 })
        XCTAssertEqual(original.count, 4_410 * 3)
    }
    func testInboxBoundsDurationAndReleasesConsumedAudio() async {
        let inbox = TranscriptionInbox()
        let pcm = TranscriptionPCM(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000, channels: 1)
        for _ in 0..<8 { XCTAssertTrue(inbox.offer(pcm)) }
        XCTAssertFalse(inbox.offer(pcm))
        var iterator = inbox.stream.makeAsyncIterator()
        if let value = await iterator.next() { inbox.consumed(value) }
        XCTAssertTrue(inbox.offer(pcm))
        inbox.finish()
        XCTAssertFalse(inbox.offer(pcm))
    }
    func testBundledManifestIntegrityAndURLSafety() throws {
        let manifest = try TranscriptionModelManifest.bundled()
        try manifest.validate()
        XCTAssertGreaterThanOrEqual(manifest.files.count, 16)
        XCTAssertGreaterThan(manifest.totalBytes, 224_000_000)
        for url in ["http://example.com/model.json", "https://user:password@example.com/model.json",
                    "https://example.com/model.json?token=secret", "https://example.com/model.json#fragment"] {
            XCTAssertFalse(TranscriptionModelManifest.safeURL(URL(string: url)!))
        }
        XCTAssertTrue(TranscriptionModelManifest.safeURL(URL(string: "https://dl.agora.build/astation/model.json")!))
    }
}

final class TranscriptionModelStoreTests: XCTestCase {
    private let content = Data("verified model fixture".utf8)
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("astation-model-test-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    private func manifest(path: String? = nil, bytes: Int64? = nil, hash: String? = nil) -> TranscriptionModelManifest {
        let paths = [path ?? "vocab.json", "decoder.mlmodelc/weights/weight.bin", "joint_decision.mlmodelc/weights/weight.bin",
                     "streaming_encoder.mlmodelc/weights/weight.bin"]
        let sha = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let files = paths.map { TranscriptionModelManifest.File(path: $0, url: URL(string: "https://model.example.com/\($0)")!,
                                                               bytes: bytes ?? Int64(content.count), sha256: hash ?? sha) }
        return TranscriptionModelManifest(schemaVersion: 1, id: TranscriptionModelManifest.modelID, name: "Fixture", revision: "test",
                                           licenseURL: URL(string: "https://example.com/license")!, totalBytes: Int64(content.count * 4), files: files)
    }
    func testRejectsTraversalHugeSizesBadChecksumsAndMissingRequiredFiles() {
        for manifest in [manifest(path: "../vocab.json"), manifest(path: "decoder.mlmodelc//vocab.json"),
                         manifest(bytes: .max), manifest(hash: "not-a-hash"), manifest(path: "not-vocab.json")] {
            XCTAssertThrowsError(try manifest.validate())
        }
    }
    func testDownloadVerifiesActualFilesAndDetectsInstalledCorruption() async throws {
        let root = try folder(), content = self.content
        let store = TranscriptionModelStore(root: root, fetchFile: { _, progress in
            let file = root.appendingPathComponent("fetch-\(UUID())")
            try content.write(to: file); progress(Int64(content.count)); return file
        })
        try await store.download(manifest: manifest()) { _ in }
        let installed = try await store.verifiedDirectory()
        XCTAssertTrue(store.hasInstalledModel)
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("vocab.json")), content)
        try Data(repeating: 0, count: content.count).write(to: installed.appendingPathComponent("vocab.json"))
        do { _ = try await store.verifiedDirectory(); XCTFail("Corrupted model accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Checksum")) }
    }
    func testFailedReplacementPreservesInstalledModelAndCleansStaging() async throws {
        let root = try folder(), content = self.content
        let good = TranscriptionModelStore(root: root, fetchFile: { _, _ in
            let file = root.appendingPathComponent("fetch-\(UUID())"); try content.write(to: file); return file
        })
        try await good.download(manifest: manifest()) { _ in }
        let bad = TranscriptionModelStore(root: root, fetchFile: { _, _ in
            let file = root.appendingPathComponent("bad-\(UUID())"); try Data([0]).write(to: file); return file
        })
        do { try await bad.download(manifest: manifest()) { _ in }; XCTFail("Bad model installed") } catch {}
        _ = try await good.verifiedDirectory()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [TranscriptionModelManifest.modelID])
    }
    func testCancelledDownloadNeverInstallsIncompleteModel() async throws {
        let root = try folder()
        let store = TranscriptionModelStore(root: root, fetchFile: { _, _ in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw CancellationError()
        })
        let manifest = manifest()
        let task = Task { try await store.download(manifest: manifest) { _ in } }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        do { try await task.value; XCTFail("Cancelled download succeeded") } catch {}
        XCTAssertFalse(store.hasInstalledModel)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}

@MainActor
final class TranscriptionSettingsTests: XCTestCase {
    private func segment(_ text: String, id: String, final: Bool = false) -> TranscriptSegment {
        TranscriptSegment(id: id, sourceID: "microphone", language: "en-US", text: text, isFinal: final, offset: 0)
    }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    private func defaults() -> UserDefaults {
        let suite = "astation-transcription-settings-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
    func testSourceCheckboxesSupportMicrophoneWithSystemOrMultipleApps() throws {
        _ = NSApplication.shared
        let defaults = defaults(), recorder = AudioRecordingManager(defaults: defaults)
        let controller = TranscriptionViewController(recorder: recorder)
        controller.loadViewIfNeeded()
        for (mode, ids) in [(RecordingOutputMode.system, ["system"]), (.applications, ["test.app-one", "test.app-two"])] {
            var config = recorder.settings; config.outputMode = mode; config.applicationBundleIDs = ids
            recorder.updateSettings(config)
            let buttons = descendants(controller.view).compactMap { $0 as? NSButton }
            let sources = buttons.filter { $0.identifier?.rawValue.hasPrefix("transcription-source-") == true }
            XCTAssertEqual(sources.count, 1 + ids.count)
            let mic = try XCTUnwrap(sources.first { $0.identifier?.rawValue == "transcription-source-microphone" })
            XCTAssertEqual(mic.state, .on)
            for id in ids {
                let button = try XCTUnwrap(sources.first { $0.identifier?.rawValue == "transcription-source-\(id)" })
                XCTAssertEqual(button.state, .off)
                button.performClick(nil)
            }
            XCTAssertEqual(recorder.transcription.settings.selectedSourceIDs, ["microphone"] + ids)
            mic.performClick(nil)
            XCTAssertEqual(recorder.transcription.settings.selectedSourceIDs, ids)
            for button in sources where button !== mic { button.performClick(nil) }
            XCTAssertTrue(recorder.transcription.settings.selectedSourceIDs.isEmpty)
            let start = try XCTUnwrap(buttons.first { $0.title == "Start Transcription" })
            XCTAssertFalse(start.isEnabled)
            mic.performClick(nil)
        }
        let stored = try JSONDecoder().decode(TranscriptionSettings.self, from: XCTUnwrap(defaults.data(forKey: AudioTranscriptionManager.defaultsKey)))
        XCTAssertEqual(stored.selectedSourceIDs, ["microphone"])
        XCTAssertEqual(recorder.state, .idle)
    }
    func testSourceControlsLockDuringPreparationButStopRemainsAvailable() throws {
        _ = NSApplication.shared
        let defaults = defaults(), recorder = AudioRecordingManager(defaults: defaults)
        let manager = AudioTranscriptionManager(recorder: recorder, defaults: defaults, engineFactory: { _ in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw CancellationError()
        })
        let controller = TranscriptionViewController(recorder: recorder, manager: manager)
        controller.loadViewIfNeeded()
        manager.start()
        defer { manager.stop() }
        XCTAssertEqual(manager.state, .preparing)
        let buttons = descendants(controller.view).compactMap { $0 as? NSButton }
        let sources = buttons.filter { $0.identifier?.rawValue.hasPrefix("transcription-source-") == true }
        XCTAssertFalse(sources.isEmpty)
        XCTAssertTrue(sources.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(try XCTUnwrap(buttons.first { $0.title == "Stop Transcription" }).isEnabled)
        XCTAssertEqual(recorder.state, .idle)
    }
    func testEmptyAndStaleSourcesShowGuidanceWithoutStartingCapture() throws {
        _ = NSApplication.shared
        let defaults = defaults(), recorder = AudioRecordingManager(defaults: defaults)
        var config = recorder.settings; config.microphoneEnabled = false; recorder.updateSettings(config)
        let controller = TranscriptionViewController(recorder: recorder)
        controller.loadViewIfNeeded()
        let fields = descendants(controller.view).compactMap { $0 as? NSTextField }
        XCTAssertTrue(fields.contains { $0.stringValue.hasPrefix("No sources enabled.") })
        XCTAssertTrue(fields.contains { $0.stringValue.hasPrefix("A previously selected source") })
        config.microphoneEnabled = true; config.outputMode = .applications; config.applicationBundleIDs = ["test.current-app"]
        recorder.updateSettings(config)
        var settings = recorder.transcription.settings; settings.sourceID = "test.previous-app"
        recorder.transcription.updateSettings(settings)
        let current = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "transcription-source-test.current-app" })
        current.performClick(nil)
        XCTAssertEqual(recorder.transcription.settings.selectedSourceIDs, ["test.current-app"])
        XCTAssertEqual(recorder.state, .idle)
    }
    func testFloatingPanelAllowsAnyMonitorCoordinatesAndNonactivatingTextFocus() {
        _ = NSApplication.shared
        let panel = TranscriptionCaptionPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 140),
                                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        for origin in [NSPoint(x: -2_500, y: 900), NSPoint(x: 4_000, y: -800)] {
            let frame = NSRect(origin: origin, size: NSSize(width: 620, height: 140))
            XCTAssertEqual(panel.constrainFrameRect(frame, to: NSScreen.main), frame)
        }
    }
    func testToastTextPreservesNewlinesAndIncludesTranslation() {
        let original = TranscriptSegment(id: "1", sourceID: "mic", language: "en-US", text: "First line\nSecond line", isFinal: true, offset: 0)
        let translation = TranscriptSegment(id: "1", sourceID: "mic", language: "es-ES", text: "Hola", isFinal: true, offset: 0, isTranslation: true)
        XCTAssertEqual(TranscriptionToastController.captionText([original, translation]).string, "First line\nSecond line\nes-ES  Hola")
    }
    func testToastTextLabelsConcurrentSourcesAndTranslations() {
        let original = TranscriptSegment(id: "1", sourceID: "mic", language: "en-US", text: "First line\nSecond line", isFinal: true, offset: 0)
        let translation = TranscriptSegment(id: "1", sourceID: "app", language: "es-ES", text: "Hola", isFinal: true, offset: 0, isTranslation: true)
        XCTAssertEqual(TranscriptionToastController.captionText([original, translation], sourceTitles: ["mic": "Microphone", "app": "Music"]).string,
                       "Microphone  First line\nSecond line\nMusic  es-ES  Hola")
    }
    func testCaptionSelectionSurvivesAppendFinalizationAndEarlierExpiry() throws {
        let old = TranscriptionToastController.captionText([segment("Earlier line", id: "old"), segment("Hello caf\u{00E9} \u{1F44B}", id: "selected")])
        let selection = (old.string as NSString).range(of: "caf\u{00E9} \u{1F44B}")
        let new = TranscriptionToastController.captionText([segment("Hello caf\u{00E9} \u{1F44B} again", id: "selected", final: true), segment("New line", id: "new")])
        let preserved = try XCTUnwrap(TranscriptionToastController.preservedSelection(selection, from: old, to: new))
        XCTAssertEqual(preserved, (new.string as NSString).range(of: "caf\u{00E9} \u{1F44B}"))
    }
    func testCaptionSelectionAcrossMultipleLinesSurvivesOtherCaptionUpdates() throws {
        let old = TranscriptionToastController.captionText([segment("Earlier line", id: "old"), segment("First sentence", id: "first"), segment("Second sentence", id: "second")])
        let new = TranscriptionToastController.captionText([segment("Changed earlier line", id: "old"), segment("First sentence", id: "first"), segment("Second sentence", id: "second"), segment("Later line", id: "later")])
        let selection = (old.string as NSString).range(of: "sentence\nSecond")
        let preserved = try XCTUnwrap(TranscriptionToastController.preservedSelection(selection, from: old, to: new))
        XCTAssertEqual(preserved, (new.string as NSString).range(of: "sentence\nSecond"))
    }
    func testCaptionSelectionClearsInsteadOfMovingToChangedOrRepeatedWords() {
        let old = TranscriptionToastController.captionText([segment("Repeated words", id: "selected"), segment("Repeated words", id: "other")])
        let selection = (old.string as NSString).range(of: "Repeated")
        let expired = TranscriptionToastController.captionText([segment("Repeated words", id: "other")])
        XCTAssertNil(TranscriptionToastController.preservedSelection(selection, from: old, to: expired))
        let changed = TranscriptionToastController.captionText([segment("Corrected words", id: "selected")])
        XCTAssertNil(TranscriptionToastController.preservedSelection(selection, from: old, to: changed))
        XCTAssertNil(TranscriptionToastController.preservedSelection(NSRange(location: NSNotFound, length: 1), from: old, to: changed))
        XCTAssertNil(TranscriptionToastController.preservedSelection(NSRange(location: old.length, length: 1), from: old, to: changed))
        XCTAssertNil(TranscriptionToastController.preservedSelection(NSRange(location: 0, length: 0), from: old, to: expired))
    }
    func testOpeningSettingsDoesNotCaptureAndControlsFitNarrowWindow() throws {
        _ = NSApplication.shared
        let suite = "astation-transcription-layout-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var requests = 0
        let recorder = AudioRecordingManager(defaults: defaults, captureFactory: { _ in
            requests += 1; throw AudioCaptureError.message("No hardware test")
        }, microphonePermission: { requests += 1; return false })
        var recording = recorder.settings; recording.outputMode = .system; recorder.updateSettings(recording)
        var selection = recorder.transcription.settings; selection.additionalSourceIDs = ["system"]
        recorder.transcription.updateSettings(selection)
        let controller = TranscriptionViewController(recorder: recorder)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = controller.view
        defer { window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let scroll = try XCTUnwrap(controller.view as? NSScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        for provider in TranscriptionProvider.allCases {
            var settings = recorder.transcription.settings
            settings.provider = provider
            settings.autoSaveTranscript = true
            settings.customEndpoint = "https://speech.example.test/v1/audio/transcriptions"
            recorder.transcription.updateSettings(settings)
            let picker = descendants(controller.view).compactMap { $0 as? NSPopUpButton }.first
            XCTAssertEqual(picker?.titleOfSelectedItem, settings.provider.title)
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            XCTAssertGreaterThan(document.frame.height, 400)
            XCTAssertLessThan(document.frame.height, 1_200)
            for view in descendants(controller.view) where !view.isHiddenOrHasHiddenAncestor {
                if view is NSButton || view is NSPopUpButton || view is NSTextField {
                    let frame = controller.view.convert(view.alignmentRect(forFrame: view.frame), from: view.superview!)
                    XCTAssertGreaterThanOrEqual(frame.minX, -1)
                    XCTAssertLessThanOrEqual(frame.maxX, 511)
                }
            }
            if let path = ProcessInfo.processInfo.environment["ASTATION_TRANSCRIPTION_UI_SNAPSHOT"] {
                let rep = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                controller.view.cacheDisplay(in: controller.view.bounds, to: rep)
                try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(path)-\(provider.rawValue).png"))
            }
        }
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertNil(recorder.transcription.downloadProgress)
    }
    func testLiveTranscriptionIsSeparateSettingsCategoryWithSourceNavigation() throws {
        let suite = "astation-transcription-sidebar-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = AudioRecordingManager(defaults: defaults)
        let recording = AudioRecordingViewController(manager: recorder, hotkeys: HotkeyManager(defaults: defaults))
        let transcription = TranscriptionViewController(recorder: recorder)
        let items = SettingsWindowController.audioTabItems(recording: recording, transcription: transcription)
        XCTAssertEqual(items.map { $0.identifier as? String }, ["recording", "transcription"])
        XCTAssertEqual(items.map(\.label), ["Audio & Recording", "Live Transcription"])
        XCTAssertTrue(items[0].viewController === recording)
        XCTAssertTrue(items[1].viewController === transcription)
        recording.loadViewIfNeeded(); transcription.loadViewIfNeeded()
        XCTAssertFalse(recording.children.contains { $0 is TranscriptionViewController })
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        XCTAssertFalse(descendants(recording.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Live Transcription" })
        var navigated = false
        transcription.onConfigureSources = { navigated = true }
        let configure = try XCTUnwrap(descendants(transcription.view).compactMap { $0 as? NSButton }.first { $0.title == "Configure Audio Sources..." })
        configure.performClick(nil)
        XCTAssertTrue(navigated)
        XCTAssertEqual(recorder.state, .idle)
        XCTAssertEqual(recorder.transcription.state, .idle)
    }
    func testModelPickerSwitchesProfilesAndUnlocksMultilingualInput() throws {
        _ = NSApplication.shared
        let recorder = AudioRecordingManager(defaults: defaults())
        let controller = TranscriptionViewController(recorder: recorder)
        let pickers = descendants(controller.view).compactMap { $0 as? NSPopUpButton }
        let models = try XCTUnwrap(pickers.first { $0.itemTitles == LocalTranscriptionModel.allCases.map(\.title) })
        let language = try XCTUnwrap(pickers.first { $0.itemTitles == TranscriptionViewController.languages.map(\.title) })
        let providers = try XCTUnwrap(pickers.first { $0.itemTitles == TranscriptionProvider.allCases.map(\.title) })
        XCTAssertFalse(language.isEnabled)
        for (index, profile) in LocalTranscriptionModel.allCases.enumerated() {
            models.selectItem(at: index)
            // Dispatch the bound action without presenting the popup menu.
            _ = models.sendAction(models.action!, to: models.target)
            XCTAssertEqual(recorder.transcription.settings.localModel, profile)
            XCTAssertEqual(language.isEnabled, !profile.isEnglishOnly)
        }
        providers.selectItem(at: 2); _ = providers.sendAction(providers.action!, to: providers.target)
        XCTAssertEqual(recorder.transcription.settings.provider, .custom)
        XCTAssertTrue(language.isEnabled)
        XCTAssertNotNil(descendants(controller.view).compactMap { $0 as? NSSecureTextField }.first)
    }
}
