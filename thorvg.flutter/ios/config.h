#ifndef _THORVG_FLUTTER_IOS_CONFIG_H_
#define _THORVG_FLUTTER_IOS_CONFIG_H_

#define THORVG_VERSION_STRING "1.0.3"

#define THORVG_SW_RASTER_SUPPORT 1
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
