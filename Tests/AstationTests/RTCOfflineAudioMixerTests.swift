import XCTest
import AgoraRtcKit

private final class OfflineMixerDelegate: NSObject, AgoraRtcEngineDelegate {}

final class RTCOfflineAudioMixerTests: XCTestCase {
    func testProcessedDirectMicCanMixWithStereoScreenAndMuteIndependently() async {
        await MainActor.run {
            // No join, native capture, credentials, or paid service is involved.
            let delegate = OfflineMixerDelegate()
            let config = AgoraRtcEngineConfig()
            config.appId = "f1e2d3c4b5a698701122334455667788"
            let engine = AgoraRtcEngineKit.sharedEngine(with: config, delegate: delegate)
            defer { AgoraRtcEngineKit.destroy() }
            XCTAssertEqual(engine.enableLocalAudio(false), 0)

            let micConfig = AgoraAudioTrackConfig()
            micConfig.enableLocalPlayback = false
            micConfig.enableAudioProcessing = true
            let mic = engine.createCustomAudioTrack(.direct, config: micConfig)
            let screenConfig = AgoraAudioTrackConfig()
            screenConfig.enableLocalPlayback = false
            let screen = engine.createCustomAudioTrack(.mixable, config: screenConfig)
            guard mic >= 0, screen >= 0 else {
                XCTFail("Agora could not create the custom audio tracks.")
                return
            }
            defer {
                _ = engine.destroyCustomAudioTrack(Int(mic))
                _ = engine.destroyCustomAudioTrack(Int(screen))
            }

            let micSource = AgoraMixedAudioStream()
            micSource.sourceType = .custom
            micSource.trackId = UInt(mic)
            let screenSource = AgoraMixedAudioStream()
            screenSource.sourceType = .custom
            screenSource.trackId = UInt(screen)
            let mixer = AgoraLocalAudioMixerConfiguration()
            mixer.syncWithLocalMic = false
            mixer.audioInputStreams = [screenSource, micSource]
            XCTAssertEqual(engine.startLocalAudioMixer(mixer), 0)
            defer { _ = engine.stopLocalAudioMixer() }

            mixer.audioInputStreams = [screenSource]
            XCTAssertEqual(engine.updateLocalAudioMixerConfiguration(mixer), 0)
            mixer.audioInputStreams = [screenSource, micSource]
            XCTAssertEqual(engine.updateLocalAudioMixerConfiguration(mixer), 0)
            XCTAssertEqual(engine.stopLocalAudioMixer(), 0)
        }
    }
}
