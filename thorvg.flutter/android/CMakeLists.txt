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

add_library(thorvg SHARED
  ${PLUGIN_SRC}
  ${COMMON_SRC}
  ${RENDERER_SRC}
  ${SW_ENGINE_SRC}
  ${LOTTIE_SRC}
  ${PNG_SRC}
  ${JPG_SRC}
  ${RAW_SRC}
)

target_link_libraries(thorvg PRIVATE log)
