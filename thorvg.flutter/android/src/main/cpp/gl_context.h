/*
 * EGL bridge for thorvg's GL backend on Android.
 *
 * Owns one EGLSurface per ThorvgTexture (1:1 with the SurfaceProducer
 * window the Flutter raster thread samples). The EGLDisplay and
 * EGLContext are process-shared and refcounted across instances so
 * thorvg's GlRenderer can keep one shader/program cache for all
 * textures, and so eglMakeCurrent only ever switches the bound
 * surface (cheap), never the context (expensive ioctl).
 *
 * Lifecycle: all calls (create, makeCurrent, swapBuffers, resize,
 * destructor) must happen on the same thread — typically the shared
 * Handler/Looper that ThorvgTexture.kt already serializes JNI calls
 * onto. The shared display+context is lazily initialised on the
 * first create() call and destroyed when the last instance dies.
 *
 * Sprint 4: this class is a pure addition. It is not yet wired into
 * jni_bridge.cpp; the SW path is unchanged. Sprint 6 swaps the C++
 * adapter to use it.
 */

#pragma once

#include <EGL/egl.h>
#include <android/native_window.h>

#include <memory>

namespace thorvg_plus {

class EglRenderContext {
public:
    // Acquire (and refcount) the process-shared EGLDisplay + EGLContext,
    // then create a window surface from `window`. Returns nullptr on any
    // EGL failure (display unavailable, no matching config, etc.); the
    // caller logs and falls back to the SW path.
    //
    // `window` must be a live ANativeWindow obtained from
    // ANativeWindow_fromSurface; ownership is NOT transferred — this
    // class only borrows it for the lifetime of the EGLSurface.
    static std::unique_ptr<EglRenderContext> create(ANativeWindow* window);

    // Destroys this instance's EGLSurface and decrements the shared
    // context refcount; when the refcount hits zero the shared display
    // and context are destroyed too.
    ~EglRenderContext();

    EglRenderContext(const EglRenderContext&) = delete;
    EglRenderContext& operator=(const EglRenderContext&) = delete;

    // Bind this surface as both read and draw target. Returns false on
    // EGL failure (typically EGL_BAD_SURFACE after the window was
    // destroyed by the platform).
    bool makeCurrent();

    // Post the rendered backbuffer to the consumer (Flutter's
    // SurfaceProducer / ImageReader). Implies a glFlush.
    bool swapBuffers();

    // Recreate the EGLSurface against potentially new ANativeWindow
    // geometry. Call this after the consumer side resizes the
    // SurfaceProducer; the caller must then re-issue
    // GlCanvas::target(display, surface, context, 0, w, h, ...).
    bool resize(int w, int h);

    EGLDisplay display() const;
    EGLContext context() const;
    EGLSurface surface() const { return m_surface; }

private:
    EglRenderContext() = default;

    EGLSurface m_surface = EGL_NO_SURFACE;
    ANativeWindow* m_window = nullptr;
};

}  // namespace thorvg_plus
