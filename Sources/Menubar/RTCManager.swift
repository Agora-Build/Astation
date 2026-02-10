import Foundation
import CStationCore

// MARK: - RTC Error

enum RTCError: Error, LocalizedError {
    case engineCreationFailed
    case notInitialized
    case alreadyInChannel

    var errorDescription: String? {
        switch self {
        case .engineCreationFailed:
            return "Failed to create RTC engine"
        case .notInitialized:
            return "RTC engine not initialized"
        case .alreadyInChannel:
            return "Already in a channel"
        }
    }
}

// MARK: - RTC Manager

/// Swift wrapper around the C FFI RTC engine (astation_rtc.h).
/// Manages the engine lifecycle, channel join/leave, mic mute, and screen sharing.
/// Audio frames received from the RTC engine are forwarded via `onAudioFrame`.
class RTCManager {
    private var engine: OpaquePointer?
    private var _isMicMuted: Bool = false
    private var _isScreenSharing: Bool = false
    private var _isInChannel: Bool = false

    /// Called when an audio frame is received from the RTC engine.
    /// Parameters: (samples, sampleCount, channels, sampleRate)
    var onAudioFrame: ((_ data: UnsafePointer<Int16>, _ samples: Int, _ channels: Int, _ sampleRate: Int) -> Void)?

    /// Called when the local user successfully joins a channel.
    var onJoinSuccess: ((_ channel: String, _ uid: UInt32) -> Void)?

    /// Called when the local user leaves the channel.
    var onLeave: (() -> Void)?

    /// Called when an error occurs in the RTC engine.
    var onError: ((_ code: Int, _ message: String) -> Void)?

    /// Called when a remote user joins the channel.
    var onUserJoined: ((_ uid: UInt32) -> Void)?

    /// Called when a remote user leaves the channel.
    var onUserLeft: ((_ uid: UInt32) -> Void)?

    var isMicMuted: Bool { return _isMicMuted }
    var isScreenSharing: Bool { return _isScreenSharing }
    var isInChannel: Bool { return _isInChannel }

    deinit {
        if engine != nil {
            astation_rtc_destroy(engine)
            engine = nil
        }
    }

    // MARK: - Lifecycle

    /// Initialize the RTC engine with the given App ID.
    /// Must be called before joinChannel / leaveChannel / etc.
    func initialize(appId: String) throws {
        // Tear down previous engine if any
        if engine != nil {
            astation_rtc_destroy(engine)
            engine = nil
        }

        let ctx = Unmanaged.passUnretained(self).toOpaque()

        var config = AStationRtcConfig()
        // We need to keep the C strings alive for the duration of the create call.
        // The stub copies them internally, so temporaries from withCString are fine.
        let newEngine: OpaquePointer? = appId.withCString { appIdPtr in
            config.app_id = appIdPtr
            config.token = nil
            config.channel = nil
            config.uid = 0
            config.enable_audio = 1
            config.enable_video = 0

            var callbacks = AStationRtcCallbacks()
            callbacks.on_audio_frame = { data, samples, channels, sampleRate, ctx in
                guard let ctx = ctx else { return }
                let mgr = Unmanaged<RTCManager>.fromOpaque(ctx).takeUnretainedValue()
                guard let data = data else { return }
                mgr.onAudioFrame?(data, Int(samples), Int(channels), Int(sampleRate))
            }
            callbacks.on_join_success = { channel, uid, ctx in
                guard let ctx = ctx else { return }
                let mgr = Unmanaged<RTCManager>.fromOpaque(ctx).takeUnretainedValue()
                let channelStr = channel.map { String(cString: $0) } ?? ""
                DispatchQueue.main.async {
                    mgr._isInChannel = true
                    mgr.onJoinSuccess?(channelStr, uid)
                }
            }
            callbacks.on_leave = { ctx in
                guard let ctx = ctx else { return }
                let mgr = Unmanaged<RTCManager>.fromOpaque(ctx).takeUnretainedValue()
                DispatchQueue.main.async {
                    mgr._isInChannel = false
                    mgr._isScreenSharing = false
                    mgr.onLeave?()
                }
            }
            callbacks.on_error = { code, msg, ctx in
                guard let ctx = ctx else { return }
                let mgr = Unmanaged<RTCManager>.fromOpaque(ctx).takeUnretainedValue()
                let msgStr = msg.map { String(cString: $0) } ?? "Unknown error"
                DispatchQueue.main.async {
                    mgr.onError?(Int(code), msgStr)
                }
            }
            callbacks.on_user_joined = { uid, ctx in
                guard let ctx = ctx else { return }
                let mgr = Unmanaged<RTCManager>.fromOpaque(ctx).takeUnretainedValue()
                DispatchQueue.main.async {
                    mgr.onUserJoined?(uid)
                }
            }
            callbacks.on_user_left = { uid, ctx in
                guard let ctx = ctx else { return }
                let mgr = Unmanaged<RTCManager>.fromOpaque(ctx).takeUnretainedValue()
                DispatchQueue.main.async {
                    mgr.onUserLeft?(uid)
                }
            }

            return astation_rtc_create(config, callbacks, ctx)
        }

        guard let created = newEngine else {
            throw RTCError.engineCreationFailed
        }
        engine = created
        print("[RTCManager] Engine initialized with appId=\(appId)")
    }

    // MARK: - Channel

    /// Join an RTC channel with the given token, channel name, and uid.
    func joinChannel(token: String, channel: String, uid: UInt32) {
        guard let engine = engine else {
            print("[RTCManager] Cannot join: engine not initialized")
            return
        }
        // Update token and channel config before joining
        token.withCString { tokenPtr in
            _ = astation_rtc_set_token(engine, tokenPtr)
        }
        let result = astation_rtc_join(engine)
        if result != 0 {
            print("[RTCManager] Join failed with code \(result)")
        }
    }

    /// Leave the current RTC channel.
    func leaveChannel() {
        guard let engine = engine else {
            print("[RTCManager] Cannot leave: engine not initialized")
            return
        }
        let result = astation_rtc_leave(engine)
        if result != 0 {
            print("[RTCManager] Leave failed with code \(result)")
        }
    }

    // MARK: - Mic

    /// Mute or unmute the local microphone.
    func muteMic(_ mute: Bool) {
        guard let engine = engine else {
            print("[RTCManager] Cannot mute: engine not initialized")
            return
        }
        let result = astation_rtc_mute_mic(engine, mute ? 1 : 0)
        if result == 0 {
            _isMicMuted = mute
        }
    }

    // MARK: - Screen Share

    /// Start screen sharing on the given display.
    func startScreenShare(displayId: UInt32) {
        guard let engine = engine else {
            print("[RTCManager] Cannot screen share: engine not initialized")
            return
        }
        let result = astation_rtc_enable_screen_share(engine, Int32(displayId))
        if result == 0 {
            _isScreenSharing = true
        }
    }

    /// Stop screen sharing.
    func stopScreenShare() {
        guard let engine = engine else {
            print("[RTCManager] Cannot stop screen share: engine not initialized")
            return
        }
        let result = astation_rtc_stop_screen_share(engine)
        if result == 0 {
            _isScreenSharing = false
        }
    }
}
