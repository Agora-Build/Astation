import AVFoundation
import Foundation

/// Only used on the recording worker queue. Tracks retain their own native rates.
final class AudioRecordingSession {
    let folder: URL
    private(set) var manifest: RecordingSessionManifest
    private let startTime: TimeInterval
    private var pauses: [(start: TimeInterval, end: TimeInterval?)] = []
    private var writers: [String: OriginalAudioTrackWriter] = [:]

    init(settings: AudioRecordingSettings, startTime: TimeInterval, date: Date = Date()) throws {
        self.startTime = startTime
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        folder = URL(fileURLWithPath: settings.folderPath, isDirectory: true)
            .appendingPathComponent("\(formatter.string(from: date))_\(UUID().uuidString.prefix(8))", isDirectory: true)
        manifest = RecordingSessionManifest(startedAt: date, settings: settings)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try saveManifest()
    }

    func elapsed(at time: TimeInterval) -> TimeInterval {
        max(0, time - startTime - pauses.reduce(0) { $0 + max(0, min(time, $1.end ?? time) - $1.start) })
    }

    func pause(at time: TimeInterval) throws {
        guard pauses.last?.end != nil || pauses.isEmpty else { return }
        pauses.append((time, nil))
        manifest.status = "paused"
        manifest.duration = elapsed(at: time)
        try saveManifest()
    }

    func resume(at time: TimeInterval) throws {
        guard let last = pauses.indices.last, pauses[last].end == nil else { return }
        pauses[last].end = time
        manifest.status = "recording"
        try saveManifest()
    }

    func addSource(_ source: AudioSourceSelection, format: AVAudioFormat) throws {
        guard writers[source.id] == nil else { return }
        writers[source.id] = try OriginalAudioTrackWriter(source: source, format: format, folder: folder,
                                                         settings: manifest.settings, index: writers.count + 1)
        try saveManifest()
    }

    func append(sourceID: String, samples: UnsafeBufferPointer<Float>, frames: Int,
                hostTime: TimeInterval, droppedFrames: UInt64) throws {
        guard let writer = writers[sourceID] else { return }
        let rate = writer.manifest.sampleRate
        let channels = writer.manifest.channels
        let end = hostTime + Double(frames) / rate
        var cursor = max(hostTime, startTime)
        func appendInterval(from begin: TimeInterval, to end: TimeInterval) throws {
            let first = max(0, min(frames, Int(((begin - hostTime) * rate).rounded())))
            let last = max(first, min(frames, Int(((end - hostTime) * rate).rounded())))
            guard last > first else { return }
            let part = UnsafeBufferPointer(rebasing: samples[(first * channels)..<(last * channels)])
            try writer.append(part, frames: last - first, time: elapsed(at: begin))
        }
        // A delayed callback can straddle start/pause/resume; trim by samples, not whole buffers.
        for pause in pauses where pause.start < end {
            let pauseEnd = pause.end ?? .infinity
            if pauseEnd <= cursor { continue }
            if pause.start > cursor { try appendInterval(from: cursor, to: min(end, pause.start)) }
            cursor = max(cursor, pauseEnd)
            if cursor >= end { break }
        }
        if cursor < end { try appendInterval(from: cursor, to: end) }
        writer.manifest.droppedFrames = droppedFrames
    }

    func updateDroppedFrames(sourceID: String, count: UInt64) { writers[sourceID]?.manifest.droppedFrames = count }

    func checkpoint(at time: TimeInterval) throws {
        manifest.duration = elapsed(at: time)
        try saveManifest()
    }

    func finish(at time: TimeInterval, error: String? = nil) throws {
        manifest.duration = elapsed(at: time)
        if let error { manifest.warnings.append(error) }
        manifest.status = error == nil ? "completed" : "failed"
        var finishError: Error?
        for writer in writers.values {
            do { try writer.finish(duration: manifest.duration, pad: error == nil) }
            catch { finishError = error; manifest.warnings.append(error.localizedDescription) }
        }
        if finishError != nil { manifest.status = "failed" }
        try saveManifest()
        if let finishError { throw finishError }
    }

    private func saveManifest() throws {
        manifest.tracks = writers.values.map(\.manifest).sorted { $0.sourceID < $1.sourceID }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("session.json"), options: .atomic)
    }
}

