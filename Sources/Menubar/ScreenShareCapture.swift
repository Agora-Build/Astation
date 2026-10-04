import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import CStationCore

struct ScreenShareOptions: Equatable {
    var captureAudio = false
    var frameRate = 60

    static func load(from defaults: UserDefaults = .standard) -> ScreenShareOptions {
        let fps = defaults.integer(forKey: "screenShare.frameRate")
        return ScreenShareOptions(
            captureAudio: defaults.bool(forKey: "screenShare.captureAudio"),
            frameRate: fps == 30 ? 30 : 60
        )
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(captureAudio, forKey: "screenShare.captureAudio")
        defaults.set(frameRate, forKey: "screenShare.frameRate")
    }
}

struct ScreenCaptureLayout: Equatable {
    let sourceRect: CGRect
    let width: Int
    let height: Int

    // The region selector uses native pixels; ScreenCaptureKit's sourceRect uses points.
    static func make(points: CGSize, pixels: CGSize, region: CGRect?) throws -> ScreenCaptureLayout {
        guard points.width > 0, points.height > 0, pixels.width >= 2, pixels.height >= 2 else {
            throw ScreenShareCaptureError.invalidRegion
        }
        let bounds = CGRect(origin: .zero, size: pixels)
        let clipped = (region ?? bounds).intersection(bounds)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2 else {
            throw ScreenShareCaptureError.invalidRegion
        }
        // H.264/NV12 requires even dimensions. Trim at most one pixel; never downscale.
        let width = Int(clipped.width) & ~1
        let height = Int(clipped.height) & ~1
        return ScreenCaptureLayout(
            sourceRect: CGRect(
                x: clipped.minX * points.width / pixels.width,
                y: clipped.minY * points.height / pixels.height,
                width: CGFloat(width) * points.width / pixels.width,
                height: CGFloat(height) * points.height / pixels.height
            ),
            width: width,
            height: height
        )
    }
}

enum ScreenShareCaptureError: LocalizedError {
    case displayUnavailable
    case invalidRegion
    case publicationFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .displayUnavailable: return "The selected display is no longer available."
        case .invalidRegion: return "The selected capture region is outside the display."
        case .publicationFailed(let code): return "Agora could not publish the screen (code \(code))."
        }
    }
}

