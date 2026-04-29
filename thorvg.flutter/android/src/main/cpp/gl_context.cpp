/*
 * Implementation notes:
 *
 *  - EGLDisplay + EGLContext are static (process-shared). First call to
 *    create() initialises them; refcount tracks live EglRenderContext
 *    instances; last destructor tears them down.
 *
 *  - Config selection prefers GLES3 (EGL_OPENGL_ES3_BIT). Stencil 8 is
 *    required because thorvg's GlRenderer uses stencil for clipping;
 *    DEPTH_SIZE 0 (vector compositing has no z); SAMPLE_BUFFERS 0
 *    (thorvg does its own AA via tessellation fans).
 *
 *  - On Android emulator the GLES3 client API context creation can
 *    fail on some host driver combinations; we fall back to GLES2 only
 *    in that case (thorvg's gl_engine compiles fine against either).
 *
 *  - All static state is guarded by a single mutex. The render path
 *    is single-threaded (Kotlin's shared render Handler/Looper) so
 *    contention here is effectively zero — the lock exists only for
 *    the create/destroy edges.
 */

#include "gl_context.h"

#include <android/log.h>

#include <mutex>

#define LOG_TAG "ThorvgPlus.gl"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)

namespace thorvg_plus {
namespace {

std::mutex& sharedMutex() {
    static std::mutex m;
    return m;
}

EGLDisplay s_display = EGL_NO_DISPLAY;
EGLContext s_context = EGL_NO_CONTEXT;
EGLConfig  s_config  = nullptr;
int        s_refcount = 0;

bool ensureSharedLocked() {
    if (s_display != EGL_NO_DISPLAY) return true;

    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display == EGL_NO_DISPLAY) {
        LOGE("eglGetDisplay failed: 0x%x", eglGetError());
        return false;
    }
    if (!eglInitialize(display, nullptr, nullptr)) {
        LOGE("eglInitialize failed: 0x%x", eglGetError());
        return false;
    }

    const EGLint configAttribs[] = {
        EGL_SURFACE_TYPE,    EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE,        8,
        EGL_GREEN_SIZE,      8,
        EGL_BLUE_SIZE,       8,
        EGL_ALPHA_SIZE,      8,
        EGL_DEPTH_SIZE,      0,
        EGL_STENCIL_SIZE,    8,
        EGL_SAMPLE_BUFFERS,  0,
        EGL_NONE,
    };
    EGLConfig config = nullptr;
    EGLint    numConfigs = 0;
    if (!eglChooseConfig(display, configAttribs, &config, 1, &numConfigs) ||
        numConfigs < 1) {
        LOGE("eglChooseConfig (GLES3) failed: 0x%x", eglGetError());
        eglTerminate(display);
        return false;
    }

    const EGLint contextAttribs3[] = {
        EGL_CONTEXT_CLIENT_VERSION, 3,
        EGL_NONE,
    };
    EGLContext context =
        eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttribs3);
    if (context == EGL_NO_CONTEXT) {
        LOGI("GLES3 context unavailable (0x%x); falling back to GLES2",
             eglGetError());
        const EGLint contextAttribs2[] = {
            EGL_CONTEXT_CLIENT_VERSION, 2,
            EGL_NONE,
        };
        context = eglCreateContext(display, config, EGL_NO_CONTEXT,
                                   contextAttribs2);
    }
    if (context == EGL_NO_CONTEXT) {
        LOGE("eglCreateContext failed: 0x%x", eglGetError());
        eglTerminate(display);
        return false;
    }

    s_display = display;
    s_context = context;
    s_config  = config;
    return true;
}

void releaseSharedLocked() {
    if (s_refcount > 0) return;
    if (s_display != EGL_NO_DISPLAY) {
        // Detach any current binding before destroying — avoids EGL
        // BAD_CONTEXT errors during teardown if something else is mid
        // makeCurrent on the shared context.
        eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                       EGL_NO_CONTEXT);
        if (s_context != EGL_NO_CONTEXT) {
            eglDestroyContext(s_display, s_context);
        }
        eglTerminate(s_display);
    }
    s_display = EGL_NO_DISPLAY;
    s_context = EGL_NO_CONTEXT;
    s_config  = nullptr;
}

}  // namespace

