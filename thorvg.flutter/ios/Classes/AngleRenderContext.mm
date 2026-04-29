/*
 * Implementation notes:
 *
 *  - Display init: eglGetPlatformDisplayEXT with
 *    EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE selects ANGLE's Metal
 *    backend, the only viable GLES path on iOS post-12.
 *
 *  - Per-pixel-buffer surfaces: eglCreatePbufferFromClientBuffer with
 *    EGL_IOSURFACE_ANGLE wraps each CVPixelBuffer's IOSurface as an
 *    EGL pbuffer. EGL_TEXTURE_INTERNAL_FORMAT_ANGLE = GL_BGRA_EXT
 *    pushes the BGRA<->RGBA swizzle into Metal's sampler config; the
 *    sw-path's vImagePermuteChannels_ARGB8888 CPU pass goes away
 *    entirely once Sprint 6 wires this in.
 *
 *  - Surface cache: each ThorvgTexture pool yields a small set of
 *    CVPixelBufferRefs (typically 3 — see
 *    ThorvgTexture.swift:297). We cache one EGLSurface per ref so
 *    bindPixelBuffer is O(1) after warmup. Cache is cleared in dtor;
 *    the pool itself holds the strong refs to the buffers.
 *
 *  - Sharing: one shared EGLDisplay + EGLContext for the whole
 *    process. Refcount tracked under a single mutex (negligible
 *    contention — render queue is serial). Last instance destroyed
 *    -> eglDestroyContext + eglTerminate.
 */

#import "AngleRenderContext.h"

#import <Foundation/Foundation.h>
// iOS exposes IOSurface as IOSurfaceRef.h (C-only API). The
// macOS-style umbrella `<IOSurface/IOSurface.h>` is not present in
// the iPhoneOS / iPhoneSimulator SDKs; using it errors out at the
// preprocessor stage.
#import <IOSurface/IOSurfaceRef.h>

#include <libEGL/EGL/eglext.h>
#include <libEGL/EGL/eglext_angle.h>

#include <mutex>
#include <unordered_map>

#define LOG_PREFIX "[ThorvgPlus.angle] "

namespace thorvg_plus {

struct AngleRenderContext::SurfaceCache {
    std::unordered_map<CVPixelBufferRef, EGLSurface> map;
};

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

    auto getPlatformDisplayEXT =
        reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
            eglGetProcAddress("eglGetPlatformDisplayEXT"));
    if (!getPlatformDisplayEXT) {
        NSLog(@LOG_PREFIX "eglGetPlatformDisplayEXT not exported by ANGLE");
        return false;
    }

    const EGLint displayAttribs[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
        EGL_NONE,
    };
    // ANGLE's eglplatform.h on iOS types EGLNativeDisplayType as `int`
    // (unlike standard EGL where it is void*). The platform display
    // function still wants a void*; cast through intptr_t to keep
    // -Wint-to-pointer-cast quiet.
    EGLDisplay display = getPlatformDisplayEXT(
        EGL_PLATFORM_ANGLE_ANGLE,
        reinterpret_cast<void*>(static_cast<intptr_t>(EGL_DEFAULT_DISPLAY)),
        displayAttribs);
    if (display == EGL_NO_DISPLAY) {
        NSLog(@LOG_PREFIX "eglGetPlatformDisplayEXT(METAL) failed: 0x%x",
              eglGetError());
        return false;
    }
    if (!eglInitialize(display, nullptr, nullptr)) {
        NSLog(@LOG_PREFIX "eglInitialize failed: 0x%x", eglGetError());
        return false;
    }

    // Pbuffer (not window) surface type — we render into an IOSurface
    // bound as a client buffer, never into a CAMetalLayer-backed window.
    // Stencil 8 is required for thorvg's clip planes; depth not needed.
    const EGLint configAttribs[] = {
        EGL_SURFACE_TYPE,    EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE,        8,
        EGL_GREEN_SIZE,      8,
        EGL_BLUE_SIZE,       8,
        EGL_ALPHA_SIZE,      8,
        EGL_DEPTH_SIZE,      0,
        EGL_STENCIL_SIZE,    8,
        EGL_NONE,
    };
    EGLConfig config = nullptr;
    EGLint    numConfigs = 0;
    if (!eglChooseConfig(display, configAttribs, &config, 1, &numConfigs) ||
        numConfigs < 1) {
        NSLog(@LOG_PREFIX "eglChooseConfig (GLES3 pbuffer) failed: 0x%x",
              eglGetError());
        eglTerminate(display);
        return false;
    }

    const EGLint contextAttribs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 3,
        EGL_NONE,
    };
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT,
                                          contextAttribs);
    if (context == EGL_NO_CONTEXT) {
        NSLog(@LOG_PREFIX "eglCreateContext (GLES3) failed: 0x%x",
              eglGetError());
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

EGLSurface createPbufferForIOSurface(IOSurfaceRef ioSurface, int w, int h) {
    // EGL_TEXTURE_INTERNAL_FORMAT_ANGLE = GL_BGRA_EXT pushes the
    // R<->B channel swap into ANGLE's Metal texture binding so the
    // GPU shader writes BGRA bytes directly into the IOSurface
    // memory that CVPixelBufferPool gave us — no CPU swizzle.
    constexpr EGLint GL_BGRA_EXT_VAL = 0x80E1;
    const EGLint surfaceAttribs[] = {
        EGL_WIDTH,                          w,
        EGL_HEIGHT,                         h,
        EGL_IOSURFACE_PLANE_ANGLE,          0,
        EGL_TEXTURE_TARGET,                 EGL_TEXTURE_RECTANGLE_ANGLE,
        EGL_TEXTURE_INTERNAL_FORMAT_ANGLE,  GL_BGRA_EXT_VAL,
        EGL_TEXTURE_FORMAT,                 EGL_TEXTURE_RGBA,
        EGL_TEXTURE_TYPE_ANGLE,             0x1401,  // GL_UNSIGNED_BYTE
        EGL_NONE,
    };
    EGLSurface surface = eglCreatePbufferFromClientBuffer(
        s_display, EGL_IOSURFACE_ANGLE,
        static_cast<EGLClientBuffer>(ioSurface),
        s_config, surfaceAttribs);
    if (surface == EGL_NO_SURFACE) {
        NSLog(@LOG_PREFIX "eglCreatePbufferFromClientBuffer failed: 0x%x",
              eglGetError());
    }
    return surface;
}

}  // namespace

