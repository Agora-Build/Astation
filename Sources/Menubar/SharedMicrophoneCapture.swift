import AVFoundation
import CoreAudio
import CStationCore

private final class MicrophoneLeaseStatus {
    private let lock = NSLock()
    private var failure: Error?
    func fail(_ error: Error) { lock.withLock { failure = error } }
    func check() throws { if let error = lock.withLock({ failure }) { throw error } }
}

/// One native capture per device; fan-out happens off the realtime audio callback.
/// Each consumer has its own bounded queue and releases only its own lease.
final class SharedMicrophoneCapture {
    static let shared = SharedMicrophoneCapture()
    private final class Entry {
        let capture: NativeAudioCapturing
        var subscribers: [UUID: (OpaquePointer, MicrophoneLeaseStatus)] = [:]
        var samples: [Float]
        var recoveries: [TimeInterval] = []
        let droppedBaseline: UInt64
        init(_ capture: NativeAudioCapturing) {
            self.capture = capture
            droppedBaseline = astation_audio_queue_dropped_frames(capture.queue)
            samples = [Float](repeating: 0, count: 4096 * Int(capture.format.channelCount))
        }
    }
    private let work = DispatchQueue(label: "build.agora.astation.shared-microphone", qos: .userInitiated)
    private let factory: (String?) throws -> NativeAudioCapturing
    private let resolveDevice: (String?) -> String
    private var entries: [String: Entry] = [:]
    private var timer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?

    init(factory: @escaping (String?) throws -> NativeAudioCapturing = { try MicrophoneAudioCapture(deviceUID: $0) },
         resolveDevice: @escaping (String?) -> String = SharedMicrophoneCapture.deviceKey) {
        self.factory = factory; self.resolveDevice = resolveDevice
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] notification in
            let object = notification.object
            self?.work.async { [weak self] in self?.recover(object) }
        }
    }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        timer?.cancel()
        for entry in entries.values { entry.capture.stop() }
    }

    private static func deviceKey(_ uid: String?) -> String {
        if let uid { return uid }
        var device = AudioObjectID(0)
        try? AudioHardware.read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, into: &device)
        return AudioHardware.string(device, kAudioDevicePropertyDeviceUID) ?? "system-default"
    }

    func makeCapture(deviceUID: String?) throws -> NativeAudioCapturing {
        try work.sync {
            let key = resolveDevice(deviceUID)
            let entry: Entry
            if let existing = entries[key] { entry = existing }
            else { entry = Entry(try factory(deviceUID)); entries[key] = entry }
            guard let queue = astation_audio_queue_create(entry.capture.format.channelCount, 4096, 64) else {
                if entry.subscribers.isEmpty { entry.capture.stop(); entries.removeValue(forKey: key) }
                throw AudioCaptureError.message("Cannot allocate a microphone consumer queue.")
            }
            let id = UUID(), status = MicrophoneLeaseStatus()
            entry.subscribers[id] = (queue, status)
            if timer == nil {
                let timer = DispatchSource.makeTimerSource(queue: work)
                timer.schedule(deadline: .now(), repeating: .milliseconds(10))
                timer.setEventHandler { [weak self] in self?.drain() }
                self.timer = timer; timer.resume()
            }
            return SharedMicrophoneLease(queue: queue, format: entry.capture.format, status: status) { [self] in
                work.sync {
                    guard let current = entries[key], current === entry else { return }
                    current.subscribers.removeValue(forKey: id)
                    if current.subscribers.isEmpty { current.capture.stop(); entries.removeValue(forKey: key) }
                    if entries.isEmpty { timer?.cancel(); timer = nil }
                }
            }
        }
    }

    private func drain() {
        for (key, entry) in entries {
            do {
                try entry.capture.checkStatus()
                guard astation_audio_queue_dropped_frames(entry.capture.queue) == entry.droppedBaseline else {
                    throw AudioCaptureError.message("The native microphone dropped audio. Restart the affected audio features; original audio is never silently filled in.")
                }
            } catch {
                for (_, status) in entry.subscribers.values { status.fail(error) }
                entry.capture.stop(); entries.removeValue(forKey: key)
                continue
            }
            entry.samples.withUnsafeMutableBufferPointer { storage in
                var hostTime: UInt64 = 0
                while true {
                    let frames = astation_audio_queue_pop(entry.capture.queue, storage.baseAddress!, 4096, &hostTime)
                    if frames == 0 { break }
                    var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                        mNumberChannels: entry.capture.format.channelCount,
                        mDataByteSize: frames * entry.capture.format.channelCount * 4, mData: storage.baseAddress))
                    for (queue, _) in entry.subscribers.values {
                        astation_audio_queue_push(queue, &buffers, frames, hostTime, entry.capture.format.sampleRate)
                    }
                }
            }
        }
        if entries.isEmpty { timer?.cancel(); timer = nil }
    }

    private func recover(_ object: Any?) {
        for (key, entry) in entries {
            guard let capture = entry.capture as? MicrophoneConfigurationHandling, capture.ownsEngine(object) else { continue }
            do {
                let now = ProcessInfo.processInfo.systemUptime
                entry.recoveries = entry.recoveries.filter { now - $0 < 5 }
                guard entry.recoveries.count < 3 else { throw AudioCaptureError.message("The microphone keeps reconfiguring. Restart the affected audio features.") }
                entry.recoveries.append(now)
                try capture.recoverAfterConfigurationChange()
            } catch {
                for (_, status) in entry.subscribers.values { status.fail(error) }
                capture.stop(); entries.removeValue(forKey: key)
            }
        }
        if entries.isEmpty { timer?.cancel(); timer = nil }
    }
}