final class OriginalAudioTrackWriter {
    var manifest: RecordingTrackManifest
    private let format: AVAudioFormat
    private let folder: URL
    private let fileFormat: RecordingFileFormat
    private let prefix: String
    private let splitFrames: Int64
    private var file: AVAudioFile?
    private var totalFrames: Int64 = 0
    private let silence: AVAudioPCMBuffer

    init(source: AudioSourceSelection, format: AVAudioFormat, folder: URL,
         settings: AudioRecordingSettings, index: Int) throws {
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0,
              let native = NativeAudioFormat.floatPCM(sampleRate: format.sampleRate, channels: format.channelCount),
              let silence = AVAudioPCMBuffer(pcmFormat: native, frameCapacity: 4096) else {
            throw AudioCaptureError.message("Unsupported recording format.")
        }
        self.format = native
        self.silence = silence
        self.folder = folder
        fileFormat = settings.format
        let name = source.title.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "-" }.joined()
        prefix = "\(index)-\(String(name.prefix(48)))-original"
        // Keep WAV chunks safely below the classic RIFF 4 GiB limit.
        splitFrames = min(Int64(Double(settings.splitMinutes * 60) * format.sampleRate),
                          Int64(1_000_000_000 / (Int(format.channelCount) * MemoryLayout<Float>.size)))
        manifest = RecordingTrackManifest(sourceID: source.id, title: source.title,
                                          sampleRate: native.sampleRate, channels: Int(native.channelCount))
        silence.frameLength = silence.frameCapacity
        for channel in 0..<Int(native.channelCount) {
            silence.floatChannelData![channel].initialize(repeating: 0, count: Int(silence.frameCapacity))
        }
        try openSegment()
    }

    func append(_ samples: UnsafeBufferPointer<Float>, frames: Int, time: TimeInterval) throws {
        guard frames > 0, samples.count >= frames * Int(format.channelCount) else { return }
        let target = Int64((time * format.sampleRate).rounded())
        let gap = target - totalFrames
        // Allow sub-buffer clock jitter. Never discard original samples to chase a clock.
        if gap > max(2, Int64(format.sampleRate * 0.01)) {
            try writeSilence(frames: gap, reason: totalFrames == 0 ? "source started after session" : "capture gap")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw AudioCaptureError.message("Could not allocate a recording buffer.")
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(format.channelCount) {
            let output = buffer.floatChannelData![channel]
            for frame in 0..<frames { output[frame] = samples[frame * Int(format.channelCount) + channel] }
        }
        try write(buffer)
    }

    func finish(duration: TimeInterval, pad: Bool) throws {
        defer { file = nil }
        if pad {
            let trailing = Int64((duration * format.sampleRate).rounded()) - totalFrames
            if trailing > 0 { try writeSilence(frames: trailing, reason: "source silent or unavailable at session end") }
        }
    }

    private func openSegment() throws {
        file = nil
        let name = "\(prefix)-\(String(format: "%03d", manifest.segments.count + 1)).\(fileFormat.rawValue)"
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        file = try AVAudioFile(forWriting: folder.appendingPathComponent(name), settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
        manifest.segments.append(RecordingSegment(file: name, startFrame: totalFrames, frameCount: 0))
    }

    private func writeSilence(frames: Int64, reason: String) throws {
        manifest.gaps.append(RecordingGap(startFrame: totalFrames, frameCount: frames, reason: reason))
        var remaining = frames
        while remaining > 0 {
            silence.frameLength = AVAudioFrameCount(min(remaining, Int64(silence.frameCapacity)))
            try write(silence)
            remaining -= Int64(silence.frameLength)
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        var offset = 0
        while offset < Int(buffer.frameLength) {
            let index = manifest.segments.count - 1
            let capacity = splitFrames - manifest.segments[index].frameCount
            if capacity == 0 { try openSegment(); continue }
            let count = min(Int(capacity), Int(buffer.frameLength) - offset)
            if offset == 0 && count == Int(buffer.frameLength) {
                try file!.write(from: buffer)
            } else {
                guard let piece = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                    throw AudioCaptureError.message("Could not allocate a recording segment.")
                }
                piece.frameLength = AVAudioFrameCount(count)
                for channel in 0..<Int(format.channelCount) {
                    piece.floatChannelData![channel].update(from: buffer.floatChannelData![channel] + offset, count: count)
                }
                try file!.write(from: piece)
            }
            manifest.segments[index].frameCount += Int64(count)
            totalFrames += Int64(count)
            offset += count
        }
    }
}
