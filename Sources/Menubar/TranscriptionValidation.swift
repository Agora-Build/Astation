#if DEBUG
import AVFoundation

/// Explicit, file-only inference check: never asks for capture permission or joins RTC.
enum TranscriptionValidation {
    static func checkBundledResources() -> Int32 {
        do {
            for model in LocalTranscriptionModel.allCases {
                let manifest = try TranscriptionModelManifest.bundled(for: model)
                try manifest.validate()
                guard manifest.id == model.id else {
                    throw TranscriptionError.message("The bundled manifest does not match \(model.name).")
                }
                print("PASS: bundled \(model.name) manifest.")
            }
            return 0
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return 1
        }
    }

    static func run() -> Int32 {
        func argument(_ name: String) -> String? {
            guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
            return CommandLine.arguments[index + 1]
        }
        guard let root = argument("--model-root"), let speech = argument("--speech-file") else {
            print("Use --transcription-check --model-root <directory> --speech-file <wav> [--local-model parakeet|whisperTurbo|whisperLarge] [--download-model]")
            return 1
        }
        guard let model = LocalTranscriptionModel(rawValue: argument("--local-model") ?? "parakeet") else {
            print("Unknown --local-model. Use parakeet, whisperTurbo, or whisperLarge."); return 1
        }
        let download = CommandLine.arguments.contains("--download-model")
        Task.detached {
            let engine: LiveTranscribing
            do {
                let store = TranscriptionModelStore(root: URL(fileURLWithPath: root, isDirectory: true))
                if download {
                    let manifest = try TranscriptionModelManifest.bundled(for: model)
                    print("Downloading pinned \(model.name) (\(manifest.totalBytes / 1_000_000) MB) into the explicit validation directory.")
                    try await store.download(manifest: manifest) { _ in }
                }
                let directory = try await store.verifiedDirectory(for: model)
                var settings = TranscriptionSettings(); settings.localModel = model; settings.sourceID = "fixture"
                engine = model == .parakeet ? LocalParakeetTranscriber(directory: directory, sourceID: "fixture")
                    : LocalWhisperTranscriber(directory: directory, settings: settings)
                let result = ValidationTranscript()
                do {
                    try await engine.start { result.update($0) }
                    let file = try AVAudioFile(forReading: URL(fileURLWithPath: speech), commonFormat: .pcmFormatFloat32, interleaved: true)
                    let converter = TranscriptionAudioConverter()
                    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_600)!
                    while file.framePosition < file.length {
                        try file.read(into: buffer)
                        let count = Int(buffer.frameLength) * Int(buffer.format.channelCount)
                        let pcm = TranscriptionPCM(samples: Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count)),
                                                   sampleRate: buffer.format.sampleRate, channels: Int(buffer.format.channelCount))
                        try await engine.consume(converter.convert(pcm))
                    }
                    let tail = try converter.finish()
                    if !tail.isEmpty { try await engine.consume(tail) }
                    try await engine.consume([Float](repeating: 0, count: 32_000))
                    try await engine.finish()
                    await engine.cancel()
                    let text = result.text
                    guard !text.isEmpty else { throw TranscriptionError.message("No speech was recognized.") }
                    print("TRANSCRIPT: \(text)")
                    print("PASS: real local streaming inference, no microphone or cloud session.")
                    exit(0)
                } catch { await engine.cancel(); throw error }
            } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
        RunLoop.main.run()
        return 1
    }
}
private final class ValidationTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = TranscriptBuffer()
    func update(_ segment: TranscriptSegment) { lock.withLock { buffer.update(segment) } }
    var text: String { lock.withLock { buffer.segments.map(\.text).joined(separator: " ") } }
}
#endif
