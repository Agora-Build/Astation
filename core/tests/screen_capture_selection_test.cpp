#include "astation_screen_capture.h"
#include "astation_rtc_audio_plan.h"

#include <cassert>
#include <cstdint>
#include <vector>

int main() {
    {
        // Screen start/stop and mute must not overwrite the other audio source.
        const auto mic = astation_rtc_audio_plan(true, true, false, false, 12, 34);
        assert(!mic.microphone && mic.custom && !mic.mixed && mic.custom_track == 12);
        const auto both = astation_rtc_audio_plan(true, true, false, true, 12, 34);
        assert(!both.microphone && !both.custom && both.mixed && both.mix_microphone);
        const auto muted = astation_rtc_audio_plan(true, true, true, true, 12, 34);
        assert(muted.mixed && !muted.mix_microphone && !muted.custom);
        const auto silent = astation_rtc_audio_plan(true, true, true, false, 12, 34);
        assert(!silent.microphone && !silent.custom && !silent.mixed);
        const auto native = astation_rtc_audio_plan(true, false, false, true, 12, 34);
        assert(native.microphone && native.custom && !native.mixed && native.custom_track == 34);
        const auto screen = astation_rtc_audio_plan(false, true, false, true, 12, 34);
        assert(!screen.microphone && screen.custom && !screen.mixed && screen.custom_track == 34);
    }
    {
        // Plane gaps and different row strides must not appear as pixels in the outgoing frame.
        const uint8_t y[] = {1, 2, 3, 4, 99, 99, 5, 6, 7, 8, 99, 99};
        const uint8_t uv[] = {9, 10, 11, 12, 99, 99, 99, 99};
        uint8_t output[12]{};
        assert(astation_copy_nv12_planes(output, sizeof(output), y, 6, uv, 8, 4, 2) == 0);
        const std::vector<uint8_t> expected = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12};
        assert(std::vector<uint8_t>(output, output + 12) == expected);
        assert(astation_copy_nv12_planes(output, 11, y, 6, uv, 8, 4, 2) == -1);
        assert(astation_copy_nv12_planes(output, 12, y, 3, uv, 8, 4, 2) == -1);
        assert(astation_copy_nv12_planes(output, 12, y, 6, uv, 8, 3, 2) == -1);
    }
    {
        // Requested display id wins when provided.
        AstationScreenSource sources[] = {
            {123, 1, 0, 0, 0, 0, 0},
            {456, 1, 1, 0, 0, 0, 0},
        };
        int64_t resolved = astation_select_screen_source(sources, 2, 999);
        assert(resolved == 999);
    }

    {
        // No sources, return requested (zero or negative).
        int64_t resolved = astation_select_screen_source(nullptr, 0, 0);
        assert(resolved == 0);
    }

    {
        // First screen is selected if no primary is marked.
        std::vector<AstationScreenSource> sources = {
            {101, 1, 0, 0, 0, 0, 0},
            {202, 1, 0, 0, 0, 0, 0},
        };
        int64_t resolved = astation_select_screen_source(sources.data(), sources.size(), 0);
        assert(resolved == 101);
    }

    {
        // Primary screen should be selected even if not first.
        std::vector<AstationScreenSource> sources = {
            {101, 1, 0, 0, 0, 0, 0},
            {202, 1, 1, 0, 0, 0, 0},
            {303, 1, 0, 0, 0, 0, 0},
        };
        int64_t resolved = astation_select_screen_source(sources.data(), sources.size(), 0);
        assert(resolved == 202);
    }

    {
        // Ignore non-screen sources.
        std::vector<AstationScreenSource> sources = {
            {101, 0, 0, 0, 0, 0, 0},
            {202, 1, 0, 0, 0, 0, 0},
        };
        int64_t resolved = astation_select_screen_source(sources.data(), sources.size(), 0);
        assert(resolved == 202);
    }

    return 0;
}
