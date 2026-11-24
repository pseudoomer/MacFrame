cmake_minimum_required(VERSION 3.22)
set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0" CACHE STRING "Minimum macOS version")
project(MacFrame VERSION 0.1.0 LANGUAGES C CXX OBJC OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_ARCHITECTURES "arm64")

add_compile_options(-Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations -O3)

find_library(FOUNDATION_FW Foundation REQUIRED)
find_library(APPKIT_FW AppKit REQUIRED)
find_library(METAL_FW Metal REQUIRED)
find_library(COREVIDEO_FW CoreVideo REQUIRED)
find_library(COREMEDIA_FW CoreMedia REQUIRED)
find_library(VIDEOTOOLBOX_FW VideoToolbox REQUIRED)
find_library(AVFOUNDATION_FW AVFoundation REQUIRED)
find_library(IOSURFACE_FW IOSurface REQUIRED)
find_library(OPENGL_FW OpenGL REQUIRED)

# 1. Core Engine Shared Library: libmacframe.dylib
add_library(macframe SHARED
    engine/src/mf_timeline.cpp
    engine/src/mf_governor.cpp
    engine/src/mf_metal_context.mm
    engine/src/mf_ipc.mm
    engine/src/mf_autohook.mm
    engine/src/mf_engine.mm
)

target_include_directories(macframe
    PUBLIC  ${CMAKE_CURRENT_SOURCE_DIR}/engine/include
    PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/engine/src
)

target_compile_options(macframe PRIVATE -fobjc-arc)

set_target_properties(macframe PROPERTIES
    VERSION 1.0.0
    SOVERSION 1
    INSTALL_NAME_DIR "@rpath"
    BUILD_WITH_INSTALL_RPATH ON
)

target_link_libraries(macframe PUBLIC
    ${FOUNDATION_FW}
    ${APPKIT_FW}
    ${METAL_FW}
    ${COREVIDEO_FW}
    ${COREMEDIA_FW}
    ${VIDEOTOOLBOX_FW}
    ${IOSURFACE_FW}
)

# 2. Benchmark & Evaluation CLI: mfbench
add_executable(mfbench
    tools/mfbench/main.mm
)
target_compile_options(mfbench PRIVATE -fobjc-arc)
target_link_libraries(mfbench PRIVATE
    macframe
    ${AVFOUNDATION_FW}
)

# 3. Headless libmpv Integration Harness: mpvharness
add_executable(mpvharness
    tools/mpvharness/mpvharness.c
)
target_include_directories(mpvharness PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/mpv-0.38
)
target_link_libraries(mpvharness PRIVATE
    ${OPENGL_FW}
)
target_link_options(mpvharness PRIVATE
    "-Wl,-rpath,/Applications/IINA.app/Contents/Frameworks"
)

# 4. Unit & GPU Regression Tests: mftests
enable_testing()
add_executable(mftests
    tests/test_all.mm
    engine/src/mf_timeline.cpp
    engine/src/mf_governor.cpp
)
target_include_directories(mftests PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/engine/include
    ${CMAKE_CURRENT_SOURCE_DIR}/engine/src
)
target_compile_options(mftests PRIVATE -fobjc-arc)
target_link_libraries(mftests PRIVATE
    macframe
)
add_test(NAME MacFrameTests COMMAND mftests)
