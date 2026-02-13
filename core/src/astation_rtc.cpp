// Agora RTC SDK integration for Astation.
// Wraps agora::rtc::IRtcEngine behind the C AStationRtcCallbacks interface.

#include "astation_rtc.h"

#include "IAgoraRtcEngine.h"
#include "IAgoraMediaEngine.h"
#include "AgoraBase.h"
#include "AgoraMediaBase.h"
#include "astation_screen_capture.h"

#include <cstdio>
#include <cstring>
#include <mutex>
#include <new>
#include <string>
#include <vector>

#ifdef __APPLE__
#include <TargetConditionals.h>
#endif

// ---------------------------------------------------------------------------
// AStationRtcEngineImpl — wraps a real agora::rtc::IRtcEngine and forwards
// SDK callbacks back through the C AStationRtcCallbacks interface.
// ---------------------------------------------------------------------------

struct AStationRtcEngineImpl
    : public agora::rtc::IRtcEngineEventHandler,
      public agora::media::IAudioFrameObserver {

    // Agora SDK handles
    agora::rtc::IRtcEngine* rtc_engine{nullptr};
    agora::media::IMediaEngine* media_engine{nullptr};

    // Config (owned copies for lifetime safety)
    std::string app_id;
    std::string token;
    std::string channel;
    uint32_t uid{0};
    int enable_audio{1};
    int enable_video{0};

    // User-provided C callbacks + context
    AStationRtcCallbacks callbacks{};
    void* callback_ctx{nullptr};

    // Guard for callback invocations from SDK threads
    std::mutex mtx;

    // Local state
    bool joined{false};
    bool mic_muted{false};
    bool screen_sharing{false};

    explicit AStationRtcEngineImpl(
        const AStationRtcConfig& config,
        AStationRtcCallbacks cb,
        void* ctx)
        : app_id(config.app_id ? config.app_id : ""),
          token(config.token ? config.token : ""),
          channel(config.channel ? config.channel : ""),
          uid(config.uid),
          enable_audio(config.enable_audio),
          enable_video(config.enable_video),
          callbacks(cb),
          callback_ctx(ctx) {}

    ~AStationRtcEngineImpl() {
        if (rtc_engine) {
            // Unregister audio observer before releasing
            if (media_engine) {
                media_engine->registerAudioFrameObserver(nullptr);
                media_engine = nullptr;
            }
            // Release engine (newer SDK uses callback instead of sync bool)
            rtc_engine->release(nullptr);
            rtc_engine = nullptr;
        }
    }

    // -----------------------------------------------------------------------
    // Engine initialization
    // -----------------------------------------------------------------------

    bool init() {
        rtc_engine = createAgoraRtcEngine();
        if (!rtc_engine) {
            std::fprintf(stderr, "[AStationRtc] createAgoraRtcEngine() returned null\n");
            return false;
        }

        agora::rtc::RtcEngineContext ctx;
        ctx.appId = app_id.c_str();
        ctx.eventHandler = this;
        ctx.channelProfile = agora::CHANNEL_PROFILE_LIVE_BROADCASTING;
        ctx.audioScenario = agora::rtc::AUDIO_SCENARIO_DEFAULT;

        int ret = rtc_engine->initialize(ctx);
        if (ret != 0) {
            std::fprintf(stderr,
                "[AStationRtc] initialize() failed: %d\n", ret);
            rtc_engine->release(nullptr);
            rtc_engine = nullptr;
            return false;
        }

        // Enable audio subsystem
        if (enable_audio) {
            rtc_engine->enableAudio();
        }

        // Enable video subsystem so screen sharing can publish video.
        rtc_engine->enableVideo();

        // Set role to broadcaster so we can publish mic/screen
        rtc_engine->setClientRole(agora::rtc::CLIENT_ROLE_BROADCASTER);

        // Obtain the media engine for audio frame observation (feeds VAD pipeline)
        void* media_ptr = nullptr;
        if (rtc_engine->queryInterface(agora::rtc::AGORA_IID_MEDIA_ENGINE,
                                        &media_ptr) == 0 &&
            media_ptr) {
            media_engine =
                static_cast<agora::media::IMediaEngine*>(media_ptr);
            media_engine->registerAudioFrameObserver(this);
        } else {
            std::fprintf(stderr,
                "[AStationRtc] Warning: could not obtain IMediaEngine\n");
        }

        std::fprintf(stderr,
            "[AStationRtc] Engine initialized (appId=%.8s... audio=%d video=%d)\n",
            app_id.c_str(), enable_audio, enable_video);
        return true;
    }

    // -----------------------------------------------------------------------
    // IRtcEngineEventHandler overrides
    // -----------------------------------------------------------------------

    void onJoinChannelSuccess(const char* ch, agora::rtc::uid_t u,
                              int elapsed) override {
        std::fprintf(stderr,
            "[AStationRtc] onJoinChannelSuccess channel=%s uid=%u elapsed=%d\n",
            ch ? ch : "", u, elapsed);
        std::lock_guard<std::mutex> lock(mtx);
        joined = true;
        if (callbacks.on_join_success) {
            callbacks.on_join_success(ch, static_cast<uint32_t>(u),
                                      callback_ctx);
        }
    }

    void onLeaveChannel(const agora::rtc::RtcStats& stats) override {
        std::fprintf(stderr,
            "[AStationRtc] onLeaveChannel duration=%u\n", stats.duration);
        std::lock_guard<std::mutex> lock(mtx);
        joined = false;
        screen_sharing = false;
        if (callbacks.on_leave) {
            callbacks.on_leave(callback_ctx);
        }
    }

    void onError(int err, const char* msg) override {
        std::fprintf(stderr,
            "[AStationRtc] onError code=%d msg=%s\n",
            err, msg ? msg : "(null)");
        std::lock_guard<std::mutex> lock(mtx);
        if (callbacks.on_error) {
            callbacks.on_error(err, msg ? msg : "Unknown error",
                               callback_ctx);
        }
    }

    void onUserJoined(agora::rtc::uid_t u, int elapsed) override {
        std::fprintf(stderr,
            "[AStationRtc] onUserJoined uid=%u elapsed=%d\n", u, elapsed);
        std::lock_guard<std::mutex> lock(mtx);
        if (callbacks.on_user_joined) {
            callbacks.on_user_joined(static_cast<uint32_t>(u), callback_ctx);
        }
    }

    void onUserOffline(agora::rtc::uid_t u,
                       agora::rtc::USER_OFFLINE_REASON_TYPE reason) override {
        std::fprintf(stderr,
            "[AStationRtc] onUserOffline uid=%u reason=%d\n", u, reason);
        std::lock_guard<std::mutex> lock(mtx);
        if (callbacks.on_user_left) {
            callbacks.on_user_left(static_cast<uint32_t>(u), callback_ctx);
        }
    }

    // -----------------------------------------------------------------------
    // IAudioFrameObserver overrides — feeds raw audio into the VAD pipeline
    // -----------------------------------------------------------------------

    bool onRecordAudioFrame(const char* /*channelId*/,
                            AudioFrame& audioFrame) override {
        // Forward recorded (mic) audio to the C callback
        if (callbacks.on_audio_frame && audioFrame.buffer) {
            const auto* data =
                static_cast<const int16_t*>(audioFrame.buffer);
            callbacks.on_audio_frame(
                data,
                audioFrame.samplesPerChannel,
                audioFrame.channels,
                audioFrame.samplesPerSec,
                callback_ctx);
        }
        return true;
    }

    bool onPlaybackAudioFrame(const char* /*channelId*/,
                              AudioFrame& /*audioFrame*/) override {
        return true;
    }

    bool onMixedAudioFrame(const char* /*channelId*/,
                           AudioFrame& /*audioFrame*/) override {
        return true;
    }

    bool onEarMonitoringAudioFrame(AudioFrame& /*audioFrame*/) override {
        return true;
    }

    bool onPlaybackAudioFrameBeforeMixing(
        const char* /*channelId*/, agora::rtc::uid_t /*uid*/,
        AudioFrame& /*audioFrame*/) override {
        return true;
    }

    int getObservedAudioFramePosition() override {
        return AUDIO_FRAME_POSITION_RECORD;
    }

    AudioParams getPlaybackAudioParams() override {
        return AudioParams();
    }

    AudioParams getRecordAudioParams() override {
        // 16 kHz mono, read-only, 320 samples per call (20 ms frames)
        return AudioParams(
            16000, 1,
            agora::rtc::RAW_AUDIO_FRAME_OP_MODE_READ_ONLY,
            320);
    }

    AudioParams getMixedAudioParams() override {
        return AudioParams();
    }

    AudioParams getEarMonitoringAudioParams() override {
        return AudioParams();
    }
};

