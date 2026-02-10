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
