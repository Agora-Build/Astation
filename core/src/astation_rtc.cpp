#include "astation_rtc.h"

#include <cstdio>
#include <cstring>
#include <new>
#include <string>

namespace {

struct AStationRtcEngineImpl {
    std::string app_id;
    std::string token;
    std::string channel;
    uint32_t uid{0};
    int enable_audio{1};
    int enable_video{0};

    AStationRtcCallbacks callbacks{};
    void* callback_ctx{nullptr};

    bool joined{false};
    bool mic_muted{false};
    bool screen_sharing{false};
    int screen_display_id{0};

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
};

} // namespace

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
    std::fprintf(stderr,
        "[AStationRtc] Engine created (app_id=%s, channel=%s, uid=%u, audio=%d, video=%d)\n",
        impl->app_id.c_str(),
        impl->channel.c_str(),
        impl->uid,
        impl->enable_audio,
        impl->enable_video);
    return reinterpret_cast<AStationRtcEngine*>(impl);
}

void astation_rtc_destroy(AStationRtcEngine* engine) {
    if (!engine) {
        return;
    }
    auto* impl = reinterpret_cast<AStationRtcEngineImpl*>(engine);
    std::fprintf(stderr, "[AStationRtc] Engine destroyed (channel=%s)\n", impl->channel.c_str());
    delete impl;
}

int astation_rtc_join(AStationRtcEngine* engine) {
    if (!engine) {
        return -1;
    }
    auto* impl = reinterpret_cast<AStationRtcEngineImpl*>(engine);
    if (impl->joined) {
        std::fprintf(stderr, "[AStationRtc] Already joined channel=%s\n", impl->channel.c_str());
        return 0;
    }
    impl->joined = true;
    std::fprintf(stderr,
        "[AStationRtc] Joined channel=%s uid=%u (stub)\n",
        impl->channel.c_str(),
        impl->uid);

    if (impl->callbacks.on_join_success) {
        impl->callbacks.on_join_success(
            impl->channel.c_str(),
            impl->uid,
            impl->callback_ctx);
    }
    return 0;
}

int astation_rtc_leave(AStationRtcEngine* engine) {
    if (!engine) {
        return -1;
    }
    auto* impl = reinterpret_cast<AStationRtcEngineImpl*>(engine);
    if (!impl->joined) {
        std::fprintf(stderr, "[AStationRtc] Not in a channel, nothing to leave\n");
        return 0;
    }
    impl->joined = false;
    impl->screen_sharing = false;
    std::fprintf(stderr,
        "[AStationRtc] Left channel=%s (stub)\n",
        impl->channel.c_str());

    if (impl->callbacks.on_leave) {
        impl->callbacks.on_leave(impl->callback_ctx);
    }
    return 0;
}

int astation_rtc_mute_mic(AStationRtcEngine* engine, int mute) {
    if (!engine) {
        return -1;
    }
    auto* impl = reinterpret_cast<AStationRtcEngineImpl*>(engine);
    impl->mic_muted = (mute != 0);
    std::fprintf(stderr,
        "[AStationRtc] Mic %s (stub)\n",
        impl->mic_muted ? "muted" : "unmuted");
    return 0;
}

int astation_rtc_enable_screen_share(AStationRtcEngine* engine, int display_id) {
    if (!engine) {
        return -1;
    }
    auto* impl = reinterpret_cast<AStationRtcEngineImpl*>(engine);
    impl->screen_sharing = true;
    impl->screen_display_id = display_id;
    std::fprintf(stderr,
        "[AStationRtc] Screen sharing enabled on display %d (stub)\n",
        display_id);
    return 0;
}

int astation_rtc_stop_screen_share(AStationRtcEngine* engine) {
    if (!engine) {
        return -1;
    }
    auto* impl = reinterpret_cast<AStationRtcEngineImpl*>(engine);
    impl->screen_sharing = false;
    std::fprintf(stderr, "[AStationRtc] Screen sharing stopped (stub)\n");
    return 0;
}

int astation_rtc_set_token(AStationRtcEngine* engine, const char* token) {
    if (!engine) {
        return -1;
    }
    auto* impl = reinterpret_cast<AStationRtcEngineImpl*>(engine);
    impl->token = (token ? token : "");
    std::fprintf(stderr, "[AStationRtc] Token updated (stub)\n");
    return 0;
}

} // extern "C"
