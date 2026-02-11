cmake_minimum_required(VERSION 3.16)

project(AstationCore LANGUAGES C CXX)

add_library(astation_core STATIC
    core/src/astation_core.cpp
    core/src/astation_rtc.cpp
)

target_include_directories(astation_core
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/core/include>
        $<INSTALL_INTERFACE:include>
)

# Locate Agora RTC SDK headers per platform.
# SDK layout:
#   macOS:   third_party/agora/rtc_mac/libs/AgoraRtcKit.xcframework/.../Headers/
#   Linux:   third_party/agora/rtc_linux/include/
#   Windows: third_party/agora/rtc_win/include/
set(AGORA_SDK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/agora")

if(APPLE)
    set(AGORA_HEADERS "${AGORA_SDK_DIR}/rtc_mac/libs/AgoraRtcKit.xcframework/macos-arm64_x86_64/AgoraRtcKit.framework/Versions/A/Headers")
elseif(UNIX)
    set(AGORA_HEADERS "${AGORA_SDK_DIR}/rtc_linux/include")
elseif(WIN32)
    set(AGORA_HEADERS "${AGORA_SDK_DIR}/rtc_win/include")
endif()

if(NOT EXISTS "${AGORA_HEADERS}")
    message(STATUS "Agora RTC SDK not found at: ${AGORA_HEADERS}")
    message(STATUS "Attempting to download Agora RTC SDK...")

    if(APPLE)
        set(SDK_URL "https://download.agora.io/sdk/release/Agora_Native_SDK_for_Mac_FULL.zip")
        set(SDK_ZIP "${CMAKE_CURRENT_BINARY_DIR}/agora_sdk.zip")

        # Download SDK
        file(DOWNLOAD "${SDK_URL}" "${SDK_ZIP}"
             SHOW_PROGRESS
             STATUS DOWNLOAD_STATUS)

        list(GET DOWNLOAD_STATUS 0 DOWNLOAD_ERROR)
        if(NOT DOWNLOAD_ERROR EQUAL 0)
            message(FATAL_ERROR "Failed to download Agora RTC SDK from ${SDK_URL}")
        endif()

        # Extract SDK
        message(STATUS "Extracting Agora RTC SDK...")
        execute_process(
            COMMAND ${CMAKE_COMMAND} -E tar xzf "${SDK_ZIP}"
            WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}"
            RESULT_VARIABLE EXTRACT_RESULT
        )

        if(NOT EXTRACT_RESULT EQUAL 0)
            message(FATAL_ERROR "Failed to extract Agora RTC SDK")
        endif()

        # Find extracted directory
        file(GLOB SDK_EXTRACTED_DIRS "${CMAKE_CURRENT_BINARY_DIR}/Agora_Native_SDK_for_Mac_*")
        list(GET SDK_EXTRACTED_DIRS 0 SDK_EXTRACTED_DIR)

        # Move xcframeworks to expected location
        file(MAKE_DIRECTORY "${AGORA_SDK_DIR}/rtc_mac/libs")
        file(GLOB XCFRAMEWORKS "${SDK_EXTRACTED_DIR}/libs/*.xcframework")
        foreach(XCFW ${XCFRAMEWORKS})
            get_filename_component(XCFW_NAME ${XCFW} NAME)
            file(COPY ${XCFW} DESTINATION "${AGORA_SDK_DIR}/rtc_mac/libs/")
            message(STATUS "Installed: ${XCFW_NAME}")
        endforeach()

        # Clean up
        file(REMOVE "${SDK_ZIP}")
        file(REMOVE_RECURSE "${SDK_EXTRACTED_DIR}")

        message(STATUS "Agora RTC SDK installed to ${AGORA_SDK_DIR}/rtc_mac/libs/")
    elseif(UNIX)
        message(FATAL_ERROR
            "Agora RTC SDK not found at: ${AGORA_HEADERS}\n"
            "Download from https://docs.agora.io/en/sdks?platform=linux and extract to third_party/agora/rtc_linux/")
    elseif(WIN32)
        message(FATAL_ERROR
            "Agora RTC SDK not found at: ${AGORA_HEADERS}\n"
            "Download from https://docs.agora.io/en/sdks?platform=windows and extract to third_party/agora/rtc_win/")
    endif()
endif()

if(EXISTS "${AGORA_HEADERS}")
    target_include_directories(astation_core PRIVATE "${AGORA_HEADERS}")
    message(STATUS "Agora RTC SDK headers: ${AGORA_HEADERS}")
else()
    message(FATAL_ERROR "Agora RTC SDK installation failed")
endif()

# On Linux, also add library search path for linking
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
