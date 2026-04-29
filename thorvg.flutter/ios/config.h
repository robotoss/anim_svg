#ifndef _THORVG_FLUTTER_IOS_CONFIG_H_
#define _THORVG_FLUTTER_IOS_CONFIG_H_

#define THORVG_VERSION_STRING "1.0.3"

#define THORVG_SW_RASTER_SUPPORT 1
// GL backend, OpenGL ES target. Sources vendored from upstream thorvg
// v1.0.3 in src/renderer/gl_engine/. Compile + link only — the upstream
// __APPLE__ branch in tvgGl.cpp:134-158 dlopen()s
// /System/Library/Frameworks/OpenGL.framework/OpenGL which exists on
// macOS but NOT on iOS, so glInit() fails at runtime here. Sprint 5
// swaps the runtime in by routing GLES through ANGLE-Metal, after
// which the runtime path is functional.
#define THORVG_GL_RASTER_SUPPORT 1
#define THORVG_GL_TARGET_GLES 1
#define THORVG_THREAD_SUPPORT 1
#define THORVG_FILE_IO_SUPPORT 1

// Smart-render: thorvg tracks dirty regions per frame and skips re-rasterizing
// untouched pixels. Combine with `SwCanvas::gen(EngineOption::SmartRender)`.
#define THORVG_PARTIAL_RENDER_SUPPORT 1

#define THORVG_LOTTIE_LOADER_SUPPORT 1
#define THORVG_PNG_LOADER_SUPPORT   1
#define THORVG_JPG_LOADER_SUPPORT   1

// NEON SIMD: arm64 device + arm64 simulator (M1/M2/M3 host) ship `arm_neon.h`.
// x86_64 simulator slice does not, so the macro is gated by compiler-defined
// arch macros. clang predefines __ARM_NEON for armv7 and __aarch64__ /
// __ARM_NEON for arm64.
#if defined(__aarch64__) || defined(__arm64__) || defined(__ARM_NEON)
  #define THORVG_NEON_VECTOR_SUPPORT 1
#endif

#endif
