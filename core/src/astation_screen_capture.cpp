#include "astation_screen_capture.h"

int64_t astation_select_screen_source(const AstationScreenSource* sources,
                                      size_t count,
                                      int64_t requested_id) {
    if (!sources || count == 0 || requested_id > 0) {
        return requested_id;
    }

    int64_t first_screen_id = requested_id;
    int64_t primary_id = requested_id;
    int has_screen = 0;

    for (size_t i = 0; i < count; ++i) {
        if (!sources[i].is_screen) {
            continue;
        }
        if (!has_screen) {
            first_screen_id = sources[i].source_id;
            has_screen = 1;
        }
        if (sources[i].is_primary) {
            primary_id = sources[i].source_id;
            return primary_id;
        }
    }

    if (has_screen) {
        return first_screen_id;
    }
    return requested_id;
}
