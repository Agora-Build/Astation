#include "astation_core.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <map>
#include <mutex>
#include <sstream>
#include <string>
#include <utility>
#include <vector>
#include <new>

namespace {

constexpr uint32_t kDefaultVadSampleRate = 16000;
constexpr uint32_t kDefaultVadFrameMs = 20;
constexpr uint32_t kDefaultVadSilenceMs = 500;
constexpr uint32_t kDefaultInactivityMs = 10000;
constexpr float kDefaultVadSpeechThreshold = 0.0008f; // RMS threshold (normalized)
constexpr float kDefaultVadSilenceThreshold = 0.0005f;

struct AtemClientState {
    uint64_t last_activity_ms{0};
    bool focused{false};
};

class WebRtcVadAdapter {
public:
    WebRtcVadAdapter(
        uint32_t sample_rate_hz,
        uint32_t frame_duration_ms,
        uint32_t silence_duration_ms)
        : sample_rate_hz_(sample_rate_hz == 0 ? kDefaultVadSampleRate : sample_rate_hz),
          frame_duration_ms_(frame_duration_ms == 0 ? kDefaultVadFrameMs : frame_duration_ms),
          silence_duration_ms_(silence_duration_ms == 0 ? kDefaultVadSilenceMs : silence_duration_ms),
          frame_samples_(static_cast<size_t>(sample_rate_hz_ * frame_duration_ms_ / 1000)),
          silence_frames_required_(
              std::max<uint32_t>(1U, silence_duration_ms_ / (frame_duration_ms_ == 0 ? kDefaultVadFrameMs : frame_duration_ms_))) {}

    void reset() {
        in_speech_ = false;
        silence_frame_count_ = 0;
        accumulated_samples_ = 0;
    }

    // Basic RMS-based fallback; replace with actual WebRTC VAD when linked.
    // Returns pair {speech_started, speech_ended}
    std::pair<bool, bool> process_frame(const int16_t* samples, size_t sample_count) {
        if (samples == nullptr || sample_count == 0) {
            return {false, false};
        }

        float rms = 0.0f;
        for (size_t i = 0; i < sample_count; ++i) {
            float normalized = static_cast<float>(samples[i]) / 32768.0f;
            rms += normalized * normalized;
        }
        rms /= static_cast<float>(sample_count);
        rms = std::sqrt(rms);

        bool detected = false;
        if (!in_speech_) {
            detected = rms >= kDefaultVadSpeechThreshold;
            if (detected) {
                in_speech_ = true;
                silence_frame_count_ = 0;
                accumulated_samples_ = sample_count;
                return {true, false};
            }
        } else {
            accumulated_samples_ += sample_count;
            if (rms <= kDefaultVadSilenceThreshold) {
                ++silence_frame_count_;
                if (silence_frame_count_ >= silence_frames_required_) {
                    in_speech_ = false;
                    silence_frame_count_ = 0;
                    accumulated_samples_ = 0;
                    return {false, true};
                }
            } else {
                silence_frame_count_ = 0;
            }
        }

        return {false, false};
    }

    size_t frame_samples() const { return frame_samples_; }
    uint32_t frame_duration_ms() const { return frame_duration_ms_; }

private:
    uint32_t sample_rate_hz_;
    uint32_t frame_duration_ms_;
    uint32_t silence_duration_ms_;
    size_t frame_samples_;
    uint32_t silence_frames_required_;
    bool in_speech_{false};
    uint32_t silence_frame_count_{0};
    size_t accumulated_samples_{0};
};

struct AStationCoreImpl {
    AStationCoreConfig config{};
    AStationCoreCallbacks callbacks{};
    AStationSignalingAdapter signaling{};
    std::mutex mutex;
    std::map<std::string, AtemClientState> clients;
    std::string active_atem_id;
    bool dictation_enabled{false};
    bool signaling_connected{false};
    WebRtcVadAdapter vad;
    std::vector<int16_t> audio_buffer;
    uint64_t audio_time_ms{0};
    uint64_t last_tick_ms{0};
    uint32_t segment_counter{0};