static int start_screen_share_internal(AStationRtcEngineImpl* impl,
                                       int64_t display_id,
                                       const agora::rtc::Rectangle& region) {
    if (impl->screen_sharing) {
        std::fprintf(stderr,
            "[AStationRtc] Screen sharing already active\n");
        return 0;
    }

    if (impl->joined) {
        agora::rtc::ChannelMediaOptions options{};
        options.publishScreenTrack = false;
        impl->rtc_engine->updateChannelMediaOptions(options);
    }
    impl->rtc_engine->stopScreenCapture();

    const int64_t requested_display_id = display_id;
    int64_t resolved_display_id = requested_display_id;
    if (impl->rtc_engine && requested_display_id <= 0) {
        agora::rtc::SIZE thumb_size(0, 0);
        agora::rtc::SIZE icon_size(0, 0);
        auto* sources = impl->rtc_engine->getScreenCaptureSources(thumb_size, icon_size, true);
        if (sources) {
            std::vector<AstationScreenSource> entries;
            entries.reserve(sources->getCount());
            for (unsigned int i = 0; i < sources->getCount(); ++i) {
                const auto info = sources->getSourceInfo(i);
                AstationScreenSource entry{};
                entry.source_id = info.sourceId;
                entry.is_screen = (info.type == agora::rtc::ScreenCaptureSourceType_Screen) ? 1 : 0;
                entry.is_primary = info.primaryMonitor ? 1 : 0;
                entries.push_back(entry);
            }
            sources->release();
            resolved_display_id = astation_select_screen_source(
                entries.data(), entries.size(), requested_display_id);
        }
    }

    // Ensure video is enabled and configure encoder for AV1 @ 1080p.
    impl->rtc_engine->enableVideo();
    int scenario_ret = impl->rtc_engine->setScreenCaptureScenario(
        agora::rtc::SCREEN_SCENARIO_DOCUMENT);
    if (scenario_ret != 0) {
        const char* desc = impl->rtc_engine->getErrorDescription(scenario_ret);
        std::fprintf(stderr,
            "[AStationRtc] setScreenCaptureScenario() failed: %d (%s)\n",
            scenario_ret, desc ? desc : "unknown");
    }
    agora::rtc::VideoEncoderConfiguration encoder_config;
    encoder_config.dimensions = agora::rtc::VideoDimensions(1920, 1080);
    encoder_config.frameRate = 15;
    encoder_config.bitrate = agora::rtc::STANDARD_BITRATE;
    encoder_config.codecType = agora::rtc::VIDEO_CODEC_AV1;
    int enc_ret = impl->rtc_engine->setVideoEncoderConfiguration(encoder_config);
    if (enc_ret != 0) {
        std::fprintf(stderr,
            "[AStationRtc] setVideoEncoderConfiguration(AV1) failed: %d\n",
            enc_ret);
        encoder_config.codecType = agora::rtc::VIDEO_CODEC_H264;
        int fallback_ret = impl->rtc_engine->setVideoEncoderConfiguration(encoder_config);
        if (fallback_ret != 0) {
            std::fprintf(stderr,
                "[AStationRtc] setVideoEncoderConfiguration(H264) failed: %d\n",
                fallback_ret);
        } else {
            std::fprintf(stderr,
                "[AStationRtc] Falling back to H264 for screen share\n");
        }
    }

    agora::rtc::ScreenCaptureParameters params;
    params.dimensions = {1920, 1080};
    params.frameRate = 15;
    params.bitrate = agora::rtc::STANDARD_BITRATE;
    params.captureMouseCursor = true;

    std::fprintf(stderr,
        "[AStationRtc] Screen share config: displayId=%lld resolvedDisplayId=%lld region=%d,%d %dx%d codec=AV1 resolution=1920x1080 fps=%d\n",
        static_cast<long long>(requested_display_id),
        static_cast<long long>(resolved_display_id),
        region.x,
        region.y,
        region.width,
        region.height,
        params.frameRate);

    int ret = impl->rtc_engine->startScreenCaptureByDisplayId(
        resolved_display_id, region, params);

    if (ret == 0) {
        impl->screen_sharing = true;
        if (impl->joined) {
            agora::rtc::ChannelMediaOptions options{};
            options.publishScreenTrack = true;
            options.publishCameraTrack = false;
            options.publishMicrophoneTrack = (impl->enable_audio != 0);
            int opt_ret = impl->rtc_engine->updateChannelMediaOptions(options);
            if (opt_ret != 0) {
                const char* desc = impl->rtc_engine->getErrorDescription(opt_ret);
                std::fprintf(stderr,
                    "[AStationRtc] updateChannelMediaOptions(publishScreenTrack) failed: %d (%s)\n",
                    opt_ret, desc ? desc : "unknown");
            }
        }
        std::fprintf(stderr,
            "[AStationRtc] Screen sharing started on display %d\n",
            static_cast<int>(resolved_display_id));
    } else {
        const char* desc = impl->rtc_engine->getErrorDescription(ret);
        std::fprintf(stderr,
            "[AStationRtc] startScreenCaptureByDisplayId() failed: %d (%s)\n",
            ret, desc ? desc : "unknown");
        if (params.frameRate > 15) {
            params.frameRate = 15;
            std::fprintf(stderr,
                "[AStationRtc] Retrying screen share with fps=%d\n",
                params.frameRate);
            impl->rtc_engine->stopScreenCapture();
            ret = impl->rtc_engine->startScreenCaptureByDisplayId(
                resolved_display_id, region, params);
            if (ret == 0) {
                impl->screen_sharing = true;
                if (impl->joined) {
                    agora::rtc::ChannelMediaOptions options{};
                    options.publishScreenTrack = true;
                    options.publishCameraTrack = false;
                    options.publishMicrophoneTrack = (impl->enable_audio != 0);
                    int opt_ret = impl->rtc_engine->updateChannelMediaOptions(options);
                    if (opt_ret != 0) {
                        const char* retry_desc = impl->rtc_engine->getErrorDescription(opt_ret);
                        std::fprintf(stderr,
                            "[AStationRtc] updateChannelMediaOptions(publishScreenTrack) failed: %d (%s)\n",
                            opt_ret, retry_desc ? retry_desc : "unknown");
                    }
                }
                std::fprintf(stderr,
                    "[AStationRtc] Screen sharing started on display %d (fps=%d)\n",
                    static_cast<int>(resolved_display_id),
                    params.frameRate);
            } else {
                const char* retry_desc = impl->rtc_engine->getErrorDescription(ret);
                std::fprintf(stderr,
                    "[AStationRtc] startScreenCaptureByDisplayId() retry failed: %d (%s)\n",
                    ret, retry_desc ? retry_desc : "unknown");
            }
        }
    }
    return ret;
}