private final class SharedMicrophoneLease: NativeAudioCapturing {
    let queue: OpaquePointer
    let format: AVAudioFormat
    private let status: MicrophoneLeaseStatus
    private let lock = NSLock()
    private var release: (() -> Void)?
    init(queue: OpaquePointer, format: AVAudioFormat, status: MicrophoneLeaseStatus, release: @escaping () -> Void) {
        self.queue = queue; self.format = format; self.status = status; self.release = release
    }
    func checkStatus() throws { try status.check() }
    func stop() {
        let action = lock.withLock { let action = release; release = nil; return action }
        action?()
    }
    deinit { stop(); astation_audio_queue_destroy(queue) }
}

/// Drains a lease on its own worker; RTC/inference never blocks native capture or recording.
final class MicrophonePCMStream {
    private let capture: NativeAudioCapturing
    private let work = DispatchQueue(label: "build.agora.astation.mic-consumer", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var samples: [Float]
    private let workerKey = DispatchSpecificKey<Bool>()
    private var stopped = false
    private var onPCM: ((TranscriptionPCM) throws -> Void)?
    private var onError: ((Error) -> Void)?
    init(capture: NativeAudioCapturing) {
        self.capture = capture
        samples = [Float](repeating: 0, count: 4096 * Int(capture.format.channelCount))
        work.setSpecific(key: workerKey, value: true)
    }
    func start(onPCM: @escaping (TranscriptionPCM) throws -> Void, onError: @escaping (Error) -> Void) {
        onWorker {
            guard timer == nil, !stopped else { return }
            self.onPCM = onPCM; self.onError = onError
            let timer = DispatchSource.makeTimerSource(queue: work)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10))
            timer.setEventHandler { [weak self] in self?.drain() }
            self.timer = timer; timer.resume()
        }
    }
    private func drain() {
        guard !stopped else { return }
        do {
            try capture.checkStatus()
            guard astation_audio_queue_dropped_frames(capture.queue) == 0 else {
                throw AudioCaptureError.message("This microphone consumer could not keep up and dropped audio. Restart it or choose a faster model.")
            }
            try samples.withUnsafeMutableBufferPointer { storage in
                var time: UInt64 = 0
                while true {
                    let count = astation_audio_queue_pop(capture.queue, storage.baseAddress!, 4096, &time)
                    if count == 0 { break }
                    try onPCM?(TranscriptionPCM(samples: Array(storage.prefix(Int(count) * Int(capture.format.channelCount))),
                        sampleRate: capture.format.sampleRate, channels: Int(capture.format.channelCount), hostTime: time))
                }
            }
        } catch {
            stopped = true; timer?.cancel(); timer = nil; capture.stop()
            onError?(error); onError = nil; onPCM = nil
        }
    }
    func stop() {
        onWorker {
            guard !stopped else { return }
            timer?.cancel(); timer = nil
            drain()
            if !stopped { capture.stop() }
            stopped = true; onPCM = nil; onError = nil
        }
    }
    private func onWorker(_ action: () -> Void) {
        if DispatchQueue.getSpecific(key: workerKey) == true { action() } else { work.sync(execute: action) }
    }
    deinit { timer?.cancel(); if !stopped { capture.stop() } }
}
