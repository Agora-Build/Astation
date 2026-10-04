import AVFoundation
import CoreML
import FluidAudio

final class TranscriptionAudioConverter {
    private var converter: AVAudioConverter?
    private var rate: Double = 0
    private var channels = 0
    private let outputFormat: AVAudioFormat
    init(outputSampleRate: Double = 16_000) {
        outputFormat = AVAudioFormat(standardFormatWithSampleRate: outputSampleRate, channels: 1)!
    }
    func convert(_ pcm: TranscriptionPCM) throws -> [Float] {
        guard pcm.sampleRate >= 8_000, pcm.sampleRate <= 192_000, pcm.channels > 0, pcm.channels <= 32,
              !pcm.samples.isEmpty, pcm.samples.count % pcm.channels == 0 else {
            throw TranscriptionError.message("Unsupported transcription audio format.")
        }
        let frames = pcm.samples.count / pcm.channels
        let clean = pcm.samples.map { $0.isFinite ? max(-1, min(1, $0)) : 0 }
        // Discrete aggregate lanes have no speaker layout. Average explicitly instead of
        // relying on Core Audio's speaker-layout downmix (which can discard these lanes).
        let mono: [Float]
        if pcm.channels == 1 { mono = clean }
        else {
            mono = stride(from: 0, to: clean.count, by: pcm.channels).map { start in
                clean[start..<(start + pcm.channels)].reduce(0, +) / Float(pcm.channels)
            }
        }
        if pcm.sampleRate == outputFormat.sampleRate { return mono }
        guard let inputFormat = NativeAudioFormat.floatPCM(sampleRate: pcm.sampleRate,
                channels: 1, interleaved: true) else {
            throw TranscriptionError.message("Unsupported transcription audio format.")
        }
        if rate != pcm.sampleRate || channels != pcm.channels {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            rate = pcm.sampleRate; channels = pcm.channels
        }
        guard let converter else { throw TranscriptionError.message("Cannot convert the selected source for transcription.") }
        let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames))!
        input.frameLength = AVAudioFrameCount(frames)
        mono.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
        let capacity = AVAudioFrameCount(ceil(Double(frames) * outputFormat.sampleRate / rate) + 256)
        let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity)!
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        if result == .error { throw error ?? TranscriptionError.message("Audio conversion failed.") as NSError }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
    func finish() throws -> [Float] {
        guard let converter else { return [] }
        var samples: [Float] = []
        for _ in 0..<4 {
            let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1_024)!
            var error: NSError?
            let result = converter.convert(to: output, error: &error) { _, status in status.pointee = .endOfStream; return nil }
            if result == .error { throw error ?? TranscriptionError.message("Audio conversion could not finish.") as NSError }
            samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            if result == .endOfStream || output.frameLength == 0 { break }
        }
        self.converter = nil; rate = 0; channels = 0
        return samples
    }
}

actor LocalParakeetTranscriber: LiveTranscribing {
    private let directory: URL
    private let sourceID: String
    private let manager: StreamingEouAsrManager
    private let events = ParakeetTranscriptEvents()
    private var samplesConsumed = 0
    init(directory: URL, sourceID: String) {
        self.directory = directory; self.sourceID = sourceID
        let config = MLModelConfiguration()
        #if arch(arm64)
        config.computeUnits = .cpuAndNeuralEngine
        #else
        config.computeUnits = .cpuOnly
        #endif
        manager = StreamingEouAsrManager(configuration: config, chunkSize: .ms320, eouDebounceMs: 800)
    }
    func start(onSegment: @escaping @Sendable (TranscriptSegment) -> Void) async throws {
        events.configure(sourceID: sourceID, callback: onSegment)
        // Only read installed files: starting captions never triggers a model download.
        try await manager.loadModels(from: directory)
        await manager.setPartialCallback { [events] text in events.emit(text, final: false) }
        await manager.setEouCallback { [events] text in events.emit(text, final: true) }
    }
    func consume(_ samples: [Float]) async throws {
        guard !samples.isEmpty else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        _ = try await manager.process(audioBuffer: buffer)
        samplesConsumed += samples.count
        if await manager.eouDetected {
            await manager.reset()
            events.nextUtterance(offset: Double(samplesConsumed) / 16_000)
        }
    }
    func finish() async throws { events.emit(try await manager.finish(), final: true) }
    func cancel() async { await manager.cleanup() }
}

private final class ParakeetTranscriptEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var sourceID = ""
    private var id = UUID().uuidString
    private var offset: TimeInterval = 0
    private var callback: (@Sendable (TranscriptSegment) -> Void)?
    func configure(sourceID: String, callback: @escaping @Sendable (TranscriptSegment) -> Void) {
        lock.lock(); self.sourceID = sourceID; self.callback = callback; lock.unlock()
    }
    func nextUtterance(offset: TimeInterval) { lock.lock(); id = UUID().uuidString; self.offset = offset; lock.unlock() }
    func emit(_ text: String, final: Bool) {
        lock.lock()
        let segment = TranscriptSegment(id: id, sourceID: sourceID, language: "en-US", text: text,
                                        isFinal: final, offset: offset)
        let callback = self.callback
        lock.unlock()
        callback?(segment)
    }
}
