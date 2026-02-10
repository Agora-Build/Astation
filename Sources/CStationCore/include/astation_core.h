#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AStationCore AStationCore;

typedef enum {
    ASTATION_LOG_TRACE = 0,
    ASTATION_LOG_DEBUG,
    ASTATION_LOG_INFO,
    ASTATION_LOG_WARN,
    ASTATION_LOG_ERROR,
} AStationLogLevel;

typedef struct {
    const char* app_id;
    const char* app_certificate;
    const char* rtm_channel;
    uint32_t vad_sample_rate;
    uint32_t vad_frame_duration_ms;
    uint32_t vad_silence_duration_ms;
    uint32_t inactivity_timeout_ms;
} AStationCoreConfig;

typedef struct {
    void (*on_log)(AStationLogLevel level, const char* message, void* user_data);
    void (*on_transcription)(
        const char* atem_id,
        const char* text,
        uint64_t timestamp_ms,
        void* user_data);
    void (*on_active_atem_changed)(
        const char* atem_id,
        void* user_data);
    void (*on_dictation_state)(
        bool dictation_active,
        void* user_data);
    void* user_data;
} AStationCoreCallbacks;

typedef struct {
    void (*connect)(void* user_data);
    void (*disconnect)(void* user_data);
    void (*publish_transcription)(
        const char* target_atem_id,
        const char* text,
        uint64_t timestamp_ms,
        void* user_data);
    void (*broadcast_active_atem)(
        const char* atem_id,
        uint64_t timestamp_ms,
        void* user_data);
    void* user_data;
} AStationSignalingAdapter;

AStationCore* astation_core_create(
    const AStationCoreConfig* config,
    const AStationCoreCallbacks* callbacks,
    const AStationSignalingAdapter* signaling_adapter);

void astation_core_destroy(AStationCore* core);

void astation_core_set_dictation_enabled(AStationCore* core, bool enabled);

void astation_core_on_atem_activity(
    AStationCore* core,
    const char* atem_id,
    uint64_t timestamp_ms,
    bool focused);

void astation_core_on_atem_disconnected(
    AStationCore* core,
    const char* atem_id);

void astation_core_feed_audio_frame(
    AStationCore* core,
    const int16_t* samples,
    size_t sample_count,
    uint32_t sample_rate_hz);

void astation_core_tick(AStationCore* core, uint64_t now_ms);

#ifdef __cplusplus
}
#endif
