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

#include <thorvg.h>
#include "tvgFlutterLottieAnimation.h"

#if defined(__ANDROID__)
  #include <android/log.h>
  #define TVG_FLUTTER_LOG(...) \
      __android_log_print(ANDROID_LOG_ERROR, "ThorvgPlus.anim", __VA_ARGS__)
#elif defined(__APPLE__)
  #include <stdio.h>
  #define TVG_FLUTTER_LOG(...) fprintf(stderr, "[ThorvgPlus.anim] " __VA_ARGS__)
#else
  #define TVG_FLUTTER_LOG(...) ((void)0)
#endif

using namespace std;
using namespace tvg;

static const char* NoError = "None";

class __attribute__((visibility("default"))) TvgLottieAnimation
{
public:
    ~TvgLottieAnimation()
    {
        // GL canvas owns no CPU buffer (the FBO is the output); only free
        // for the SW path. Initializer::term is refcounted globally either
        // way, so calling it here is correct in both modes.
        if (!useGl) free(buffer);
        Initializer::term();
    }

    static TvgLottieAnimation* create()
    {
        return new TvgLottieAnimation(/*useGl*/false);
    }

    static TvgLottieAnimation* create_gl()
    {
        return new TvgLottieAnimation(/*useGl*/true);
    }

    // Bridge calls this after creating the EGL/ANGLE context but BEFORE
    // load() so the resize() inside load() has valid opaque handles to
    // pass into GlCanvas::target. Re-issues target() if the size is
    // already known so a swap of the surface (e.g. SurfaceProducer
    // recreation on Android) doesn't strand the canvas.
    //
    // The EGL context MUST be current on the calling thread; GlCanvas::
    // target touches GL state at call time.
    void setGlContext(void* display, void* surface, void* context)
    {
        glDisplay = display;
        glSurface = surface;
        glContext = context;
        if (useGl && canvas && width > 0 && height > 0)
        {
            canvas->sync();
            static_cast<GlCanvas*>(canvas)->target(
                glDisplay, glSurface, glContext, /*fbo*/0,
                width, height, ColorSpace::ABGR8888S);
        }
    }

    bool load(char* data, char* mimetype, int width, int height)
    {
        // Preserve the constructor-time error (e.g. "init() fail",
        // "Invalid canvas") if the engine is not in a usable state —
        // resetting to NoError here would mask that diagnosis at the
        // Dart side (sprint 6e regression: GL constructor failures
        // surfaced as the meaningless "Lottie load failed: None").
        if (!canvas) return false;

        errorMsg = NoError;

        if (data != nullptr && data[0] == '\0')
        {
            errorMsg = "Invalid data";
            return false;
        }

        canvas->remove();

        delete(animation);
        animation = Animation::gen();

        if (animation->picture()->load(data, strlen(data), "lottie+json", "", false) != Result::Success)
        {
            errorMsg = "load() fail";
            return false;
        }

        animation->picture()->size(&psize[0], &psize[1]);

        /* need to reset size to calculate scale in Picture.size internally before calling resize() */
        this->width = 0;
        this->height = 0;

        resize(width, height);

        if (canvas->add(animation->picture()) != Result::Success)
        {
            errorMsg = "add() fail";
            return false;
        }

        updated = true;

        return true;
    }

    bool update()
    {
        if (!updated) return true;

        errorMsg = NoError;

        if (canvas->update() != Result::Success)
        {
            errorMsg = "update() fail";
            return false;
        }

        return true;
    }

    uint8_t* render()
    {
        errorMsg = NoError;

        if (!canvas || !animation)
            return nullptr;

        // SW path: short-circuit only when nothing changed. GL path
        // always draws — the FBO is consumed by eglSwapBuffers (Android)
        // or eglWaitGL + textureFrameAvailable (iOS), and skipping a
        // draw would publish a stale frame to Flutter's compositor.
        if (!updated && !useGl)
            return buffer;

        if (canvas->draw(true) != Result::Success)
        {
            errorMsg = "draw() fail";
            return nullptr;
        }

        canvas->sync();

        updated = false;

        // GL path has no CPU buffer to return — the FBO is the output.
        // Bridge ignores the return value in GL mode (sees nullptr).
        return useGl ? nullptr : buffer;
    }

