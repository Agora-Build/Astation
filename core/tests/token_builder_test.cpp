#include "astation_token.h"

#include "cpp/src/AccessToken2.h"

#include <cassert>
#include <cstdint>
#include <iostream>
#include <string>

namespace {

constexpr const char* kAppId = "0123456789abcdef0123456789abcdef";
constexpr const char* kAppCert = "abcdef0123456789abcdef0123456789";

agora::tools::ServiceRtc* require_rtc_service(agora::tools::AccessToken2& token) {
    auto it = token.services_.find(agora::tools::ServiceRtc::kServiceType);
    assert(it != token.services_.end());
    auto* service = dynamic_cast<agora::tools::ServiceRtc*>(it->second.get());
    assert(service != nullptr);
    return service;
}

agora::tools::ServiceRtm* require_rtm_service(agora::tools::AccessToken2& token) {
    auto it = token.services_.find(agora::tools::ServiceRtm::kServiceType);
    assert(it != token.services_.end());
    auto* service = dynamic_cast<agora::tools::ServiceRtm*>(it->second.get());
    assert(service != nullptr);
    return service;
}

std::string build_rtc_token(
    const char* channel,
    uint32_t uid,
    int role,
    uint32_t token_expire,
    uint32_t privilege_expire) {
    char* token = astation_rtc_build_token(
        kAppId,
        kAppCert,
        channel,
        uid,
        role,
        token_expire,
        privilege_expire);
    assert(token != nullptr);
    std::string token_str(token);
    astation_token_free(token);
    return token_str;
}

std::string build_rtm_token(
    const char* user_id,
    uint32_t token_expire) {
    char* token = astation_rtm_build_token(
        kAppId,
        kAppCert,
        user_id,
        token_expire);
    assert(token != nullptr);
    std::string token_str(token);
    astation_token_free(token);
    return token_str;
}

void test_rtc_publisher() {
    const std::string channel = "test-channel";
    const int uid_int = 1234;
    const uint32_t token_expire = 600;
    const uint32_t privilege_expire = 300;

    std::string token = build_rtc_token(
        channel.c_str(),
        static_cast<uint32_t>(uid_int),
        1,
        token_expire,
        privilege_expire);

    assert(token.rfind("007", 0) == 0);

    agora::tools::AccessToken2 parsed;
    assert(parsed.FromString(token));
    assert(parsed.app_id_ == kAppId);
    assert(parsed.expire_ == token_expire);

    auto* service = require_rtc_service(parsed);
    assert(service->channel_name_ == channel);
    assert(service->account_ == std::to_string(uid_int));
    assert(service->privileges_.size() == 4);
    assert(service->privileges_.at(agora::tools::ServiceRtc::kPrivilegeJoinChannel) == privilege_expire);
    assert(service->privileges_.at(agora::tools::ServiceRtc::kPrivilegePublishAudioStream) == privilege_expire);
    assert(service->privileges_.at(agora::tools::ServiceRtc::kPrivilegePublishVideoStream) == privilege_expire);
    assert(service->privileges_.at(agora::tools::ServiceRtc::kPrivilegePublishDataStream) == privilege_expire);
}

void test_rtc_subscriber() {
    const std::string channel = "test-subscriber";
    const int uid_int = 77;
    const uint32_t token_expire = 1200;
    const uint32_t privilege_expire = 900;

    std::string token = build_rtc_token(
        channel.c_str(),
        static_cast<uint32_t>(uid_int),
        2,
        token_expire,
        privilege_expire);

    agora::tools::AccessToken2 parsed;
    assert(parsed.FromString(token));
    assert(parsed.app_id_ == kAppId);
    assert(parsed.expire_ == token_expire);

    auto* service = require_rtc_service(parsed);
    assert(service->channel_name_ == channel);
    assert(service->account_ == std::to_string(uid_int));
    assert(service->privileges_.size() == 1);
    assert(service->privileges_.at(agora::tools::ServiceRtc::kPrivilegeJoinChannel) == privilege_expire);
}

void test_rtc_uid_zero() {
    const std::string channel = "uid-zero";
    std::string token = build_rtc_token(channel.c_str(), 0, 2, 60, 60);

    agora::tools::AccessToken2 parsed;
    assert(parsed.FromString(token));
    auto* service = require_rtc_service(parsed);
    assert(service->channel_name_ == channel);
    assert(service->account_.empty());
}

void test_rtm_token() {
    const std::string user_id = "user-42";
    const uint32_t token_expire = 3600;

    std::string token = build_rtm_token(user_id.c_str(), token_expire);

    agora::tools::AccessToken2 parsed;
    assert(parsed.FromString(token));
    assert(parsed.app_id_ == kAppId);
    assert(parsed.expire_ == token_expire);

    auto* service = require_rtm_service(parsed);
    assert(service->user_id_ == user_id);
    assert(service->privileges_.size() == 1);
    assert(service->privileges_.at(agora::tools::ServiceRtm::kPrivilegeLogin) == token_expire);
}

void test_invalid_app_id() {
    const std::string channel = "invalid-app";
    char* token = astation_rtc_build_token(
        "not-a-uuid",
        kAppCert,
        channel.c_str(),
        1,
        1,
        60,
        60);
    assert(token != nullptr);
    assert(std::string(token).empty());
    astation_token_free(token);
}

void test_invalid_app_cert() {
    const std::string channel = "invalid-cert";
    char* token = astation_rtc_build_token(
        kAppId,
        "not-a-uuid",
        channel.c_str(),
        1,
        1,
        60,
        60);
    assert(token != nullptr);
    assert(std::string(token).empty());
    astation_token_free(token);
}

void test_rtm_invalid_cert() {
    char* token = astation_rtm_build_token(
        kAppId,
        "not-a-uuid",
        "user",
        60);
    assert(token != nullptr);
    assert(std::string(token).empty());
    astation_token_free(token);
}

} // namespace

int main() {
    test_rtc_publisher();
    test_rtc_subscriber();
    test_rtc_uid_zero();
    test_rtm_token();
    test_invalid_app_id();
    test_invalid_app_cert();
    test_rtm_invalid_cert();

    std::cout << "token_builder_test: ok\n";
    return 0;
}
