#include "astation_core.h"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

struct CallbackRecorder {
    std::vector<std::string> transcriptions;
    std::vector<std::string> active_updates;
    std::vector<bool> dictation_updates;
};

void on_log(AStationLogLevel level, const char* message, void* user_data) {
    (void)level;
    (void)message;
    (void)user_data;
}

void on_transcription(
    const char* atem_id,
    const char* text,
    uint64_t timestamp_ms,
    void* user_data) {
    (void)timestamp_ms;
    auto* recorder = static_cast<CallbackRecorder*>(user_data);
    std::string record;
    record.reserve(64);
    record.append(atem_id ? atem_id : "");
    record.push_back(':');
    record.append(text ? text : "");
    recorder->transcriptions.push_back(record);
}

void on_active_changed(const char* atem_id, void* user_data) {
    auto* recorder = static_cast<CallbackRecorder*>(user_data);
    recorder->active_updates.emplace_back(atem_id ? atem_id : "");
}

void on_dictation_state(bool enabled, void* user_data) {
    auto* recorder = static_cast<CallbackRecorder*>(user_data);
    recorder->dictation_updates.push_back(enabled);
}

int main() {
    CallbackRecorder recorder{};

    AStationCoreConfig config{};
    config.app_id = "dummy";
    config.app_certificate = "dummy";
    config.rtm_channel = "channel";
    config.vad_sample_rate = 16000;
    config.vad_frame_duration_ms = 20;
    config.vad_silence_duration_ms = 200;
    config.inactivity_timeout_ms = 10000;

    AStationCoreCallbacks callbacks{};
    callbacks.on_log = on_log;
    callbacks.on_transcription = on_transcription;
    callbacks.on_active_atem_changed = on_active_changed;
    callbacks.on_dictation_state = on_dictation_state;
    callbacks.user_data = &recorder;

    AStationCore* core = astation_core_create(&config, &callbacks, nullptr);
    assert(core != nullptr);

    astation_core_set_dictation_enabled(core, true);
    assert(!recorder.dictation_updates.empty());
    assert(recorder.dictation_updates.back() == true);

    astation_core_on_atem_activity(core, "atem-A", 1000, true);
    astation_core_on_atem_activity(core, "atem-B", 1500, true);
    assert(!recorder.active_updates.empty());
    assert(recorder.active_updates.back() == "atem-B");

    const size_t frame_samples = (config.vad_sample_rate * config.vad_frame_duration_ms) / 1000;
    std::vector<int16_t> speech_frame(frame_samples, 20000);
    std::vector<int16_t> silence_frame(frame_samples, 0);

    // Speech burst
    astation_core_feed_audio_frame(core, speech_frame.data(), speech_frame.size(), config.vad_sample_rate);
    // Silence for hangover (200ms / 20ms = 10 frames)
    for (int i = 0; i < 12; ++i) {
        astation_core_feed_audio_frame(core, silence_frame.data(), silence_frame.size(), config.vad_sample_rate);
    }

    assert(!recorder.transcriptions.empty());
    std::cout << "Transcription events: " << recorder.transcriptions.size() << "\n";
    std::cout << "Latest transcription: " << recorder.transcriptions.back() << "\n";

    astation_core_destroy(core);
    return 0;
}

