#ifndef _THORVG_FLUTTER_ANDROID_CONFIG_H_
#define _THORVG_FLUTTER_ANDROID_CONFIG_H_

#define THORVG_VERSION_STRING "1.0.3"

#define THORVG_SW_RASTER_SUPPORT 1
#define THORVG_THREAD_SUPPORT 1
#define THORVG_FILE_IO_SUPPORT 1

// Smart-render: thorvg tracks dirty regions per frame and skips re-rasterizing
// untouched pixels. Big win for slot-machine-style logos with mostly-static
// backgrounds and small moving elements. Combine with
// `SwCanvas::gen(EngineOption::SmartRender)`.
#define THORVG_PARTIAL_RENDER_SUPPORT 1

#define THORVG_LOTTIE_LOADER_SUPPORT 1
#define THORVG_PNG_LOADER_SUPPORT   1
#define THORVG_JPG_LOADER_SUPPORT   1

// NEON SIMD for ARM ABIs is enabled via -DTHORVG_NEON_VECTOR_SUPPORT in
// CMakeLists.txt (gated by ANDROID_ABI to avoid breaking x86/x86_64 builds
// where arm_neon.h does not exist).

#endif