std::unique_ptr<EglRenderContext> EglRenderContext::create(
        ANativeWindow* window) {
    if (!window) return nullptr;

    std::lock_guard<std::mutex> lk(sharedMutex());
    if (!ensureSharedLocked()) return nullptr;

    // Match the SW path's pixel-format choice so the consumer sees the
    // same byte order whether SW (memcpy ABGR8888S) or GL (glClear /
    // GlCanvas writes RGBA8) produces the frame. Width/height passed
    // as 0 lets the surface inherit the consumer-side geometry, which
    // is what SurfaceProducer/ImageReader configure.
    if (ANativeWindow_setBuffersGeometry(window, 0, 0,
                                         WINDOW_FORMAT_RGBA_8888) != 0) {
        LOGE("ANativeWindow_setBuffersGeometry failed");
        releaseSharedLocked();
        return nullptr;
    }

    EGLSurface surface = eglCreateWindowSurface(s_display, s_config, window,
                                                nullptr);
    if (surface == EGL_NO_SURFACE) {
        LOGE("eglCreateWindowSurface failed: 0x%x", eglGetError());
        releaseSharedLocked();
        return nullptr;
    }

    auto ctx = std::unique_ptr<EglRenderContext>(new EglRenderContext());
    ctx->m_surface = surface;
    ctx->m_window  = window;
    ++s_refcount;
    return ctx;
}

EglRenderContext::~EglRenderContext() {
    std::lock_guard<std::mutex> lk(sharedMutex());
    if (m_surface != EGL_NO_SURFACE && s_display != EGL_NO_DISPLAY) {
        eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                       EGL_NO_CONTEXT);
        eglDestroySurface(s_display, m_surface);
    }
    --s_refcount;
    releaseSharedLocked();
}

bool EglRenderContext::makeCurrent() {
    if (s_display == EGL_NO_DISPLAY || m_surface == EGL_NO_SURFACE ||
        s_context == EGL_NO_CONTEXT) {
        return false;
    }
    if (!eglMakeCurrent(s_display, m_surface, m_surface, s_context)) {
        LOGE("eglMakeCurrent failed: 0x%x", eglGetError());
        return false;
    }
    return true;
}

bool EglRenderContext::swapBuffers() {
    if (s_display == EGL_NO_DISPLAY || m_surface == EGL_NO_SURFACE) {
        return false;
    }
    if (!eglSwapBuffers(s_display, m_surface)) {
        LOGE("eglSwapBuffers failed: 0x%x", eglGetError());
        return false;
    }
    return true;
}

bool EglRenderContext::resize(int w, int h) {
    if (s_display == EGL_NO_DISPLAY || !m_window) return false;
    std::lock_guard<std::mutex> lk(sharedMutex());

    // Rebuild surface; eglCreateWindowSurface with the same window after
    // an underlying buffer geometry change is the documented recipe.
    if (m_surface != EGL_NO_SURFACE) {
        eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                       EGL_NO_CONTEXT);
        eglDestroySurface(s_display, m_surface);
        m_surface = EGL_NO_SURFACE;
    }
    if (ANativeWindow_setBuffersGeometry(m_window, w, h,
                                         WINDOW_FORMAT_RGBA_8888) != 0) {
        LOGE("setBuffersGeometry(%d,%d) failed during resize", w, h);
        return false;
    }
    m_surface = eglCreateWindowSurface(s_display, s_config, m_window, nullptr);
    if (m_surface == EGL_NO_SURFACE) {
        LOGE("eglCreateWindowSurface (resize) failed: 0x%x", eglGetError());
        return false;
    }
    return true;
}

EGLDisplay EglRenderContext::display() const { return s_display; }
EGLContext EglRenderContext::context() const { return s_context; }

}  // namespace thorvg_plus