    float* size()
    {
        return psize;
    }

    void resize(int w, int h)
    {
        if (!canvas || !animation) return;
        if (width == w && height == h) return;

        canvas->sync();

        width = w;
        height = h;

        if (useGl)
        {
            // FBO 0 = the EGL window surface (Android) or the IOSurface
            // pbuffer (iOS, ANGLE) the bridge made current. Bridge MUST
            // have set both context and current binding before this call.
            // No CPU buffer in GL mode.
            if (glDisplay && glSurface && glContext)
            {
                static_cast<GlCanvas*>(canvas)->target(
                    glDisplay, glSurface, glContext, /*fbo*/0,
                    width, height, ColorSpace::ABGR8888S);
            }
        }
        else
        {
            buffer = (uint8_t*)realloc(buffer, width * height * sizeof(uint32_t));
            static_cast<SwCanvas*>(canvas)->target(
                (uint32_t*)buffer, width, width, height, ColorSpace::ABGR8888S);
        }

        float scale;
        float shiftX = 0.0f, shiftY = 0.0f;
        if (psize[0] > psize[1])
        {
            scale = width / psize[0];
            shiftY = (height - psize[1] * scale) * 0.5f;
        }
        else
        {
            scale = height / psize[1];
            shiftX = (width - psize[0] * scale) * 0.5f;
        }
        animation->picture()->scale(scale);
        animation->picture()->translate(shiftX, shiftY);

        updated = true;
    }

    float duration()
    {
        if (!canvas || !animation) return 0;
        return animation->duration();
    }

    float totalFrame()
    {
        if (!canvas || !animation) return 0;
        return animation->totalFrame();
    }

    float curFrame()
    {
        if (!canvas || !animation) return 0;
        return animation->curFrame();
    }

    bool frame(float no)
    {
        if (!canvas || !animation) return false;
        if (animation->frame(no) == Result::Success)
        {
            updated = true;
        }
        return true;
    }

    const char* error()
    {
        return errorMsg;
    }

private:
    explicit TvgLottieAnimation(bool useGlEngine) : useGl(useGlEngine)
    {
        errorMsg = NoError;

        // Initializer::init is reference-counted globally; only the first
        // call's `threads` value takes effect (subsequent calls just bump
        // the counter). Passing N>0 spins up N internal worker threads that
        // SwCanvas::draw uses for parallel scanline rasterization, and also
        // turns thorvg's internal ScopedLocks from no-ops into real
        // mutexes (see tvgLock.h).
        //
        // 4 is a deliberate cap: too high adds task-dispatch overhead for
        // small (<= 1 MPix) frames, too low loses parallelism on the slow
        // SwCanvas path. The GL path benefits from the worker threads as
        // well — thorvg's GlRenderer tessellates beziers on the CPU
        // before dispatching to GPU, and that tessellation parallelises.
        if (Initializer::init(4) != Result::Success)
        {
            errorMsg = "init() fail";
            TVG_FLUTTER_LOG("Initializer::init(4) failed");
            return;
        }

        if (useGl)
        {
            // EngineOption::SmartRender is silently ignored on GlCanvas
            // (tvgCanvas.cpp:209 logs a warning + falls through). For
            // dynamic compositions the GPU still beats SW; for mostly-
            // static logos the consumer should opt back into the SW
            // engine via create() and skip set_gl_context entirely.
            canvas = GlCanvas::gen();
        }
        else
        {
            // EngineOption::SmartRender enables thorvg's partial-redraw
            // path, gated by THORVG_PARTIAL_RENDER_SUPPORT in config.h.
            // For mostly-static compositions (slot-machine style logos
            // with small moving elements) this avoids re-rasterizing the
            // unchanged background every frame, which is the common case
            // in list scenarios — and the reason create() (SW) is still
            // the default in sprint 6.
            canvas = SwCanvas::gen(EngineOption::SmartRender);
        }
        if (!canvas) {
            errorMsg = useGl ? "GlCanvas::gen returned null — engine not "
                               "compiled with THORVG_GL_RASTER_SUPPORT, "
                               "or Initializer::engineInit==0 at gen time"
                             : "SwCanvas::gen returned null";
            TVG_FLUTTER_LOG("%s", errorMsg);
        }

        animation = Animation::gen();
        if (!animation) errorMsg = "Invalid animation";
    }

private:
    const char* errorMsg;
    // Base pointer so the same field holds either SwCanvas* or GlCanvas*;
    // call sites that touch the engine-specific target() overload must
    // static_cast based on `useGl`.
    Canvas* canvas = nullptr;
    Animation* animation = nullptr;
    uint8_t* buffer = nullptr;       // SW only — heap raster output
    uint32_t width = 0;
    uint32_t height = 0;
    float psize[2]; // picture size
    bool updated = false;
    const bool useGl = false;
    // GL only — opaque EGL/ANGLE handles set via setGlContext() before
    // the first resize. Both Sw and Gl modes ignore these unless useGl.
    void* glDisplay = nullptr;
    void* glSurface = nullptr;
    void* glContext = nullptr;
};

