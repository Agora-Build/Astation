import XCTest
import CoreMedia
import AudioToolbox
@testable import Menubar

final class ScreenShareCaptureTests: XCTestCase {
    func testRetinaDisplayKeepsNativeResolution() throws {
        let layout = try ScreenCaptureLayout.make(
            points: CGSize(width: 1920, height: 1080),
            pixels: CGSize(width: 3840, height: 2160), region: nil
        )
        XCTAssertEqual(layout.width, 3840)
        XCTAssertEqual(layout.height, 2160)
        XCTAssertEqual(layout.sourceRect, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    func testRegionConvertsPixelsToPointsWithoutDownscaling() throws {
        let layout = try ScreenCaptureLayout.make(
            points: CGSize(width: 1920, height: 1080),
            pixels: CGSize(width: 3840, height: 2160),
            region: CGRect(x: 400, y: 200, width: 1001, height: 501)
        )
        XCTAssertEqual(layout.width, 1000)
        XCTAssertEqual(layout.height, 500)
        XCTAssertEqual(layout.sourceRect, CGRect(x: 200, y: 100, width: 500, height: 250))
    }

    func testScaledDisplayUsesIndependentPixelScalesAndClipsRegion() throws {
        let layout = try ScreenCaptureLayout.make(
            points: CGSize(width: 1600, height: 900),
            pixels: CGSize(width: 3840, height: 2160),
            region: CGRect(x: 3600, y: 1920, width: 1000, height: 1000)
        )
        XCTAssertEqual(layout.width, 240)
        XCTAssertEqual(layout.height, 240)
        XCTAssertEqual(layout.sourceRect, CGRect(x: 1500, y: 800, width: 100, height: 100))
    }

    func testInvalidRegionIsRejected() {
        XCTAssertThrowsError(try ScreenCaptureLayout.make(
            points: CGSize(width: 1920, height: 1080),
            pixels: CGSize(width: 3840, height: 2160),
            region: CGRect(x: 4000, y: 0, width: 100, height: 100)
        ))
    }

    func testStereoAudioDecodesPlanarAndInterleavedBuffers() throws {
        let planar = try makeAudioBuffer(samples: [0.5, -0.5, 1, -1], planar: true)
        let interleaved = try makeAudioBuffer(samples: [0.5, 1, -0.5, -1], planar: false)
        let expected: [Int16] = [16383, 32767, -16383, -32767]
        XCTAssertEqual(ScreenAudioPCM.decode(planar), expected)
        XCTAssertEqual(ScreenAudioPCM.decode(interleaved), expected)
        XCTAssertEqual(ScreenAudioPCM.quantize(.nan), 0)
        XCTAssertEqual(ScreenAudioPCM.quantize(.greatestFiniteMagnitude), 32767)
    }

    func testPacketizerPreservesStereoAndTenMillisecondTimingAcrossBuffers() {
        var packetizer = ScreenAudioPacketizer()
        var packets: [[Int16]] = []
        var times: [Double] = []
        let emit: (ArraySlice<Int16>, Double) -> Void = { packets.append(Array($0)); times.append($1) }
        packetizer.append([Int16](repeating: 1, count: 512), timestampMs: 1000, emit: emit)
        XCTAssertTrue(packets.isEmpty)
        packetizer.append([Int16](repeating: 2, count: 1408), timestampMs: 1000 + 256.0 / 48, emit: emit)
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0], [Int16](repeating: 1, count: 512) + [Int16](repeating: 2, count: 448))
        XCTAssertEqual(times, [1000, 1010])
    }

    func testPacketizerDropsOldPartialAudioAfterDiscontinuity() {
        var packetizer = ScreenAudioPacketizer()
        packetizer.append([Int16](repeating: 1, count: 100), timestampMs: 0) { _, _ in XCTFail() }
        packetizer.append([Int16](repeating: 2, count: 960), timestampMs: 500) { packet, time in
            XCTAssertEqual(Array(packet), [Int16](repeating: 2, count: 960))
            XCTAssertEqual(time, 500)
        }
    }

    private func makeAudioBuffer(samples: [Float], planar: Bool) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked |
                (planar ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: planar ? 4 : 8, mFramesPerPacket: 1,
            mBytesPerFrame: planar ? 4 : 8, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        ), noErr)
        var block: CMBlockBuffer?
        let byteCount = samples.count * MemoryLayout<Float>.size
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block
        ), noErr)
        let dataBlock = try XCTUnwrap(block)
        samples.withUnsafeBytes {
            XCTAssertEqual(CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: dataBlock, offsetIntoDestination: 0, dataLength: byteCount
            ), noErr)
        }
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: dataBlock,
            formatDescription: try XCTUnwrap(format), sampleCount: samples.count / 2,
            presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample
        ), noErr)
        return try XCTUnwrap(sample)
    }
}
