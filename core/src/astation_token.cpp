#include "astation_token.h"

#include <cstdlib>
#include <cstring>
#include <string>

#include "cpp/src/RtcTokenBuilder2.h"
#include "cpp/src/RtmTokenBuilder2.h"

namespace {

agora::tools::UserRole to_role(int role) {
    // 1 = publisher, 2 = subscriber (matches Agora's UserRole)
    if (role == 2) {
        return agora::tools::UserRole::kRoleSubscriber;
    }
    return agora::tools::UserRole::kRolePublisher;
}

char* dup_string(const std::string& input) {
    char* out = static_cast<char*>(std::malloc(input.size() + 1));
    if (!out) {
        return nullptr;
    }
    std::memcpy(out, input.data(), input.size());
    out[input.size()] = '\0';
    return out;
}

} // namespace

extern "C" char* astation_rtc_build_token(
    const char* app_id,
    const char* app_certificate,
    const char* channel_name,
    uint32_t uid,
    int role,
    uint32_t token_expire_seconds,
    uint32_t privilege_expire_seconds) {
    if (!app_id || !app_certificate || !channel_name) {
        return nullptr;
    }

    std::string token = agora::tools::RtcTokenBuilder2::BuildTokenWithUid(
        app_id,
        app_certificate,
        channel_name,
        uid,
        to_role(role),
        token_expire_seconds,
        privilege_expire_seconds);

    return dup_string(token);
}

extern "C" char* astation_rtm_build_token(
    const char* app_id,
    const char* app_certificate,
    const char* user_id,
    uint32_t token_expire_seconds) {
    if (!app_id || !app_certificate || !user_id) {
        return nullptr;
    }

    std::string token = agora::tools::RtmTokenBuilder2::BuildToken(
        app_id,
        app_certificate,
        user_id,
        token_expire_seconds);

    return dup_string(token);
}

extern "C" void astation_token_free(char* token) {
    std::free(token);
}
