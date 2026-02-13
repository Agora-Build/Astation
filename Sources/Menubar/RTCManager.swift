import Foundation
#if os(macOS)
import AppKit
import CoreGraphics
#endif
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

struct ScreenShareSource {
    let id: Int64
    let isPrimary: Bool
    let rectPixels: CGRect
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
    private var _currentChannel: String?
    private var _currentUid: UInt32 = 0

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
    var currentChannel: String? { return _currentChannel }
    var currentUid: UInt32 { return _currentUid }

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
        // The SDK copies them internally, so temporaries from withCString are fine.
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
                    mgr._currentChannel = channelStr
                    mgr._currentUid = uid
                    mgr.onJoinSuccess?(channelStr, uid)
                }
            }
            callbacks.on_leave = { ctx in
                guard let ctx = ctx else { return }
                let mgr = Unmanaged<RTCManager>.fromOpaque(ctx).takeUnretainedValue()
                DispatchQueue.main.async {
                    mgr._isInChannel = false
                    mgr._isScreenSharing = false
                    mgr._currentChannel = nil
                    mgr._currentUid = 0
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
        Log.info("[RTCManager] Engine initialized with appId=\(appId)")
    }

    // MARK: - Channel

    /// Join an RTC channel with the given token, channel name, and uid.
    func joinChannel(token: String, channel: String, uid: UInt32) {
        guard let engine = engine else {
            Log.info("[RTCManager] Cannot join: engine not initialized")
            return
        }
        // Update channel, uid, and token on the engine before joining
        channel.withCString { channelPtr in
            _ = astation_rtc_set_channel(engine, channelPtr, uid)
        }
        token.withCString { tokenPtr in
            _ = astation_rtc_set_token(engine, tokenPtr)
        }
        let result = astation_rtc_join(engine)
        if result != 0 {
            Log.info("[RTCManager] Join failed with code \(result)")
        }
    }

    /// Leave the current RTC channel.
    func leaveChannel() {
        guard let engine = engine else {
            Log.info("[RTCManager] Cannot leave: engine not initialized")
            return
        }
        let result = astation_rtc_leave(engine)
        if result != 0 {
            Log.info("[RTCManager] Leave failed with code \(result)")
        }
    }

    // MARK: - Mic

    /// Mute or unmute the local microphone.
    func muteMic(_ mute: Bool) {
        guard let engine = engine else {
            Log.info("[RTCManager] Cannot mute: engine not initialized")
            return
        }
        let result = astation_rtc_mute_mic(engine, mute ? 1 : 0)
        if result == 0 {
            _isMicMuted = mute
        }
    }

    // MARK: - Screen Share
#if os(macOS)
    private func ensureScreenSharePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        Log.info("[RTCManager] Screen recording permission not granted. Requesting access...")
        let granted = CGRequestScreenCaptureAccess()
        if !granted {
            for _ in 0..<2 {
                let alert = NSAlert()
                alert.messageText = "Screen Recording Permission Required"
                alert.informativeText =
                    "Enable Screen Recording for Astation in System Settings > Privacy & Security > Screen Recording, then relaunch."
                alert.addButton(withTitle: "Grant Permission First")
                alert.runModal()
            }
        }
        return granted
    }
#endif

    func screenSources() -> [ScreenShareSource] {
        guard let engine = engine else {
            Log.info("[RTCManager] Cannot list screens: engine not initialized")
            return []
        }
        let count = Int(astation_rtc_get_screen_sources(engine, nil, 0))
        if count <= 0 {
            return []
        }
        var sources = Array(
            repeating: AstationScreenSource(
                source_id: 0,
                is_screen: 0,
                is_primary: 0,
                x: 0,
                y: 0,
                width: 0,
                height: 0
            ),
            count: count
        )
        let filled = sources.withUnsafeMutableBufferPointer { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return Int(astation_rtc_get_screen_sources(engine, base, Int32(buf.count)))
        }
        if filled <= 0 {
            return []
        }
        return sources.prefix(filled).map { source in
            ScreenShareSource(
                id: source.source_id,
                isPrimary: source.is_primary != 0,
                rectPixels: CGRect(
                    x: CGFloat(source.x),
                    y: CGFloat(source.y),
                    width: CGFloat(source.width),
                    height: CGFloat(source.height)
                )
            )
        }
    }

    /// Start screen sharing on the given display.
    func startScreenShare(displayId: Int64) {
        startScreenShare(displayId: displayId, regionPixels: nil)
    }

    /// Start screen sharing on a display with an optional capture region (pixels).
    func startScreenShare(displayId: Int64, regionPixels: CGRect?) {
        guard let engine = engine else {
            Log.info("[RTCManager] Cannot screen share: engine not initialized")
            return
        }
        #if os(macOS)
        guard ensureScreenSharePermission() else {
            Log.info("[RTCManager] Screen recording permission denied")
            return
        }
        #else
        let _ = displayId
        #endif
        let result: Int32
        if let region = regionPixels {
            let x = Int32(region.origin.x)
            let y = Int32(region.origin.y)
            let w = Int32(region.size.width)
            let h = Int32(region.size.height)
            result = astation_rtc_enable_screen_share_region(engine, Int32(displayId), x, y, w, h)
        } else {
            result = astation_rtc_enable_screen_share(engine, Int32(displayId))
        }
        if result == 0 {
            _isScreenSharing = true
        }
    }

    /// Stop screen sharing.
    func stopScreenShare() {
        guard let engine = engine else {
            Log.info("[RTCManager] Cannot stop screen share: engine not initialized")
            return
        }
        let result = astation_rtc_stop_screen_share(engine)
        if result == 0 {
            _isScreenSharing = false
        }
    }
}