#ifdef __cplusplus
extern "C"
{
#endif

    FlutterLottieAnimation* create()
    {
        return (FlutterLottieAnimation*)TvgLottieAnimation::create();
    }

    FlutterLottieAnimation* create_gl()
    {
        return (FlutterLottieAnimation*)TvgLottieAnimation::create_gl();
    }

    void set_gl_context(FlutterLottieAnimation* animation,
                        void* display, void* surface, void* context)
    {
        if (!animation) return;
        reinterpret_cast<TvgLottieAnimation*>(animation)
            ->setGlContext(display, surface, context);
    }

    bool destroy(FlutterLottieAnimation* animation)
    {
        if (!animation) return false;
        delete (reinterpret_cast<TvgLottieAnimation*>(animation));
        return true;
    }

    bool load(FlutterLottieAnimation* animation, char* data, char* mimetype, int width, int height)
    {
        return reinterpret_cast<TvgLottieAnimation*>(animation)->load(data, mimetype, width, height);
    }

    bool update(FlutterLottieAnimation* animation)
    {
        return reinterpret_cast<TvgLottieAnimation*>(animation)->update();
    }

    uint8_t* render(FlutterLottieAnimation* animation)
    {
        return reinterpret_cast<TvgLottieAnimation*>(animation)->render();
    }

    float* size(FlutterLottieAnimation* animation)
    {
        return reinterpret_cast<TvgLottieAnimation*>(animation)->size();
    }

    void resize(FlutterLottieAnimation* animation, int w, int h)
    {
        return reinterpret_cast<TvgLottieAnimation*>(animation)->resize(w, h);
    }

    float duration(FlutterLottieAnimation* animation)
    {
        return reinterpret_cast<TvgLottieAnimation*>(animation)->duration();
    }

    float totalFrame(FlutterLottieAnimation* animation)
    {
        return reinterpret_cast<TvgLottieAnimation*>(animation)->totalFrame();
    }

    float curFrame(FlutterLottieAnimation* animation)
    {
        return reinterpret_cast<TvgLottieAnimation*>(animation)->curFrame();
    }

    bool frame(FlutterLottieAnimation* animation, float no)
    {
        return reinterpret_cast<TvgLottieAnimation*>(animation)->frame(no);
    }

    const char* error(FlutterLottieAnimation* animation)
    {
        return reinterpret_cast<TvgLottieAnimation*>(animation)->error();
    }

#ifdef __cplusplus
}
#endif