    explicit AStationCoreImpl(const AStationCoreConfig& cfg, const AStationCoreCallbacks* cb)
        : config(cfg),
          callbacks(cb ? *cb : AStationCoreCallbacks{}),
          vad(cfg.vad_sample_rate, cfg.vad_frame_duration_ms, cfg.vad_silence_duration_ms) {
        if (config.vad_sample_rate == 0) {
            config.vad_sample_rate = kDefaultVadSampleRate;
        }
        if (config.vad_frame_duration_ms == 0) {
            config.vad_frame_duration_ms = kDefaultVadFrameMs;
        }
        if (config.vad_silence_duration_ms == 0) {
            config.vad_silence_duration_ms = kDefaultVadSilenceMs;
        }
        if (config.inactivity_timeout_ms == 0) {
            config.inactivity_timeout_ms = kDefaultInactivityMs;
        }
    }

    void set_signaling(const AStationSignalingAdapter* adapter) {
        if (adapter) {
            signaling = *adapter;
        } else {
            signaling = {};
        }
    }

    void log(AStationLogLevel level, const std::string& message) {
        if (callbacks.on_log) {
            callbacks.on_log(level, message.c_str(), callbacks.user_data);
        }
    }

    void notify_active_change_locked(const std::string& atem_id) {
        if (!callbacks.on_active_atem_changed) {
            return;
        }
        callbacks.on_active_atem_changed(atem_id.empty() ? nullptr : atem_id.c_str(), callbacks.user_data);
    }

    void broadcast_active_change_locked(const std::string& atem_id, uint64_t timestamp_ms) {
        if (signaling.broadcast_active_atem) {
            signaling.broadcast_active_atem(atem_id.empty() ? nullptr : atem_id.c_str(), timestamp_ms, signaling.user_data);
        }
    }

    void ensure_signaling_connected_locked() {
        if (!dictation_enabled) {
            return;
        }
        if (!signaling_connected && signaling.connect) {
            signaling.connect(signaling.user_data);
            signaling_connected = true;
        }
    }

    void ensure_signaling_disconnected_locked() {
        if (signaling_connected && signaling.disconnect) {
            signaling.disconnect(signaling.user_data);
        }
        signaling_connected = false;
    }
};

} // namespace

