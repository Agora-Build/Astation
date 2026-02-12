cmake_minimum_required(VERSION 3.16)

project(AstationCore LANGUAGES C CXX)

if(APPLE AND NOT CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS deployment target")
endif()

add_library(astation_core STATIC
    core/src/astation_core.cpp
    core/src/astation_rtc.cpp
    core/src/astation_token.cpp
)

target_include_directories(astation_core
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/core/include>
        $<INSTALL_INTERFACE:include>
)
target_include_directories(astation_core PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/core/third_party/agora_token_builder
)

# Locate Agora RTC SDK headers per platform.
# On macOS: Download from Agora's SPM distribution (individual xcframework zips)
# On Linux/Windows: Look for manually extracted SDK
option(AGORA_SKIP_DOWNLOAD "Skip auto-download of Agora SDK (use local AGORA_SDK_DIR)" OFF)
set(AGORA_SDK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/agora" CACHE PATH "Path to Agora SDK root (contains rtc_mac/rtc_linux/rtc_win)")
set(AGORA_VERSION "4.6.2")

if(APPLE)
    set(AGORA_HEADERS "${AGORA_SDK_DIR}/rtc_mac/AgoraRtcKit.xcframework/macos-arm64_x86_64/AgoraRtcKit.framework/Headers")
elseif(UNIX)
    set(AGORA_HEADERS "${AGORA_SDK_DIR}/rtc_linux/include")
elseif(WIN32)
    set(AGORA_HEADERS "${AGORA_SDK_DIR}/rtc_win/include")
endif()

# Auto-download SDK if missing (macOS only, uses SPM distribution URLs)
if(APPLE AND NOT EXISTS "${AGORA_HEADERS}" AND NOT AGORA_SKIP_DOWNLOAD)
    message(STATUS "Agora RTC SDK not found, downloading from SPM distribution...")

    set(BASE_URL "https://download.agora.io/swiftpm/AgoraRtcEngine_macOS/${AGORA_VERSION}")
    set(FRAMEWORKS
        "AgoraRtcKit"
        "Agorafdkaac"
        "Agoraffmpeg"
        "AgoraSoundTouch"
        "video_dec"
        "AgoraScreenCaptureExtension"
        "AgoraAiNoiseSuppressionExtension"
    )

    file(MAKE_DIRECTORY "${AGORA_SDK_DIR}/rtc_mac")

    foreach(FW ${FRAMEWORKS})
        set(ZIP_FILE "${CMAKE_CURRENT_BINARY_DIR}/${FW}.xcframework.zip")
        set(ZIP_URL "${BASE_URL}/${FW}.xcframework.zip")

        message(STATUS "Downloading ${FW}.xcframework...")
        file(DOWNLOAD "${ZIP_URL}" "${ZIP_FILE}"
             SHOW_PROGRESS
             STATUS DOWNLOAD_STATUS)

        list(GET DOWNLOAD_STATUS 0 DOWNLOAD_ERROR)
        if(NOT DOWNLOAD_ERROR EQUAL 0)
            message(FATAL_ERROR "Failed to download ${FW} from ${ZIP_URL}")
        endif()

        message(STATUS "Extracting ${FW}.xcframework...")
        execute_process(
            COMMAND ${CMAKE_COMMAND} -E tar xzf "${ZIP_FILE}"
            WORKING_DIRECTORY "${AGORA_SDK_DIR}/rtc_mac"
            RESULT_VARIABLE EXTRACT_RESULT
        )

        if(NOT EXTRACT_RESULT EQUAL 0)
            message(FATAL_ERROR "Failed to extract ${FW}.xcframework")
        endif()

        file(REMOVE "${ZIP_FILE}")
        message(STATUS "Installed: ${FW}.xcframework")
    endforeach()

    message(STATUS "Agora RTC SDK installed to ${AGORA_SDK_DIR}/rtc_mac/")
endif()

if(APPLE)
    if(AGORA_SKIP_DOWNLOAD AND NOT EXISTS "${AGORA_HEADERS}")
        message(FATAL_ERROR
            "Agora RTC SDK not found at: ${AGORA_HEADERS}\n"
            "AGORA_SKIP_DOWNLOAD is ON. Provide a local SDK via -DAGORA_SDK_DIR=/path/to/sdk\n"
            "Expected structure: ${AGORA_SDK_DIR}/rtc_mac/<Framework>.xcframework/...")
    endif()
    # Fail fast if any expected framework bundles are missing.
    set(AGORA_EXPECTED_FRAMEWORK_DIRS "")
    foreach(FW ${FRAMEWORKS})
        list(APPEND AGORA_EXPECTED_FRAMEWORK_DIRS
            "${AGORA_SDK_DIR}/rtc_mac/${FW}.xcframework/macos-arm64_x86_64/${FW}.framework"
        )
    endforeach()
    foreach(FW_DIR IN LISTS AGORA_EXPECTED_FRAMEWORK_DIRS)
        if(NOT EXISTS "${FW_DIR}")
            message(FATAL_ERROR "Missing Agora framework bundle at: ${FW_DIR}")
        endif()
    endforeach()

    # AgoraRtcKit must provide headers for the core build.
    if(NOT EXISTS "${AGORA_HEADERS}")
        message(FATAL_ERROR "Missing AgoraRtcKit headers at: ${AGORA_HEADERS}")
    endif()

    file(GLOB AGORA_XCFRAMEWORK_HEADERS
        "${AGORA_SDK_DIR}/rtc_mac/*.xcframework/macos-arm64_x86_64/*.framework/Headers"
    )
    if(AGORA_XCFRAMEWORK_HEADERS)
        list(REMOVE_DUPLICATES AGORA_XCFRAMEWORK_HEADERS)
        target_include_directories(astation_core SYSTEM PRIVATE ${AGORA_XCFRAMEWORK_HEADERS})
        message(STATUS "Agora RTC SDK headers:")
        foreach(HDR_DIR IN LISTS AGORA_XCFRAMEWORK_HEADERS)
            message(STATUS "  ${HDR_DIR}")
        endforeach()
    else()
        message(FATAL_ERROR
            "Agora RTC SDK headers not found under: ${AGORA_SDK_DIR}/rtc_mac\n"
            "macOS: Run cmake again to auto-download")
    endif()
elseif(EXISTS "${AGORA_HEADERS}")
    target_include_directories(astation_core SYSTEM PRIVATE "${AGORA_HEADERS}")
    message(STATUS "Agora RTC SDK headers: ${AGORA_HEADERS}")
else()
    message(FATAL_ERROR
        "Agora RTC SDK not found at: ${AGORA_HEADERS}\n"
        "macOS: Run cmake again to auto-download\n"
        "Linux: Download from https://docs.agora.io/en/sdks?platform=linux\n"
        "Windows: Download from https://docs.agora.io/en/sdks?platform=windows")
endif()

# On Linux/Windows, add library search paths
if(UNIX AND NOT APPLE)
    set(AGORA_LIBS_DIR "${AGORA_SDK_DIR}/rtc_linux/libs")
    if(EXISTS "${AGORA_LIBS_DIR}")
        target_link_directories(astation_core PUBLIC "${AGORA_LIBS_DIR}")
    endif()
elseif(WIN32)
    set(AGORA_LIBS_DIR "${AGORA_SDK_DIR}/rtc_win/libs")
    if(EXISTS "${AGORA_LIBS_DIR}")
        target_link_directories(astation_core PUBLIC "${AGORA_LIBS_DIR}")
    endif()
endif()

target_compile_features(astation_core PUBLIC cxx_std_17)

find_package(ZLIB REQUIRED)
target_link_libraries(astation_core PRIVATE ZLIB::ZLIB)

if(NOT APPLE)
    find_package(OpenSSL REQUIRED)
    target_link_libraries(astation_core PRIVATE OpenSSL::Crypto)
endif()

if(MSVC)
    target_compile_options(astation_core PRIVATE /W4 /permissive-)
else()
    target_compile_options(astation_core PRIVATE -Wall -Wextra -Wpedantic)
endif()

add_library(Astation::core ALIAS astation_core)

include(CTest)

if(BUILD_TESTING)
    add_executable(astation_core_tests
        core/tests/session_manager_test.cpp
    )
    target_link_libraries(astation_core_tests PRIVATE astation_core)
    target_include_directories(astation_core_tests PRIVATE core/include)
    if(MSVC)
        target_compile_options(astation_core_tests PRIVATE /W4 /permissive-)
    else()
        target_compile_options(astation_core_tests PRIVATE -Wall -Wextra -Wpedantic)
    endif()
    add_test(NAME astation_core_tests COMMAND astation_core_tests)
endif()
