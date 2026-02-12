#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Builds an RTC token using Agora's AccessToken2 (C++ implementation).
// Returns a heap-allocated C string that must be freed with astation_token_free.
char* astation_rtc_build_token(
    const char* app_id,
    const char* app_certificate,
    const char* channel_name,
    uint32_t uid,
    int role,
    uint32_t token_expire_seconds,
    uint32_t privilege_expire_seconds);

// Builds an RTM token using Agora's AccessToken2 (C++ implementation).
// Returns a heap-allocated C string that must be freed with astation_token_free.
char* astation_rtm_build_token(
    const char* app_id,
    const char* app_certificate,
    const char* user_id,
    uint32_t token_expire_seconds);

void astation_token_free(char* token);

#ifdef __cplusplus
}
#endif
