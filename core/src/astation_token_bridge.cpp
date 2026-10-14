#include "astation_token.h"
#include "atem_core.h"

#include <cstdlib>
#include <cstring>

namespace {
// Preserve the existing C API's malloc/free ownership and empty-on-error behavior.
char* copy_result(int32_t status, char* value, char* error) {
    const char* text = status == ATEM_CORE_OK && value ? value : "";
    const size_t length = std::strlen(text);
    auto* result = static_cast<char*>(std::malloc(length + 1));
    if (result) std::memcpy(result, text, length + 1);
    atem_core_string_free(value);
    atem_core_string_free(error);
    return result;
}
}

extern "C" char* astation_rtc_build_token(const char* app_id, const char* certificate,
    const char* channel, uint32_t uid, int role, uint32_t token_expire, uint32_t privilege_expire) {
    if (!app_id || !certificate || !channel) return nullptr;
    AtemCoreRtcTokenParams params{};
    params.struct_size = sizeof(params);
    params.app_id = app_id; params.app_certificate = certificate; params.channel = channel;
    params.uid = uid;
    // The legacy API defaults every non-subscriber role to publisher.
    params.role = role == 2 ? ATEM_CORE_ROLE_SUBSCRIBER : ATEM_CORE_ROLE_PUBLISHER;
    params.token_expire = token_expire; params.privilege_expire = privilege_expire;
    char* token = nullptr;
    char* error = nullptr;
    if (atem_core_abi_version() != ATEM_CORE_ABI_VERSION) return copy_result(99, nullptr, nullptr);
    const auto status = atem_core_build_rtc_token(&params, &token, &error);
    return copy_result(status, token, error);
}

extern "C" char* astation_rtm_build_token(const char* app_id, const char* certificate,
    const char* user, uint32_t token_expire) {
    if (!app_id || !certificate || !user) return nullptr;
    AtemCoreRtmTokenParams params{};
    params.struct_size = sizeof(params);
    params.app_id = app_id; params.app_certificate = certificate;
    params.user_id = user; params.expire = token_expire;
    char* token = nullptr;
    char* error = nullptr;
    if (atem_core_abi_version() != ATEM_CORE_ABI_VERSION) return copy_result(99, nullptr, nullptr);
    const auto status = atem_core_build_rtm_token(&params, &token, &error);
    return copy_result(status, token, error);
}

extern "C" void astation_token_free(char* token) { std::free(token); }
