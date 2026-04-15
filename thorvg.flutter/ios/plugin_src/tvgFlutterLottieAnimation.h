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


TVG_FFI_EXPORT FlutterLottieAnimation* create();
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
