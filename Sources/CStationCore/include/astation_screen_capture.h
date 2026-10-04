#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AstationScreenSource {
    int64_t source_id;
    int is_screen;
    int is_primary;
    int x;
    int y;
    int width;
    int height;
} AstationScreenSource;

int64_t astation_select_screen_source(const AstationScreenSource* sources,
                                      size_t count,
                                      int64_t requested_id);
int astation_copy_nv12_planes(uint8_t* output, size_t output_size,
                               const uint8_t* y, size_t y_stride,
                               const uint8_t* uv, size_t uv_stride,
                               int width, int height);

#ifdef __cplusplus
}  // extern "C"
#endif
