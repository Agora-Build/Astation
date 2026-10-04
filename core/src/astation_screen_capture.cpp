#include "astation_screen_capture.h"
#include <cstring>

int astation_copy_nv12_planes(uint8_t* output, size_t output_size,
                               const uint8_t* y, size_t y_stride,
                               const uint8_t* uv, size_t uv_stride,
                               int width, int height) {
    if (!output || !y || !uv || width <= 0 || height <= 0 ||
        width % 2 != 0 || height % 2 != 0 ||
        y_stride < static_cast<size_t>(width) || uv_stride < static_cast<size_t>(width)) return -1;
    const size_t y_size = static_cast<size_t>(width) * height;
    if (output_size < y_size + y_size / 2) return -1;
    for (int row = 0; row < height; ++row) {
        std::memcpy(output + static_cast<size_t>(row) * width, y + row * y_stride, width);
    }
    for (int row = 0; row < height / 2; ++row) {
        std::memcpy(output + y_size + static_cast<size_t>(row) * width, uv + row * uv_stride, width);
    }
    return 0;
}

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