std::unique_ptr<AngleRenderContext> AngleRenderContext::create() {
    std::lock_guard<std::mutex> lk(sharedMutex());
    if (!ensureSharedLocked()) return nullptr;

    auto ctx = std::unique_ptr<AngleRenderContext>(new AngleRenderContext());
    ctx->m_cache = new SurfaceCache();
    ++s_refcount;
    return ctx;
}

AngleRenderContext::~AngleRenderContext() {
    std::lock_guard<std::mutex> lk(sharedMutex());
    if (m_cache) {
        if (s_display != EGL_NO_DISPLAY) {
            eglMakeCurrent(s_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                           EGL_NO_CONTEXT);
            for (auto& kv : m_cache->map) {
                if (kv.second != EGL_NO_SURFACE) {
                    eglDestroySurface(s_display, kv.second);
                }
            }
        }
        delete m_cache;
        m_cache = nullptr;
    }
    m_currentSurface = EGL_NO_SURFACE;
    --s_refcount;
    releaseSharedLocked();
}

bool AngleRenderContext::bindPixelBuffer(CVPixelBufferRef pb) {
    if (!pb || !m_cache) return false;
    std::lock_guard<std::mutex> lk(sharedMutex());
    if (s_display == EGL_NO_DISPLAY) return false;

    auto it = m_cache->map.find(pb);
    if (it == m_cache->map.end()) {
        IOSurfaceRef ioSurface = CVPixelBufferGetIOSurface(pb);
        if (!ioSurface) {
            NSLog(@LOG_PREFIX
                  "CVPixelBufferGetIOSurface returned NULL — pool must "
                  "set kCVPixelBufferIOSurfacePropertiesKey to enable "
                  "IOSurface backing");
            return false;
        }
        const int w = static_cast<int>(CVPixelBufferGetWidth(pb));
        const int h = static_cast<int>(CVPixelBufferGetHeight(pb));
        EGLSurface surface = createPbufferForIOSurface(ioSurface, w, h);
        if (surface == EGL_NO_SURFACE) return false;
        m_cache->map.emplace(pb, surface);
        m_currentSurface = surface;
    } else {
        m_currentSurface = it->second;
    }
    return true;
}

bool AngleRenderContext::makeCurrent() {
    if (s_display == EGL_NO_DISPLAY || s_context == EGL_NO_CONTEXT ||
        m_currentSurface == EGL_NO_SURFACE) {
        return false;
    }
    if (!eglMakeCurrent(s_display, m_currentSurface, m_currentSurface,
                        s_context)) {
        NSLog(@LOG_PREFIX "eglMakeCurrent failed: 0x%x", eglGetError());
        return false;
    }
    return true;
}

bool AngleRenderContext::present() {
    if (s_display == EGL_NO_DISPLAY) return false;
    // For pbuffer surfaces eglSwapBuffers is a no-op, but eglWaitGL
    // flushes the GLES command queue and waits for the GPU to drain
    // it — necessary so Flutter's raster thread reads a complete
    // frame from the IOSurface after textureFrameAvailable fires.
    if (!eglWaitGL()) {
        NSLog(@LOG_PREFIX "eglWaitGL failed: 0x%x", eglGetError());
        return false;
    }
    return true;
}

EGLDisplay AngleRenderContext::display() const { return s_display; }
EGLContext AngleRenderContext::context() const { return s_context; }

}  // namespace thorvg_plus