// ---------------------------------------------------------------------------
// C API implementation
// ---------------------------------------------------------------------------

extern "C" {

AStationRtcEngine* astation_rtc_create(
    struct AStationRtcConfig config,
    AStationRtcCallbacks cb,
    void* ctx) {
    auto* impl = new (std::nothrow) AStationRtcEngineImpl(config, cb, ctx);
    if (!impl) {
        std::fprintf(stderr, "[AStationRtc] Failed to allocate engine\n");
        return nullptr;
    }

    if (!impl->init()) {
        delete impl;
        return nullptr;
    }

    return reinterpret_cast<AStationRtcEngine*>(impl);
}

void astation_rtc_destroy(AStationRtcEngine* engine) {
    if (!engine) return;
    auto* impl = reinterpret_cast<AStationRtcEngineImpl*>(engine);
    std::fprintf(stderr,
        "[AStationRtc] Destroying engine (channel=%s)\n",
        impl->channel.c_str());
    delete impl;
}

int astation_rtc_join(AStationRtcEngine* engine) {
    if (!engine) return -1;
    auto* impl = reinterpret_cast<AStationRtcEngineImpl*>(engine);

    if (!impl->rtc_engine) {
        std::fprintf(stderr, "[AStationRtc] Cannot join: engine not initialized\n");
        return -1;
    }

    if (impl->joined) {
        std::fprintf(stderr,
            "[AStationRtc] Already joined channel=%s\n",
            impl->channel.c_str());
        return 0;
    }

    std::fprintf(stderr,
        "[AStationRtc] Joining channel=%s uid=%u token=%s\n",
        impl->channel.c_str(),
        impl->uid,
        impl->token.empty() ? "(none)" : "(set)");

    int ret = impl->rtc_engine->joinChannel(
        impl->token.empty() ? nullptr : impl->token.c_str(),
        impl->channel.c_str(),
        impl->uid,
        [&]() {
            agora::rtc::ChannelMediaOptions options{};
            options.publishMicrophoneTrack = (impl->enable_audio != 0);
            options.publishCameraTrack = false;
            options.publishScreenTrack = impl->screen_sharing;
            options.autoSubscribeAudio = true;
            options.autoSubscribeVideo = true;
            return options;
        }());

    if (ret != 0) {
        const char* desc = impl->rtc_engine->getErrorDescription(ret);
        std::fprintf(stderr,
            "[AStationRtc] joinChannel() failed: %d (%s)\n",
            ret, desc ? desc : "unknown");
    }
    return ret;
}

int astation_rtc_leave(AStationRtcEngine* engine) {
    if (!engine) return -1;
    auto* impl = reinterpret_cast<AStationRtcEngineImpl*>(engine);

    if (!impl->rtc_engine) {
        std::fprintf(stderr, "[AStationRtc] Cannot leave: engine not initialized\n");
        return -1;
    }

    if (!impl->joined) {
        std::fprintf(stderr, "[AStationRtc] Not in a channel, nothing to leave\n");
        return 0;
    }

    std::fprintf(stderr,
        "[AStationRtc] Leaving channel=%s\n", impl->channel.c_str());

    int ret = impl->rtc_engine->leaveChannel();
    if (ret != 0) {
        std::fprintf(stderr,
            "[AStationRtc] leaveChannel() failed: %d\n", ret);
    }
    return ret;
}

int astation_rtc_mute_mic(AStationRtcEngine* engine, int mute) {
    if (!engine) return -1;
    auto* impl = reinterpret_cast<AStationRtcEngineImpl*>(engine);

    if (!impl->rtc_engine) {
        std::fprintf(stderr, "[AStationRtc] Cannot mute: engine not initialized\n");
        return -1;
    }

    int ret = impl->rtc_engine->muteLocalAudioStream(mute != 0);
    if (ret == 0) {
        impl->mic_muted = (mute != 0);
        std::fprintf(stderr,
            "[AStationRtc] Mic %s\n",
            impl->mic_muted ? "muted" : "unmuted");
    } else {
        std::fprintf(stderr,
            "[AStationRtc] muteLocalAudioStream() failed: %d\n", ret);
    }
    return ret;
}

int astation_rtc_enable_screen_share(AStationRtcEngine* engine,
                                      int display_id) {
    if (!engine) return -1;
    auto* impl = reinterpret_cast<AStationRtcEngineImpl*>(engine);

    if (!impl->rtc_engine) {
        std::fprintf(stderr,
            "[AStationRtc] Cannot screen share: engine not initialized\n");
        return -1;
    }

#if (defined(__APPLE__) && TARGET_OS_MAC && !TARGET_OS_IPHONE) || defined(_WIN32)
    const agora::rtc::Rectangle region = {0, 0, 0, 0}; // full display
    return start_screen_share_internal(impl, static_cast<int64_t>(display_id), region);
#else
    (void)display_id;
    std::fprintf(stderr,
        "[AStationRtc] Screen sharing not available on this platform\n");
    return -1;
#endif
}

int astation_rtc_enable_screen_share_region(AStationRtcEngine* engine,
                                            int display_id,
                                            int x,
                                            int y,
                                            int width,
                                            int height) {
    if (!engine) return -1;
    auto* impl = reinterpret_cast<AStationRtcEngineImpl*>(engine);

    if (!impl->rtc_engine) {
        std::fprintf(stderr,
            "[AStationRtc] Cannot screen share: engine not initialized\n");
        return -1;
    }

#if (defined(__APPLE__) && TARGET_OS_MAC && !TARGET_OS_IPHONE) || defined(_WIN32)
    if (width <= 0 || height <= 0) {
        std::fprintf(stderr,
            "[AStationRtc] Invalid screen share region: %dx%d\n",
            width,
            height);
        return -1;
    }
    const agora::rtc::Rectangle region = {x, y, width, height};
    return start_screen_share_internal(impl, static_cast<int64_t>(display_id), region);
#else
    (void)display_id;
    (void)x;
    (void)y;
    (void)width;
    (void)height;
    std::fprintf(stderr,
        "[AStationRtc] Screen sharing not available on this platform\n");
    return -1;
#endif
}

int astation_rtc_stop_screen_share(AStationRtcEngine* engine) {
    if (!engine) return -1;
    auto* impl = reinterpret_cast<AStationRtcEngineImpl*>(engine);

    if (!impl->rtc_engine) {
        std::fprintf(stderr,
            "[AStationRtc] Cannot stop screen share: engine not initialized\n");
        return -1;
    }

#if (defined(__APPLE__) && TARGET_OS_MAC && !TARGET_OS_IPHONE) || defined(_WIN32)
    int ret = impl->rtc_engine->stopScreenCapture();
    if (ret == 0) {
        impl->screen_sharing = false;
        if (impl->joined) {
            agora::rtc::ChannelMediaOptions options{};
            options.publishScreenTrack = false;
            int opt_ret = impl->rtc_engine->updateChannelMediaOptions(options);
            if (opt_ret != 0) {
                const char* desc = impl->rtc_engine->getErrorDescription(opt_ret);
                std::fprintf(stderr,
                    "[AStationRtc] updateChannelMediaOptions(stopScreenTrack) failed: %d (%s)\n",
                    opt_ret, desc ? desc : "unknown");
            }
        }
        std::fprintf(stderr, "[AStationRtc] Screen sharing stopped\n");
    } else {
        const char* desc = impl->rtc_engine->getErrorDescription(ret);
        std::fprintf(stderr,
            "[AStationRtc] stopScreenCapture() failed: %d (%s)\n",
            ret, desc ? desc : "unknown");
    }
    return ret;
#else
    std::fprintf(stderr,
        "[AStationRtc] Screen sharing not available on this platform\n");
    return -1;
#endif
}

int astation_rtc_get_screen_sources(AStationRtcEngine* engine,
                                    AstationScreenSource* out_sources,
                                    int max_count) {
    if (!engine) return -1;
    auto* impl = reinterpret_cast<AStationRtcEngineImpl*>(engine);

    if (!impl->rtc_engine) {
        std::fprintf(stderr,
            "[AStationRtc] Cannot list screens: engine not initialized\n");
        return -1;
    }

#if (defined(__APPLE__) && TARGET_OS_MAC && !TARGET_OS_IPHONE) || defined(_WIN32)
    agora::rtc::SIZE thumb_size(0, 0);
    agora::rtc::SIZE icon_size(0, 0);
    auto* sources = impl->rtc_engine->getScreenCaptureSources(thumb_size, icon_size, true);
    if (!sources) {
        return 0;
    }
    int total = 0;
    const unsigned int count = sources->getCount();
    for (unsigned int i = 0; i < count; ++i) {
        const auto info = sources->getSourceInfo(i);
        if (info.type != agora::rtc::ScreenCaptureSourceType_Screen) {
            continue;
        }
        if (out_sources && total < max_count) {
            out_sources[total].source_id = info.sourceId;
            out_sources[total].is_screen = 1;
            out_sources[total].is_primary = info.primaryMonitor ? 1 : 0;
            out_sources[total].x = info.position.x;
            out_sources[total].y = info.position.y;
            out_sources[total].width = info.position.width;
            out_sources[total].height = info.position.height;
        }
        total++;
    }
    sources->release();
    return total;
#else
    (void)out_sources;
    (void)max_count;
    return -1;
#endif
}

int astation_rtc_set_token(AStationRtcEngine* engine, const char* token) {
    if (!engine) return -1;
    auto* impl = reinterpret_cast<AStationRtcEngineImpl*>(engine);
    impl->token = (token ? token : "");

    // If already in a channel, renew the token on the engine
    if (impl->rtc_engine && impl->joined && !impl->token.empty()) {
        int ret = impl->rtc_engine->renewToken(impl->token.c_str());
        if (ret != 0) {
            std::fprintf(stderr,
                "[AStationRtc] renewToken() failed: %d\n", ret);
        }
        return ret;
    }

    std::fprintf(stderr, "[AStationRtc] Token updated\n");
    return 0;
}

int astation_rtc_set_channel(AStationRtcEngine* engine, const char* channel,
                              uint32_t uid) {
    if (!engine) return -1;
    auto* impl = reinterpret_cast<AStationRtcEngineImpl*>(engine);
    impl->channel = (channel ? channel : "");
    impl->uid = uid;
    std::fprintf(stderr,
        "[AStationRtc] Channel set to %s uid=%u\n",
        impl->channel.c_str(), impl->uid);
    return 0;
}

} // extern "C"
