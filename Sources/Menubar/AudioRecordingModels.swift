import Foundation

enum RecordingOutputMode: String, Codable, CaseIterable {
    case none, applications, system
    var title: String {
        switch self {
        case .none: return "Microphone only"
        case .applications: return "Selected applications"
        case .system: return "All system audio"
        }
    }
}

enum RecordingFileFormat: String, Codable, CaseIterable {
    case caf, wav
    var title: String { rawValue.uppercased() + " (lossless)" }
}

struct AudioRecordingSettings: Codable, Equatable {
    var microphoneEnabled = true
    var microphoneUID: String?
    var outputMode: RecordingOutputMode = .none
    var applicationBundleIDs: [String] = []
    var format: RecordingFileFormat = .caf
    var splitMinutes = 30
    var folderPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        .first!.appendingPathComponent("Astation", isDirectory: true)
        .appendingPathComponent("Recordings", isDirectory: true).path

    var validationError: String? {
        if !microphoneEnabled && outputMode == .none { return "Select a microphone or an audio output source." }
        if outputMode == .applications && applicationBundleIDs.isEmpty { return "Select at least one application." }
        if ![15, 30, 60].contains(splitMinutes) { return "Choose a 15, 30, or 60 minute file length." }
        if !folderPath.hasPrefix("/") { return "Choose an absolute recording folder." }
        return nil
    }
}

struct AudioSourceSelection: Hashable {
    let id: String
    let title: String
    let kind: Kind
    enum Kind: Hashable { case microphone(String?), application(String), system }
}

struct WaveformBin: Equatable {
    var minimum: Float = 0
    var maximum: Float = 0
}

struct AudioMeterSnapshot {
    var lanes: [[WaveformBin]] = []
    var rmsDB: Double = -120
    var peakDB: Double = -120
    var lastAudioTime: TimeInterval = 0
    var lastClipTime: TimeInterval = 0
    var droppedFrames: UInt64 = 0

    func hasRecentAudio(at time: TimeInterval) -> Bool {
        lastAudioTime > 0 && time - lastAudioTime < 1
    }
}

enum AudioSourceActivity: Equatable {
    case off, waiting, silence, sound, clipping

    var title: String {
        switch self {
        case .off: return "Preview off"
        case .waiting: return "Waiting for audio samples"
        case .silence: return "Listening: silence"
        case .sound: return "Sound detected"
        case .clipping: return "Clipping"
        }
    }
}

struct AudioSourceActivityTracker {
    private(set) var activity: AudioSourceActivity = .off
    private var lastSoundTime: TimeInterval?

    mutating func update(_ snapshot: AudioMeterSnapshot, capturing: Bool, now: TimeInterval) -> AudioSourceActivity {
        guard capturing, snapshot.hasRecentAudio(at: now) else {
            lastSoundTime = nil
            activity = capturing ? .waiting : .off
            return activity
        }
        // Separate enter/exit thresholds and a short hold avoid speech/noise-floor chatter.
        let soundThreshold = activity == .sound || activity == .clipping ? -66.0 : -60.0
        if snapshot.peakDB > soundThreshold { lastSoundTime = now }
        let clipping = snapshot.lastClipTime > 0 && now - snapshot.lastClipTime < 1
        let sound = lastSoundTime.map { now - $0 < 0.4 } ?? false
        activity = clipping ? .clipping : sound ? .sound : .silence
        return activity
    }
}

/// Fixed-duration summaries, independent of the hardware callback's buffer size.
struct AudioWaveformAccumulator {
    let channels: Int
    let sampleRate: Double
    private var histories: [[WaveformBin]]
    private var current: [WaveformBin]
    private var binFrames = 0
    private var sumSquares: Double = 0
    private var peak: Float = 0
    private var windowFrames = 0
    private var lastWaveformTime: TimeInterval = 0
    private var snapshot = AudioMeterSnapshot()
    private var framesPerBin: Int { max(1, Int(sampleRate / 30)) }

    init(channels: Int, sampleRate: Double) {
        self.channels = channels
        self.sampleRate = sampleRate
        histories = Array(repeating: [], count: min(channels, 2))
        current = Array(repeating: WaveformBin(), count: min(channels, 2))
    }

    mutating func consume(_ samples: UnsafeBufferPointer<Float>, frames: Int, now: TimeInterval) {
        for frame in 0..<frames {
            for channel in 0..<channels {
                let raw = samples[frame * channels + channel]
                let value = raw.isFinite ? raw : 0
                sumSquares += Double(value) * Double(value)
                peak = max(peak, abs(value))
                if channel < current.count {
                    current[channel].minimum = min(current[channel].minimum, value)
                    current[channel].maximum = max(current[channel].maximum, value)
                }
            }
            binFrames += 1
            windowFrames += 1
            if binFrames >= framesPerBin {
                for channel in current.indices {
                    histories[channel].append(current[channel])
                    if histories[channel].count > 150 { histories[channel].removeFirst() }
                    current[channel] = WaveformBin()
                }
                binFrames = 0
            }
        }
        lastWaveformTime = now + Double(frames) / sampleRate
        snapshot.lastAudioTime = lastWaveformTime
    }

    mutating func takeSnapshot(now: TimeInterval, droppedFrames: UInt64) -> AudioMeterSnapshot {
        if windowFrames > 0 {
            let rms = sqrt(sumSquares / Double(windowFrames * channels))
            snapshot.rmsDB = Self.decibels(rms)
            snapshot.peakDB = Self.decibels(Double(peak))
            if peak >= 0.999 { snapshot.lastClipTime = now }
        } else if !snapshot.hasRecentAudio(at: now) {
            snapshot.rmsDB = -120
            snapshot.peakDB = -120
            // Empty worker polls are not silent audio. Only age history after a real timeout.
            if snapshot.lastAudioTime > 0 {
                let elapsedBins = max(0, Int((now - lastWaveformTime) * 30))
                if elapsedBins > 0 {
                    let emptyBins = [WaveformBin](repeating: WaveformBin(), count: min(150, elapsedBins))
                    for channel in histories.indices {
                        histories[channel].append(contentsOf: emptyBins)
                        if histories[channel].count > 150 { histories[channel].removeFirst(histories[channel].count - 150) }
                    }
                    lastWaveformTime += Double(elapsedBins) / 30
                }
            }
        }
        sumSquares = 0
        peak = 0
        windowFrames = 0
        snapshot.lanes = histories
        snapshot.droppedFrames = droppedFrames
        return snapshot
    }

    static func decibels(_ amplitude: Double) -> Double { max(-120, 20 * log10(max(amplitude, 1e-6))) }
}

struct RecordingGap: Codable {
    let startFrame: Int64
    let frameCount: Int64
    let reason: String
}

struct RecordingSegment: Codable {
    let file: String
    let startFrame: Int64
    var frameCount: Int64
}

struct RecordingTrackManifest: Codable {
    let sourceID: String
    let title: String
    let sampleRate: Double
    let channels: Int
    var segments: [RecordingSegment] = []
    var gaps: [RecordingGap] = []
    var droppedFrames: UInt64 = 0
}

struct RecordingSessionManifest: Codable {
    var version = 1
    let startedAt: Date
    var status = "recording"
    var duration: TimeInterval = 0
    let settings: AudioRecordingSettings
    var tracks: [RecordingTrackManifest] = []
    var warnings: [String] = []
}
