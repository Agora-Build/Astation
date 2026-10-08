import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import CStationCore

enum AudioCaptureError: LocalizedError {
    case message(String)
    case coreAudio(String, OSStatus)
    case microphoneFormatChanged(previous: String, current: String)
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .coreAudio(let action, let status):
            return "\(action) failed (\(status)). Check Microphone or Screen & System Audio Recording permissions in System Settings."
        case .microphoneFormatChanged(let previous, let current):
            return "The microphone's audio format changed from \(previous) to \(current)."
        }
    }
}

enum AudioHardware {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        into value: inout T) throws {
        var property = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, UnsafeMutableRawPointer($0))
        }
        try check(status, "Read audio device")
    }

    static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var property = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !result.isEmpty else { return [] }
        let status = result.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? result : []
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var result: Unmanaged<CFString>?
        guard (try? read(object, selector, into: &result)) != nil else { return nil }
        return result?.takeRetainedValue() as String?
    }

    static func check(_ status: OSStatus, _ operation: String) throws {
        if status != noErr { throw AudioCaptureError.coreAudio(operation, status) }
    }
}

struct RecordingMicrophone {
    let deviceID: AudioObjectID
    let uid: String
    let name: String
}

struct RecordingApplication {
    let bundleID: String
    let name: String
    let icon: NSImage?
    var processIDs: [AudioObjectID]
}

enum AudioSourceCatalog {
    static func microphones() -> [RecordingMicrophone] {
        AudioHardware.objects(kAudioHardwarePropertyDevices).compactMap { device in
            var property = AudioHardware.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size) == noErr, size > 0 else { return nil }
            let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { storage.deallocate() }
            guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, storage) == noErr else { return nil }
            let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
            guard buffers.reduce(0, { $0 + $1.mNumberChannels }) > 0,
                  let uid = AudioHardware.string(device, kAudioDevicePropertyDeviceUID) else { return nil }
            return RecordingMicrophone(deviceID: device, uid: uid,
                                       name: AudioHardware.string(device, kAudioObjectPropertyName) ?? "Microphone")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @available(macOS 14.2, *)
    static func applications() -> [RecordingApplication] {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        let byPID = Dictionary(running.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        var grouped: [String: RecordingApplication] = [:]
        for app in running {
            guard let bundleID = app.bundleIdentifier else { continue }
            grouped[bundleID] = RecordingApplication(bundleID: bundleID, name: app.localizedName ?? bundleID,
                                                     icon: app.icon, processIDs: [])
        }
        for process in AudioHardware.objects(kAudioHardwarePropertyProcessObjectList) {
            var pid: pid_t = 0
            guard (try? AudioHardware.read(process, kAudioProcessPropertyPID, into: &pid)) != nil else { continue }
            var ancestor = pid
            var app: NSRunningApplication?
            for _ in 0..<32 {
                if let match = byPID[ancestor] { app = match; break }
                let parent = astation_audio_parent_pid(ancestor)
                if parent <= 1 || parent == ancestor { break }
                ancestor = parent
            }
            let identity = app?.bundleIdentifier ?? AudioHardware.string(process, kAudioProcessPropertyBundleID)
            if let identity, grouped[identity] != nil { grouped[identity]?.processIDs.append(process) }
        }
        return grouped.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @available(macOS 14.2, *)
    static func ownProcessIDs() -> [AudioObjectID] {
        AudioHardware.objects(kAudioHardwarePropertyProcessObjectList).filter {
            var pid: pid_t = 0
            try? AudioHardware.read($0, kAudioProcessPropertyPID, into: &pid)
            return pid == ProcessInfo.processInfo.processIdentifier
        }
    }
}

/// Setup/recovery uses the setup queue; teardown is serialized with recovery.
/// Only the C queue touches the audio callback.
protocol NativeAudioCapturing: AnyObject {
    var queue: OpaquePointer { get }
    var format: AVAudioFormat { get }
    func stop()
    func checkStatus() throws
}

extension NativeAudioCapturing { func checkStatus() throws {} }

protocol MicrophoneConfigurationHandling: NativeAudioCapturing {
    func ownsEngine(_ object: Any?) -> Bool
    func recoverAfterConfigurationChange() throws
}

enum NativeAudioFormat {
    static func floatPCM(sampleRate: Double, channels: AVAudioChannelCount, interleaved: Bool = false) -> AVAudioFormat? {
        guard sampleRate.isFinite, sampleRate > 0, channels > 0, channels <= 32 else { return nil }
        if channels <= 2 {
            return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: interleaved)
        }
        // Aggregate inputs need a discrete layout; the standard initializer rejects e.g. three channels.
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels) else { return nil }
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: interleaved, channelLayout: layout)
    }
}

