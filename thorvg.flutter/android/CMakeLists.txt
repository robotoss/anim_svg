cmake_minimum_required(VERSION 3.18.1)
project(thorvg CXX)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

add_compile_options(
  -fno-exceptions
  -fno-rtti
  -fno-math-errno
  -fvisibility=hidden
  -fvisibility-inlines-hidden
  -w
)

add_compile_definitions(TVG_STATIC=1)

set(PLUGIN_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/..")
set(THORVG_ROOT "${PLUGIN_ROOT}/thorvg")

include_directories(
  ${CMAKE_CURRENT_SOURCE_DIR}
  ${PLUGIN_ROOT}/src
  ${THORVG_ROOT}/inc
  ${THORVG_ROOT}/src/common
  ${THORVG_ROOT}/src/renderer
  ${THORVG_ROOT}/src/renderer/sw_engine
  ${THORVG_ROOT}/src/loaders/lottie
  ${THORVG_ROOT}/src/loaders/png
  ${THORVG_ROOT}/src/loaders/jpg
  ${THORVG_ROOT}/src/loaders/raw
)

file(GLOB PLUGIN_SRC    "${PLUGIN_ROOT}/src/*.cpp")
file(GLOB COMMON_SRC    "${THORVG_ROOT}/src/common/*.cpp")
file(GLOB RENDERER_SRC  "${THORVG_ROOT}/src/renderer/*.cpp")
file(GLOB SW_ENGINE_SRC "${THORVG_ROOT}/src/renderer/sw_engine/*.cpp")
file(GLOB LOTTIE_SRC    "${THORVG_ROOT}/src/loaders/lottie/tvgLottie*.cpp")
file(GLOB PNG_SRC       "${THORVG_ROOT}/src/loaders/png/*.cpp")
file(GLOB JPG_SRC       "${THORVG_ROOT}/src/loaders/jpg/*.cpp")
file(GLOB RAW_SRC       "${THORVG_ROOT}/src/loaders/raw/*.cpp")

# JNI bridge — exposes the existing extern "C" API to Kotlin via
# Java_com_robotoss_thorvg_1plus_* native methods, plus a
# Surface-aware render path that skips Bitmap/ui.Image entirely.
file(GLOB JNI_SRC       "${CMAKE_CURRENT_SOURCE_DIR}/src/main/cpp/*.cpp")

add_library(thorvg SHARED
  ${PLUGIN_SRC}
  ${COMMON_SRC}
  ${RENDERER_SRC}
  ${SW_ENGINE_SRC}
  ${LOTTIE_SRC}
  ${PNG_SRC}
  ${JPG_SRC}
  ${RAW_SRC}
  ${JNI_SRC}
)

# Enable NEON SIMD rasterization on ARM ABIs only. arm_neon.h is unavailable
# on x86 / x86_64 ABIs, so the macro must not be defined there or the SwRaster
# NEON branches fail to compile.
if(ANDROID_ABI STREQUAL "arm64-v8a" OR ANDROID_ABI STREQUAL "armeabi-v7a")
  target_compile_definitions(thorvg PRIVATE THORVG_NEON_VECTOR_SUPPORT=1)
  if(ANDROID_ABI STREQUAL "armeabi-v7a")
    # arm64 has NEON enabled by default; armv7 needs an explicit flag.
    target_compile_options(thorvg PRIVATE -mfpu=neon)
  endif()
endif()

# `android` provides ANativeWindow_fromSurface / lock / unlockAndPost,
# used by jni_bridge.cpp to blit the SwCanvas buffer directly into the
# Flutter SurfaceTexture without an intermediate Bitmap.
target_link_libraries(thorvg PRIVATE log android)

# Android 15+ uses 16 KB memory pages; ELF LOAD segments must be aligned to
# 16384 bytes or the loader falls back to page-size-compat mode (and Play
# Console rejects uploads with targetSdk >= 35). Rust's bundled lld does
# not inherit this from the NDK, but for the C++ toolchain setting both
# max-page-size and common-page-size at link time is sufficient.
if(ANDROID)
  target_link_options(thorvg PRIVATE
    "-Wl,-z,max-page-size=16384"
    "-Wl,-z,common-page-size=16384")
endif()