final class ScreenShareCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Statistics {
        var videoFrames = 0
        var audioPackets = 0
        var width = 0
        var height = 0
    }

    private let engine: OpaquePointer
    private let queue = DispatchQueue(label: "build.agora.astation.screen-share", qos: .userInteractive)
    private var stream: SCStream?
    private var invalidated = false
    private var acceptsFrames = false
    private var timestampOffsetMs: Double = 0
    private var audioPacketizer = ScreenAudioPacketizer()
    private var reportedPushError = false
    private var statistics = Statistics()
    var onStop: ((Error) -> Void)?

    func snapshotStatistics() -> Statistics { queue.sync { statistics } }

    init(engine: OpaquePointer) {
        self.engine = engine
    }

    @MainActor
    func start(displayID: CGDirectDisplayID, region: CGRect?, options: ScreenShareOptions,
               configurePublication: (ScreenCaptureLayout) throws -> Void) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !invalidated else { throw CancellationError() }
        guard let display = content.displays.first(where: { $0.displayID == displayID }),
              let mode = CGDisplayCopyDisplayMode(displayID) else {
            throw ScreenShareCaptureError.displayUnavailable
        }
        let layout = try ScreenCaptureLayout.make(
            points: CGSize(width: display.width, height: display.height),
            pixels: CGSize(width: mode.pixelWidth, height: mode.pixelHeight),
            region: region
        )
        let excluded = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = SCStreamConfiguration()
        config.width = layout.width
        config.height = layout.height
        config.sourceRect = layout.sourceRect
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.capturesAudio = options.captureAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2

        try configurePublication(layout)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if options.captureAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        queue.sync {
            timestampOffsetMs = Double(astation_rtc_monotonic_time_ms(engine)) -
                CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) * 1000
            acceptsFrames = true
        }
        try await stream.startCapture()
        guard !invalidated else {
            try? await stream.stopCapture()
            throw CancellationError()
        }
        Log.info("[ScreenShare] Screen sharing started: \(layout.width)x\(layout.height), target \(options.frameRate) fps, system audio \(options.captureAudio ? "on" : "off")")
    }

    // Drain pending callbacks before the owning RTC engine is left or destroyed.
    func stop() {
        invalidated = true
        queue.sync { acceptsFrames = false }
        if let stream {
            self.stream = nil
            Task { try? await stream.stopCapture() }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.invalidated else { return }
            self.onStop?(error)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard acceptsFrames, sampleBuffer.isValid else { return }
        let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000 + timestampOffsetMs
        guard timestamp.isFinite else { return }
        var result: Int32 = 0
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let status = attachments.first?[.status] as? Int,
                  status == SCFrameStatus.complete.rawValue,
                  let pixelBuffer = sampleBuffer.imageBuffer else { return }
            result = astation_rtc_push_screen_video(
                engine, Unmanaged.passUnretained(pixelBuffer).toOpaque(),
                Int32(CVPixelBufferGetWidth(pixelBuffer)), Int32(CVPixelBufferGetHeight(pixelBuffer)),
                Int64(timestamp)
            )
            if result == 0 {
                statistics.videoFrames += 1
                statistics.width = CVPixelBufferGetWidth(pixelBuffer)
                statistics.height = CVPixelBufferGetHeight(pixelBuffer)
            }
        case .audio:
            guard let pcm = ScreenAudioPCM.decode(sampleBuffer) else { return }
            audioPacketizer.append(pcm, timestampMs: timestamp) { packet, time in
                result = packet.withUnsafeBufferPointer {
                    astation_rtc_push_screen_audio(engine, $0.baseAddress, 480, Int64(time))
                }
                if result == 0 { statistics.audioPackets += 1 }
            }
        default: return
        }
        if result != 0, !reportedPushError {
            reportedPushError = true
            Log.error("[ScreenShare] Agora rejected a captured frame: \(result)")
        }
    }
}

enum ScreenAudioPCM {
    static func quantize(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        return Int16(max(-1, min(1, value)) * 32767)
    }

    static func decode(_ sampleBuffer: CMSampleBuffer) -> [Int16]? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mSampleRate == 48000, asbd.mChannelsPerFrame == 2,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else { return nil }
        var requiredSize = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &requiredSize, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: nil
        ) == noErr, requiredSize > 0 else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: list, bufferListSize: requiredSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
            blockBufferOut: &block
        ) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let count = CMSampleBufferGetNumSamples(sampleBuffer)
        let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard buffers.count == (planar ? 2 : 1), buffers.allSatisfy({
            $0.mData != nil && Int($0.mDataByteSize) >= count * (planar ? 1 : 2) * MemoryLayout<Float>.size
        }) else { return nil }
        return withExtendedLifetime(block) {
            let left = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            let right = planar ? buffers[1].mData!.assumingMemoryBound(to: Float.self) : left
            var pcm = [Int16](repeating: 0, count: count * 2)
            for index in 0..<count {
                pcm[index * 2] = quantize(left[planar ? index : index * 2])
                pcm[index * 2 + 1] = quantize(right[planar ? index : index * 2 + 1])
            }
            return pcm
        }
    }
}

struct ScreenAudioPacketizer {
    private var pending: [Int16] = []
    private var nextTimestampMs: Double = 0

    mutating func append(_ pcm: [Int16], timestampMs: Double,
                         emit: (ArraySlice<Int16>, Double) -> Void) {
        let expected = nextTimestampMs + Double(pending.count / 2) / 48
        if pending.isEmpty || abs(timestampMs - expected) > 30 {
            pending.removeAll(keepingCapacity: true)
            nextTimestampMs = timestampMs
        }
        pending.append(contentsOf: pcm)
        var offset = 0
        while pending.count - offset >= 960 {
            emit(pending[offset..<(offset + 960)], nextTimestampMs)
            nextTimestampMs += 10
            offset += 960
        }
        if offset > 0 { pending.removeFirst(offset) }
    }
}