enum MicrophoneCaptureFormat {
    static func tapFormat(hardware: AVAudioFormat) throws -> AVAudioFormat {
        guard hardware.sampleRate.isFinite, hardware.sampleRate > 0,
              hardware.channelCount > 0, hardware.channelCount <= 32,
              let format = NativeAudioFormat.floatPCM(sampleRate: hardware.sampleRate, channels: hardware.channelCount) else {
            throw AudioCaptureError.message("The microphone has no supported audio input format.")
        }
        return format
    }

    static func matches(_ expected: AVAudioFormat, _ current: AVAudioFormat) -> Bool {
        expected.sampleRate == current.sampleRate && expected.channelCount == current.channelCount
            && expected.commonFormat == current.commonFormat && expected.isInterleaved == current.isInterleaved
    }

    static func label(_ format: AVAudioFormat) -> String {
        String(format: "%.0f Hz / %u channels", format.sampleRate, format.channelCount)
    }

    static func validate(_ expected: AVAudioFormat, hardware: AVAudioFormat, nodeOutput: AVAudioFormat) throws {
        let hardwareMatches = hardware.sampleRate == expected.sampleRate && hardware.channelCount == expected.channelCount
        guard hardwareMatches, matches(expected, nodeOutput) else {
            throw AudioCaptureError.microphoneFormatChanged(previous: label(expected),
                current: label(hardwareMatches ? nodeOutput : hardware))
        }
    }
}

final class MicrophoneAudioCapture: MicrophoneConfigurationHandling {
    let queue: OpaquePointer
    let format: AVAudioFormat
    private let engine: AVAudioEngine
    private var stopped = false
    private let lifecycleLock = NSLock()

    init(deviceUID: String?) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let deviceUID {
            guard let device = AudioSourceCatalog.microphones().first(where: { $0.uid == deviceUID }),
                  let audioUnit = input.audioUnit else { throw AudioCaptureError.message("The selected microphone is disconnected.") }
            var id = device.deviceID
            try AudioHardware.check(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                                        kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout.size(ofValue: id))), "Select microphone")
        }
        // Selecting a device can leave the output bus cached at the old microphone's channel count.
        let format = try MicrophoneCaptureFormat.tapFormat(hardware: input.inputFormat(forBus: 0))
        guard let queue = astation_audio_queue_create(format.channelCount, 4096, 64) else {
            throw AudioCaptureError.message("The microphone has no supported audio input format.")
        }
        self.engine = engine
        self.format = format
        self.queue = queue
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
            astation_audio_queue_push(queue, buffer.audioBufferList, buffer.frameLength,
                                      time.isHostTimeValid ? time.hostTime : mach_absolute_time(), format.sampleRate)
        }
        do { try engine.start(); try validateInputFormat() }
        catch { stop(); throw error }
    }

    func stop() {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        guard !stopped else { return }
        stopped = true
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }
    func ownsEngine(_ object: Any?) -> Bool { (object as? AVAudioEngine) === engine }

    func recoverAfterConfigurationChange() throws {
        lifecycleLock.lock(); defer { lifecycleLock.unlock() }
        guard !stopped else { return }
        try validateInputFormat()
        if !engine.isRunning { try engine.start() }
        try validateInputFormat()
    }

    private func validateInputFormat() throws {
        let hardware = engine.inputNode.inputFormat(forBus: 0)
        let current = engine.inputNode.outputFormat(forBus: 0)
        try MicrophoneCaptureFormat.validate(format, hardware: hardware, nodeOutput: current)
    }
    deinit { stop(); astation_audio_queue_destroy(queue) }
}

