#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AStationRtcEngine AStationRtcEngine;

struct AStationRtcConfig {
    const char* app_id;
    const char* token;
    const char* channel;
    uint32_t uid;
    int enable_audio;
    int enable_video;
};

typedef struct {
    void (*on_audio_frame)(const int16_t* data, int samples, int channels, int sample_rate, void* ctx);
    void (*on_join_success)(const char* channel, uint32_t uid, void* ctx);
    void (*on_leave)(void* ctx);
    void (*on_error)(int code, const char* msg, void* ctx);
    void (*on_user_joined)(uint32_t uid, void* ctx);
    void (*on_user_left)(uint32_t uid, void* ctx);
} AStationRtcCallbacks;

AStationRtcEngine* astation_rtc_create(struct AStationRtcConfig config, AStationRtcCallbacks cb, void* ctx);
void astation_rtc_destroy(AStationRtcEngine* engine);
int astation_rtc_join(AStationRtcEngine* engine);
int astation_rtc_leave(AStationRtcEngine* engine);
int astation_rtc_mute_mic(AStationRtcEngine* engine, int mute);
int astation_rtc_enable_screen_share(AStationRtcEngine* engine, int display_id);
int astation_rtc_stop_screen_share(AStationRtcEngine* engine);
int astation_rtc_set_token(AStationRtcEngine* engine, const char* token);

#ifdef __cplusplus
}
#endif
