import Foundation

/// Bounded 16 kHz windows for engines that decode files/windows rather than native streams.
struct SpeechWindowBuffer {
    struct Window: Sendable {
        let id: String
        let samples: [Float]
        let offset: TimeInterval
        let isFinal: Bool
    }
    private let maximumFrames: Int
    private let partialFrames: Int?
    private var samples: [Float] = []
    private var preroll: [Float] = []
    private var totalFrames = 0
    private var startFrame = 0
    private var quietFrames = 0
    private var decodedFrames = 0
    private var id = UUID().uuidString

    init(maximumSeconds: Int = 24, partialSeconds: Int? = 2) {
        maximumFrames = max(1, min(24, maximumSeconds)) * 16_000
        partialFrames = partialSeconds.map { max(1, $0) * 16_000 }
    }
    mutating func append(_ incoming: [Float]) -> [Window] {
        var windows: [Window] = []
        var begin = 0
        while begin < incoming.count {
            let remaining = maximumFrames - (samples.isEmpty ? preroll.count : samples.count)
            let end = min(begin + min(320, remaining), incoming.count)
            let frame = Array(incoming[begin..<end])
            begin = end
            let energy = frame.reduce(0.0) { $0 + ($1.isFinite ? Double($1) * Double($1) : 0) } / Double(frame.count)
            let speech = energy > 0.000009
            if samples.isEmpty && !speech {
                preroll.append(contentsOf: frame)
                if preroll.count > 3_200 { preroll.removeFirst(preroll.count - 3_200) }
                totalFrames += frame.count
                continue
            }
            if samples.isEmpty {
                startFrame = totalFrames - preroll.count
                samples = preroll; preroll.removeAll(keepingCapacity: true)
            }
            samples.append(contentsOf: frame); totalFrames += frame.count
            quietFrames = speech ? 0 : quietFrames + frame.count
            if quietFrames >= 12_800 || samples.count >= maximumFrames {
                windows.append(window(final: true)); reset()
            } else if let partialFrames, samples.count - decodedFrames >= partialFrames {
                windows.append(window(final: false)); decodedFrames = samples.count
            }
        }
        return windows
    }
    mutating func finish() -> Window? {
        guard !samples.isEmpty else { return nil }
        let result = window(final: true); reset(); return result
    }
    private func window(final: Bool) -> Window {
        Window(id: id, samples: samples, offset: Double(startFrame) / 16_000, isFinal: final)
    }
    private mutating func reset() {
        samples.removeAll(keepingCapacity: true); quietFrames = 0; decodedFrames = 0
        id = UUID().uuidString
    }
}