extern "C" {

AStationCore* astation_core_create(
    const AStationCoreConfig* config,
    const AStationCoreCallbacks* callbacks,
    const AStationSignalingAdapter* signaling_adapter) {
    if (!config) {
        return nullptr;
    }
    auto* impl = new (std::nothrow) AStationCoreImpl(*config, callbacks);
    if (!impl) {
        return nullptr;
    }
    impl->set_signaling(signaling_adapter);
    return reinterpret_cast<AStationCore*>(impl);
}

void astation_core_destroy(AStationCore* core) {
    if (!core) {
        return;
    }
    auto* impl = reinterpret_cast<AStationCoreImpl*>(core);
    delete impl;
}

void astation_core_set_dictation_enabled(AStationCore* core, bool enabled) {
    if (!core) {
        return;
    }
    auto* impl = reinterpret_cast<AStationCoreImpl*>(core);
    std::lock_guard<std::mutex> lock(impl->mutex);
    if (impl->dictation_enabled == enabled) {
        return;
    }
    impl->dictation_enabled = enabled;
    if (impl->callbacks.on_dictation_state) {
        impl->callbacks.on_dictation_state(enabled, impl->callbacks.user_data);
    }
    if (enabled) {
        impl->ensure_signaling_connected_locked();
        impl->vad.reset();
    } else {
        impl->ensure_signaling_disconnected_locked();
    }
}

void astation_core_on_atem_activity(
    AStationCore* core,
    const char* atem_id_cstr,
    uint64_t timestamp_ms,
    bool focused) {
    if (!core || !atem_id_cstr) {
        return;
    }
    auto* impl = reinterpret_cast<AStationCoreImpl*>(core);
    std::string atem_id(atem_id_cstr);
    std::lock_guard<std::mutex> lock(impl->mutex);
    auto& state = impl->clients[atem_id];
    state.last_activity_ms = timestamp_ms;
    state.focused = focused;

    bool should_switch = false;
    if (impl->active_atem_id.empty()) {
        should_switch = true;
    } else if (impl->active_atem_id != atem_id) {
        const auto& active_state = impl->clients[impl->active_atem_id];
        if (timestamp_ms > active_state.last_activity_ms) {
            should_switch = true;
        } else if (!active_state.focused && focused) {
            should_switch = true;
        }
    }

    if (should_switch) {
        impl->active_atem_id = atem_id;
        impl->notify_active_change_locked(impl->active_atem_id);
        impl->broadcast_active_change_locked(impl->active_atem_id, timestamp_ms);
    }
}

void astation_core_on_atem_disconnected(
    AStationCore* core,
    const char* atem_id_cstr) {
    if (!core || !atem_id_cstr) {
        return;
    }
    auto* impl = reinterpret_cast<AStationCoreImpl*>(core);
    std::string atem_id(atem_id_cstr);
    std::lock_guard<std::mutex> lock(impl->mutex);
    impl->clients.erase(atem_id);
    if (impl->active_atem_id == atem_id) {
        impl->active_atem_id.clear();
        impl->notify_active_change_locked("");
        impl->broadcast_active_change_locked("", impl->audio_time_ms);
    }
}

void astation_core_feed_audio_frame(
    AStationCore* core,
    const int16_t* samples,
    size_t sample_count,
    uint32_t sample_rate_hz) {
    (void)sample_rate_hz;
    if (!core || !samples || sample_count == 0) {
        return;
    }
    auto* impl = reinterpret_cast<AStationCoreImpl*>(core);
    std::string active_atem;
    bool dictation_enabled = false;
    {
        std::lock_guard<std::mutex> lock(impl->mutex);
        if (!impl->dictation_enabled || impl->active_atem_id.empty()) {
            return;
        }
        dictation_enabled = impl->dictation_enabled;
        active_atem = impl->active_atem_id;
        impl->ensure_signaling_connected_locked();
    }
    if (!dictation_enabled || active_atem.empty()) {
        return;
    }

    size_t frame_samples = impl->vad.frame_samples();
    size_t processed = 0;

    while (processed < sample_count) {
        size_t remaining = sample_count - processed;
        size_t take = std::min(frame_samples - impl->audio_buffer.size(), remaining);
        impl->audio_buffer.insert(
            impl->audio_buffer.end(),
            samples + processed,
            samples + processed + take);
        processed += take;

        if (impl->audio_buffer.size() == frame_samples) {
            auto [speech_started, speech_ended] =
                impl->vad.process_frame(impl->audio_buffer.data(), impl->audio_buffer.size());

            impl->audio_time_ms += impl->config.vad_frame_duration_ms;

            if (speech_started) {
            if (impl->callbacks.on_log) {
                impl->callbacks.on_log(
                    ASTATION_LOG_DEBUG,
                    "VAD detected speech start",
                    impl->callbacks.user_data);
            }
        }
            if (speech_ended) {
                ++impl->segment_counter;
                std::ostringstream oss;
                oss << "speech_segment_" << impl->segment_counter;
                uint64_t timestamp = impl->audio_time_ms;

                if (impl->signaling.publish_transcription) {
                    impl->signaling.publish_transcription(
                        active_atem.c_str(),
                        oss.str().c_str(),
                        timestamp,
                        impl->signaling.user_data);
                }
                if (impl->callbacks.on_transcription) {
                    impl->callbacks.on_transcription(
                        active_atem.c_str(),
                        oss.str().c_str(),
                        timestamp,
                        impl->callbacks.user_data);
                }
            }

            impl->audio_buffer.clear();
        }
    }
}

void astation_core_tick(AStationCore* core, uint64_t now_ms) {
    if (!core) {
        return;
    }
    auto* impl = reinterpret_cast<AStationCoreImpl*>(core);
    std::lock_guard<std::mutex> lock(impl->mutex);
    impl->last_tick_ms = now_ms;
    std::vector<std::string> expired;
    for (const auto& [atem_id, state] : impl->clients) {
        if (now_ms > state.last_activity_ms &&
            now_ms - state.last_activity_ms > impl->config.inactivity_timeout_ms) {
            expired.push_back(atem_id);
        }
    }

    for (const auto& id : expired) {
        impl->clients.erase(id);
        if (impl->active_atem_id == id) {
            impl->active_atem_id.clear();
            impl->notify_active_change_locked("");
            impl->broadcast_active_change_locked("", now_ms);
        }
    }

    if (!impl->dictation_enabled && impl->signaling_connected) {
        impl->ensure_signaling_disconnected_locked();
    }
}

} // extern "C"
