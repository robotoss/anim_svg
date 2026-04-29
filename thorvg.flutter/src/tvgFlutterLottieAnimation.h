/*
 * Copyright (c) 2024 - 2026 ThorVG project. All rights reserved.

 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:

 * The above copyright notice and this permission notice shall be included in all
 * copies or substantial portions of the Software.

 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#include <stdint.h>
#include <stdbool.h>

#if defined(_WIN32)
  #define TVG_FFI_EXPORT __declspec(dllexport)
#else
  #define TVG_FFI_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

typedef struct _FlutterLottieAnimation FlutterLottieAnimation;

#ifdef __cplusplus
extern "C"
{
#endif


// Existing SW path: SwCanvas + heap buffer the bridge memcpy's into the
// platform surface. Backwards compatible — render() returns the buffer.
TVG_FFI_EXPORT FlutterLottieAnimation* create();

// GL path (sprint 6, hybrid toggle): GlCanvas backed by an EGL context the
// bridge owns. Requirements:
//  1. Bridge must call set_gl_context(...) BEFORE load() / resize() so the
//     first GlCanvas::target(...) inside resize() has valid opaque handles.
//  2. The EGL context MUST be current on the calling thread for every
//     load / update / render / resize call (target / draw / sync touch GL
//     state on whatever context is bound right now).
//  3. render() returns nullptr in GL mode — the FBO is the output surface,
//     no CPU buffer exists.
// All other methods (load, update, render, resize, frame, ...) work
// identically in both modes; the engine is selected once at create time
// and never changes.
TVG_FFI_EXPORT FlutterLottieAnimation* create_gl();
TVG_FFI_EXPORT void set_gl_context(FlutterLottieAnimation* animation,
                                   void* display, void* surface, void* context);

TVG_FFI_EXPORT bool destroy(FlutterLottieAnimation* animation);
TVG_FFI_EXPORT const char* error(FlutterLottieAnimation* animation);
TVG_FFI_EXPORT float* size(FlutterLottieAnimation* animation);
TVG_FFI_EXPORT float duration(FlutterLottieAnimation* animation);
TVG_FFI_EXPORT float totalFrame(FlutterLottieAnimation* animation);
TVG_FFI_EXPORT float curFrame(FlutterLottieAnimation* animation);
TVG_FFI_EXPORT void resize(FlutterLottieAnimation* animation, int w, int h);
TVG_FFI_EXPORT bool load(FlutterLottieAnimation* animation, char* data, char* mimetype, int width, int height);
TVG_FFI_EXPORT uint8_t* render(FlutterLottieAnimation* animation);
TVG_FFI_EXPORT bool frame(FlutterLottieAnimation* animation, float no);
TVG_FFI_EXPORT bool update(FlutterLottieAnimation* animation);


#ifdef __cplusplus
}
#endif
