/*
 * ANGLE-Metal EGL bridge for thorvg's GL backend on iOS.
 *
 * One instance per ThorvgTexture. Owns a per-CVPixelBufferRef cache of
 * EGLSurfaces created via the EGL_ANGLE_iosurface_client_buffer
 * extension. The EGLDisplay (Metal-backed via
 * EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE) and EGLContext are
 * process-shared and refcounted across instances — eglMakeCurrent only
 * ever rebinds the surface, never the context, so multi-texture
 * switches are cheap (no MTLDevice / MTLCommandQueue churn).
 *
 * Thread model: mirrors the Android EglRenderContext. All calls
 * (create, bindPixelBuffer, makeCurrent, present, dtor) must run on
 * the single shared `io.thorvg.render` DispatchQueue from
 * ThorvgPlusPlugin (already enforced by ThorvgTexture.kt's queue
 * parameter; see ThorvgPlusPlugin.swift:26).
 *
 * Sprint 5: this class is a pure addition. ThorvgBridge.mm and the SW
 * render path are unchanged. Sprint 6 swaps TvgLottieAnimation onto
 * tvg::GlCanvas backed by this context per the hybrid useGl flag.
 *
 * The libEGL.xcframework + libGLESv2.xcframework binaries vendored at
 * thorvg.flutter/ios/Frameworks/ are extracted from
 * Knightro63/flutter_angle (MIT, see FLUTTER_ANGLE_LICENSE).
 */

#pragma once

// Framework-style include — EGL ships inside libEGL.xcframework, so the
// header lives at libEGL.framework/Headers/EGL/egl.h. The umbrella
// header in the framework uses the same path; we mirror that here.
#include <libEGL/EGL/egl.h>
#include <CoreVideo/CoreVideo.h>

#include <memory>

namespace thorvg_plus {

class AngleRenderContext {
public:
    // Acquire the process-shared ANGLE-Metal display+context (refcounted,
    // lazy-init). Returns nullptr if the EGLDisplay can't be created (e.g.
    // ANGLE binary missing) or the GLES3 context can't be made.
    static std::unique_ptr<AngleRenderContext> create();

    // Decrements the shared refcount, destroys all EGLSurfaces this
    // instance cached, terminates the shared display+context when the
    // refcount hits zero.
    ~AngleRenderContext();

    AngleRenderContext(const AngleRenderContext&) = delete;
    AngleRenderContext& operator=(const AngleRenderContext&) = delete;

    // Find or create the EGLSurface for `pb` and remember it for the
    // lifetime of this instance. Subsequent calls with the same
    // CVPixelBufferRef hit the cache. Returns false on EGL failure.
    bool bindPixelBuffer(CVPixelBufferRef pb);

    // Bind the most recently bound pixel buffer's EGLSurface as the
    // read+draw target on the shared context. Returns false if no
    // surface is bound or eglMakeCurrent fails.
    bool makeCurrent();

    // Wait for the GPU to drain the command buffer that drew into the
    // currently bound IOSurface, so the consumer (Flutter raster
    // thread) sees a complete frame when textureFrameAvailable fires.
    // Cheap CPU wait via eglWaitGL; v2 (post-Sprint 7) could promote
    // to MTLCommandBuffer.addCompletedHandler for zero CPU cost.
    bool present();

    EGLDisplay display() const;
    EGLContext context() const;
    EGLSurface currentSurface() const { return m_currentSurface; }

private:
    AngleRenderContext() = default;

    EGLSurface m_currentSurface = EGL_NO_SURFACE;

    // Opaque to header — the cache type lives in the .mm to avoid
    // pulling <unordered_map> + IOSurface here. ABI-private.
    struct SurfaceCache;
    SurfaceCache* m_cache = nullptr;
};

}  // namespace thorvg_plus
