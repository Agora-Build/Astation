#include "astation_screen_capture.h"

#include <cassert>
#include <cstdint>
#include <vector>

int main() {
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
