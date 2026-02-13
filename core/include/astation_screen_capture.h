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
} AstationScreenSource;

int64_t astation_select_screen_source(const AstationScreenSource* sources,
                                      size_t count,
                                      int64_t requested_id);

#ifdef __cplusplus
}  // extern "C"
#endif
