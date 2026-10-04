#include "astation_screen_capture.h"

#include <cassert>
#include <cstdint>
#include <vector>

int main() {
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