@available(macOS 14.2, *)
final class ProcessAudioCapture: NativeAudioCapturing {
    let queue: OpaquePointer
    let format: AVAudioFormat
    private var tapID: AudioObjectID = 0
    private var deviceID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private let description: CATapDescription
    private(set) var processes: [AudioObjectID]
    private var stopped = false

    init(processes: [AudioObjectID], system: Bool) throws {
        self.processes = processes
        description = system
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: processes)
            : CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "Astation Audio Capture"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap: AudioObjectID = 0
        try AudioHardware.check(AudioHardwareCreateProcessTap(description, &tap), "Start system audio capture")
        var native = AudioStreamBasicDescription()
        do {
            try AudioHardware.read(tap, kAudioTapPropertyFormat, into: &native)
            guard native.mFormatID == kAudioFormatLinearPCM,
                  native.mFormatFlags & kAudioFormatFlagIsFloat != 0, native.mBitsPerChannel == 32,
                  let format = AVAudioFormat(standardFormatWithSampleRate: native.mSampleRate, channels: native.mChannelsPerFrame),
                  let queue = astation_audio_queue_create(native.mChannelsPerFrame, 4096, 64) else {
                throw AudioCaptureError.message("The selected output has an unsupported capture format.")
            }
            self.format = format
            self.queue = queue
        } catch { AudioHardwareDestroyProcessTap(tap); throw error }
        tapID = tap
        do {
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Astation Private Capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                                 kAudioSubTapDriftCompensationKey: true]]
            ]
            try AudioHardware.check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &deviceID), "Create capture device")
            let queue = self.queue
            let rate = format.sampleRate
            let channels = format.channelCount
            try AudioHardware.check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, deviceID, nil) { _, input, time, _, _ in
                guard input.pointee.mNumberBuffers > 0 else { return }
                let first = input.pointee.mBuffers
                let frameChannels = max(1, first.mNumberChannels)
                let frames = first.mDataByteSize / (frameChannels * UInt32(MemoryLayout<Float>.size))
                if channels > 0 {
                    astation_audio_queue_push(queue, input, frames,
                                              time.pointee.mHostTime != 0 ? time.pointee.mHostTime : mach_absolute_time(), rate)
                }
            }, "Attach audio callback")
            try AudioHardware.check(AudioDeviceStart(deviceID, ioProc), "Start audio device")
        } catch { stop(); throw error }
    }

    func updateProcesses(_ processes: [AudioObjectID]) throws {
        guard Set(processes) != Set(self.processes) else { return }
        description.processes = processes
        var property = AudioHardware.address(kAudioTapPropertyDescription)
        var value = Unmanaged.passUnretained(description).toOpaque()
        let size = UInt32(MemoryLayout.size(ofValue: value))
        let status = withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(tapID, &property, 0, nil, size, $0)
        }
        try AudioHardware.check(status, "Update application capture")
        self.processes = processes
    }

    func validateFormat() throws {
        var current = AudioStreamBasicDescription()
        try AudioHardware.read(tapID, kAudioTapPropertyFormat, into: &current)
        guard current.mSampleRate == format.sampleRate, current.mChannelsPerFrame == format.channelCount,
              current.mFormatFlags & kAudioFormatFlagIsFloat != 0, current.mBitsPerChannel == 32 else {
            throw AudioCaptureError.message("The captured output's audio format changed. Start a new recording to preserve its original format.")
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if deviceID != 0 {
            AudioDeviceStop(deviceID, ioProc)
            if let ioProc { AudioDeviceDestroyIOProcID(deviceID, ioProc) }
            AudioHardwareDestroyAggregateDevice(deviceID)
        }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        ioProc = nil
    }
    deinit { stop(); astation_audio_queue_destroy(queue) }
}
