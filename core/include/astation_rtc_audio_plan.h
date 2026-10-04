#pragma once

#include <cstdint>

struct AstationRtcAudioPlan {
    bool microphone;
    bool custom;
    bool mixed;
    bool mix_microphone;
    uint32_t custom_track;
};

// One connection selects only one custom track. Explicit mixing keeps the
// processed direct microphone and unprocessed stereo screen audio independent.
inline AstationRtcAudioPlan astation_rtc_audio_plan(bool enabled, bool external_mic,
                                                  bool muted, bool screen_audio,
                                                  uint32_t mic_track, uint32_t screen_track) {
    const bool mic = enabled && !muted;
    const bool mixed = enabled && external_mic && screen_audio;
    return {mic && !external_mic, !mixed && (screen_audio || (mic && external_mic)),
            mixed, mixed && mic, screen_audio ? screen_track : mic_track};
}
