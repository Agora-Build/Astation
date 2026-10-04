import AVFoundation

enum RTCNoiseReduction: Int32, CaseIterable {
    case off = -1, balanced = 0, aggressive = 1, lowLatency = 2
    var title: String {
        switch self {
        case .off: return "Standard Noise Suppression"
        case .balanced: return "AI - Balanced"
        case .aggressive: return "AI - Strong"
        case .lowLatency: return "AI - Lowest Latency"
        }
    }
}

/// Capture has its own lifetime. Channel and mute changes only gate publication.
final class RTCMicrophonePublisher {
    private let work = DispatchQueue(label: "build.agora.astation.rtc-microphone", qos: .userInitiated)
    private let captureFactory: (String?) throws -> NativeAudioCapturing
    private let permission: () async -> Bool
    private var stream: MicrophonePCMStream?
    private var preparation: Task<Void, Never>?
    private var generation = UUID()
    private var connected = false
    private var muted = false
    private var publicationBoundary: UInt64 = 0
    private var pending: [Int16] = []
    private var converter = TranscriptionAudioConverter(outputSampleRate: 48_000)
    var onPush: (([Int16]) throws -> Void)?
    var onError: ((Error) -> Void)?
    var onStateChanged: (() -> Void)?
    var isCapturing: Bool { stream != nil }
    var isPreparing: Bool { preparation != nil }

    init(captureFactory: @escaping (String?) throws -> NativeAudioCapturing = { try SharedMicrophoneCapture.shared.makeCapture(deviceUID: $0) },
         permission: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
        self.captureFactory = captureFactory; self.permission = permission
    }
    deinit { preparation?.cancel(); stream?.stop() }

    func start(deviceUID: String?) {
        guard stream == nil, preparation == nil else { return }
        let id = UUID(); generation = id
        let factory = captureFactory, permission = permission
        preparation = Task { @MainActor [weak self] in
            do {
                guard await permission() else { throw AudioCaptureError.message("RTC microphone permission is denied. The channel can still receive audio.") }
                try Task.checkCancellation()
                let capture = try await Task.detached(priority: .userInitiated) { try factory(deviceUID) }.value
                guard let self, self.generation == id, !Task.isCancelled else { capture.stop(); return }
                let stream = MicrophonePCMStream(capture: capture)
                self.stream = stream; self.preparation = nil
                stream.start(onPCM: { [weak self] pcm in try self?.consume(pcm) }, onError: { [weak self] error in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == id else { return }
                        self.stop(); self.onError?(error)
                    }
                })
                self.onStateChanged?()
            } catch {
                guard let self, self.generation == id else { return }
                self.preparation = nil
                if !Task.isCancelled { self.onError?(error) }
                self.onStateChanged?()
            }
        }
    }
    func setConnected(_ value: Bool) {
        work.sync { connected = value; publicationBoundary = mach_absolute_time(); resetPending() }
    }
    func setMuted(_ value: Bool) {
        work.sync { muted = value; publicationBoundary = mach_absolute_time(); resetPending() }
    }
    private func resetPending() {
        pending.removeAll(keepingCapacity: true)
        converter = TranscriptionAudioConverter(outputSampleRate: 48_000)
    }
    private func consume(_ pcm: TranscriptionPCM) throws {
        try work.sync {
            guard connected, !muted else { return }
            // Capture queues can still contain pre-join/pre-unmute audio; never replay it.
            guard pcm.hostTime == 0 || pcm.hostTime >= publicationBoundary else { return }
            let converted = try converter.convert(pcm)
            pending.append(contentsOf: converted.map(Self.pcm16))
            while pending.count >= 480 {
                try onPush?(Array(pending.prefix(480)))
                pending.removeFirst(480)
            }
        }
    }
    static func pcm16(_ sample: Float) -> Int16 {
        // Resampling can overshoot even when the native float input was bounded.
        sample.isFinite ? Int16((max(-1, min(1, sample)) * 32_767).rounded()) : 0
    }
    func stop() {
        generation = UUID(); preparation?.cancel(); preparation = nil
        stream?.stop(); stream = nil
        work.sync { resetPending() }
        onStateChanged?()
    }
}
