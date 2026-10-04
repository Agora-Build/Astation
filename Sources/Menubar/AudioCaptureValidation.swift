#if DEBUG
import AppKit
import AVFoundation
import CoreAudio
import CStationCore

/// Explicit development probe: capture generated test tones, never the microphone.
enum AudioCaptureValidation {
    @available(macOS 14.2, *)
    static func run() -> Int32 {
        do {
            print("Starting native selected-process capture probe.")
            fflush(stdout)
            _ = NSApplication.shared
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("astation-audio-native-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let first = root.appendingPathComponent("selected-440.wav")
            let second = root.appendingPathComponent("excluded-990.wav")
            try writeTone(to: first, frequency: 440)
            try writeTone(to: second, frequency: 990)
            let selected = try play(first)
            defer { if selected.isRunning { selected.terminate() }; selected.waitUntilExit() }
            let excluded = try play(second)
            defer { if excluded.isRunning { excluded.terminate() }; excluded.waitUntilExit() }
            var processIDs: [AudioObjectID] = []
            let discoveryDeadline = Date().addingTimeInterval(3)
            while Date() < discoveryDeadline && processIDs.isEmpty {
                processIDs = AudioHardware.objects(kAudioHardwarePropertyProcessObjectList).filter {
                    var pid: pid_t = 0
                    try? AudioHardware.read($0, kAudioProcessPropertyPID, into: &pid)
                    return pid == selected.processIdentifier
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            guard !processIDs.isEmpty else { throw AudioCaptureError.message("The test player did not register an audio process.") }
            print("Requesting system-audio capture. Allow Astation access if macOS asks.")
            fflush(stdout)
            let capture = try ProcessAudioCapture(processes: processIDs, system: false)
            defer { capture.stop() }
            print("Waiting for generated audio. Allow Astation system-audio access if macOS asks.")
            fflush(stdout)
            var samples = [Float](repeating: 0, count: 4096 * Int(capture.format.channelCount))
            let warmupDeadline = Date().addingTimeInterval(20)
            var foundSound = false
            while Date() < warmupDeadline && !foundSound {
                samples.withUnsafeMutableBufferPointer { buffer in
                    var host: UInt64 = 0
                    let frames = astation_audio_queue_pop(capture.queue, buffer.baseAddress!, 4096, &host)
                    foundSound = buffer.prefix(Int(frames) * Int(capture.format.channelCount)).contains { abs($0) > 0.001 }
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            guard foundSound else { throw AudioCaptureError.message("No test audio arrived. Check system-audio permission for Astation and launch the probe through its .app bundle.") }
            let source = AudioSourceSelection(id: "generated-test-player", title: "Selected Test Player", kind: .application("generated-test-player"))
            var settings = AudioRecordingSettings()
            settings.microphoneEnabled = false
            settings.outputMode = .applications
            settings.applicationBundleIDs = [source.id]
            settings.folderPath = root.path
            let session = try AudioRecordingSession(settings: settings, startTime: AudioRecordingManager.hostSeconds)
            try session.addSource(source, format: capture.format)
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                try samples.withUnsafeMutableBufferPointer { buffer in
                    var hostTime: UInt64 = 0
                    while true {
                        let frames = astation_audio_queue_pop(capture.queue, buffer.baseAddress!, 4096, &hostTime)
                        if frames == 0 { break }
                        try session.append(sourceID: source.id, samples: UnsafeBufferPointer(buffer), frames: Int(frames),
                                           hostTime: AVAudioTime.seconds(forHostTime: hostTime), droppedFrames: 0)
                    }
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            capture.stop()
            let dropped = astation_audio_queue_dropped_frames(capture.queue)
            session.updateDroppedFrames(sourceID: source.id, count: dropped)
            try session.finish(at: AudioRecordingManager.hostSeconds)
            let track = session.manifest.tracks[0]
            let file = try AVAudioFile(forReading: session.folder.appendingPathComponent(track.segments[0].file))
            let data = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length))!
            try file.read(into: data)
            let wanted = magnitude(data, frequency: 440)
            let unwanted = magnitude(data, frequency: 990)
            print("Native capture: \(track.sampleRate) Hz, \(track.channels) channels, \(file.length) frames")
            print(String(format: "Selected tone: %.6f; excluded tone: %.6f; dropped frames: %llu", wanted, unwanted, dropped))
            print("Artifacts: \(session.folder.path)")
            guard wanted > 0.001, unwanted < wanted * 0.03, dropped == 0 else {
                throw AudioCaptureError.message("Native app isolation was not verified. Grant system-audio access if macOS requested it, then rerun the probe.")
            }
            print("PASS: selected-process capture preserves its tone and excludes the other process.")
            return 0
        } catch {
            print("FAIL: \(error.localizedDescription)")
            return 1
        }
    }

    private static func writeTone(to url: URL, frequency: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000 * 60)!
        buffer.frameLength = buffer.frameCapacity
        let increment = 2 * Double.pi * frequency / format.sampleRate
        for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][frame] = Float(0.02 * sin(Double(frame) * increment)) }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }

    private static func play(_ url: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        process.arguments = [url.path]
        try process.run()
        return process
    }

    private static func magnitude(_ buffer: AVAudioPCMBuffer, frequency: Double) -> Double {
        let data = buffer.floatChannelData![0]
        let count = Int(buffer.frameLength)
        let increment = 2 * Double.pi * frequency / buffer.format.sampleRate
        var sine = 0.0
        var cosine = 0.0
        for frame in 0..<count {
            let angle = Double(frame) * increment
            sine += Double(data[frame]) * sin(angle)
            cosine += Double(data[frame]) * cos(angle)
        }
        return 2 * sqrt(sine * sine + cosine * cosine) / Double(max(1, count))
    }
}
#endif
