/*
 * JNI bridge for thorvg_plus Texture-based renderer.
 *
 * Exposes the existing extern "C" API of TvgLottieAnimation
 * (declared in `tvgFlutterLottieAnimation.h`) to Kotlin, with one extra
 * composite call that:
 *
 *   1) sets the requested animation frame,
 *   2) updates the canvas,
 *   3) rasterizes (SwCanvas::draw + sync), and
 *   4) blits the resulting buffer directly into the Flutter SurfaceTexture
 *      via ANativeWindow_lock / unlockAndPost.
 *
 * The composite call is invoked from a per-texture HandlerThread on the
 * Kotlin side, so the Flutter UI isolate is never blocked by software
 * rasterization. See ADR for the underlying jank diagnosis.
 */

#include <jni.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <android/log.h>
#include <cstring>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <unordered_map>

#include "tvgFlutterLottieAnimation.h"
#include "gl_context.h"

#define LOG_TAG "ThorvgPlus"
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// Serializes the global thorvg engine init/term reference counter that lives
// inside `TvgLottieAnimation`'s constructor / destructor. Without this a burst
// of texture creations or disposals on different per-texture HandlerThreads
// races on the non-atomic `engineInit++`/`--` counter inside thorvg's
// `Initializer`, which corrupts global LoaderMgr / TaskScheduler state and
// surfaces as a SIGSEGV deep inside `canvas->update()`.
static std::mutex& engineInitMutex() {
    static std::mutex m;
    return m;
}

// Per-handle ANativeWindow cache.
//
// Calling `ANativeWindow_fromSurface` + `ANativeWindow_release` every frame
// causes a binder transaction that occasionally retains a fence file
// descriptor in `BnTransactionCompletedListener` parcels. After ~minutes of
// 60 Hz scrolling with many textures this exhausts the per-process fd
// budget — `fcntl(F_DUPFD_CLOEXEC) failed, error: Too many open files` —
// and Flutter's raster thread aborts inside `SurfaceTexture.updateTexImage`.
//
// We acquire the window once per texture (via `nativeAttachSurface`) and
// reuse it across frames. The map is keyed by the same `jlong` we hand back
// to Kotlin from `nativeCreate`, so each ThorvgTexture owns exactly one
// cached `ANativeWindow*` for its lifetime.
static std::mutex g_windowsMutex;
static std::unordered_map<jlong, ANativeWindow*> g_windows;

static ANativeWindow* lookupWindowLocked(jlong handle) {
    auto it = g_windows.find(handle);
    return it == g_windows.end() ? nullptr : it->second;
}

// GL bridge state. The presence of a handle in g_glContexts is the
// authoritative "this animation is in GL mode" check used by the render
// path; the SW path is unchanged for handles absent from this map.
//
// Lifecycle:
//   nativeCreateGl   -> allocates the C++ TvgLottieAnimation via create_gl
//                       and inserts a (handle, nullptr) entry so subsequent
//                       calls know this is a GL handle even before a
//                       surface is attached.
//   nativeAttachSurface(GL) -> creates EglRenderContext from the
//                              ANativeWindow and stores it; then makes the
//                              context current and calls set_gl_context so
//                              later resize() inside load() can target the
//                              GlCanvas onto FBO 0.
//   nativeRenderFrame(GL)   -> makeCurrent -> frame/update/render ->
//                              swapBuffers.
//   nativeDetachSurface(GL) -> tears down the EglRenderContext (and its
//                              EGLSurface) but keeps the C++ animation.
//   nativeDestroy(GL)       -> tears down both.
static std::unordered_map<jlong, std::unique_ptr<thorvg_plus::EglRenderContext>>
    g_glContexts;

static bool isGlHandleLocked(jlong handle) {
    return g_glContexts.find(handle) != g_glContexts.end();
}

static thorvg_plus::EglRenderContext* lookupGlContextLocked(jlong handle) {
    auto it = g_glContexts.find(handle);
    if (it == g_glContexts.end()) return nullptr;
    return it->second.get();
}

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_robotoss_thorvg_1plus_ThorvgTexture_nativeCreate(
        JNIEnv* /*env*/, jobject /*thiz*/) {
    std::lock_guard<std::mutex> lk(engineInitMutex());
    return reinterpret_cast<jlong>(create());
}

// GL counterpart of nativeCreate. Allocates a TvgLottieAnimation built
// around tvg::GlCanvas (see tvgFlutterLottieAnimation.cpp::create_gl).
// Inserts a placeholder entry into g_glContexts so subsequent calls
// recognise the handle as GL even before the EGL context exists; the
// real EglRenderContext is created later by nativeAttachSurface, when
// the ANativeWindow is available.
JNIEXPORT jlong JNICALL
Java_com_robotoss_thorvg_1plus_ThorvgTexture_nativeCreateGl(
        JNIEnv* /*env*/, jobject /*thiz*/) {
    std::lock_guard<std::mutex> lk(engineInitMutex());
    auto* anim = create_gl();
    if (!anim) return 0;
    {
        std::lock_guard<std::mutex> wlk(g_windowsMutex);
        g_glContexts.emplace(reinterpret_cast<jlong>(anim), nullptr);
    }
    return reinterpret_cast<jlong>(anim);
}

JNIEXPORT void JNICALL
Java_com_robotoss_thorvg_1plus_ThorvgTexture_nativeDestroy(
        JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    if (!handle) return;
    // Tear down the EGL context (if GL handle) BEFORE we release the
    // ANativeWindow it borrows from — the destructor calls
    // eglDestroySurface against that window.
    {
        std::lock_guard<std::mutex> lk(g_windowsMutex);
        g_glContexts.erase(handle);
    }
    // Release any cached ANativeWindow for this handle before destroying the
    // thorvg side. After this point no more nativeRenderFrame calls can
    // succeed for this handle.
    {
        std::lock_guard<std::mutex> lk(g_windowsMutex);
        if (auto* w = lookupWindowLocked(handle)) {
            ANativeWindow_release(w);
            g_windows.erase(handle);
        }
    }
    std::lock_guard<std::mutex> lk(engineInitMutex());
    destroy(reinterpret_cast<FlutterLottieAnimation*>(handle));
}

JNIEXPORT jboolean JNICALL
Java_com_robotoss_thorvg_1plus_ThorvgTexture_nativeAttachSurface(
        JNIEnv* env, jobject /*thiz*/, jlong handle, jobject jsurface) {
    if (!handle || !jsurface) return JNI_FALSE;
    ANativeWindow* window = ANativeWindow_fromSurface(env, jsurface);
    if (!window) {
        LOGE("ANativeWindow_fromSurface failed in attach");
        return JNI_FALSE;
    }
    std::lock_guard<std::mutex> lk(g_windowsMutex);
    // Defensive: replace any stale cached window. In normal use each handle
    // attaches exactly once, but a swap should still keep refcounts honest.
    if (auto* prev = lookupWindowLocked(handle)) {
        ANativeWindow_release(prev);
    }
    g_windows[handle] = window;

    // GL handles also need the EGL context bound to the freshly-attached
    // ANativeWindow. Skip silently for SW handles (g_glContexts entry
    // missing means SW mode).
    if (isGlHandleLocked(handle)) {
        // Drop any stale context tied to a previous (now-released) window.
        g_glContexts[handle].reset();
        auto ctx = thorvg_plus::EglRenderContext::create(window);
        if (!ctx) {
            LOGE("EglRenderContext::create failed; falling back to SW would "
                 "require remaking the TvgLottieAnimation. Aborting attach.");
            return JNI_FALSE;
        }
        // Make current so the very next set_gl_context (and any later
        // load/resize that calls GlCanvas::target) executes against a live
        // GL context. set_gl_context is a no-op against zero size, so it
        // just stashes the handles for the resize() inside the imminent
        // nativeLoad call.
        if (!ctx->makeCurrent()) {
            LOGE("eglMakeCurrent failed right after EGL context creation");
            return JNI_FALSE;
        }
        set_gl_context(reinterpret_cast<FlutterLottieAnimation*>(handle),
                       ctx->display(), ctx->surface(), ctx->context());
        g_glContexts[handle] = std::move(ctx);
    }
    return JNI_TRUE;
}

JNIEXPORT void JNICALL
Java_com_robotoss_thorvg_1plus_ThorvgTexture_nativeDetachSurface(
        JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    if (!handle) return;
    std::lock_guard<std::mutex> lk(g_windowsMutex);
    // Tear down the GL surface BEFORE releasing the ANativeWindow it
    // owns; the EglRenderContext destructor calls eglDestroySurface,
    // which requires the window pointer to still be valid.
    if (isGlHandleLocked(handle)) {
        g_glContexts[handle].reset();
        // Keep the placeholder entry so we still recognize the handle
        // as GL on the next attach (which will rebuild the context).
    }
    if (auto* w = lookupWindowLocked(handle)) {
        ANativeWindow_release(w);
        g_windows.erase(handle);
    }
}

JNIEXPORT jboolean JNICALL
Java_com_robotoss_thorvg_1plus_ThorvgTexture_nativeLoad(
        JNIEnv* env, jobject /*thiz*/,
        jlong handle, jbyteArray jdata, jint w, jint h) {
    if (!handle || !jdata) return JNI_FALSE;
    auto* anim = reinterpret_cast<FlutterLottieAnimation*>(handle);

    const jsize len = env->GetArrayLength(jdata);
    char* data = static_cast<char*>(std::malloc(static_cast<size_t>(len) + 1));
    if (!data) return JNI_FALSE;
    env->GetByteArrayRegion(jdata, 0, len, reinterpret_cast<jbyte*>(data));
    data[len] = '\0';  // thorvg's load() uses strlen() on the data pointer

    // GL: load() internally calls resize() which calls GlCanvas::target;
    // that touches GL state, so the EGL context must be current right
    // now. SW path is untouched.
    {
        std::lock_guard<std::mutex> lk(g_windowsMutex);
        if (auto* gl = lookupGlContextLocked(handle)) {
            if (!gl->makeCurrent()) {
                LOGE("eglMakeCurrent failed in nativeLoad");
                std::free(data);
                return JNI_FALSE;
            }
        }
    }

    char mime[] = "json";
    const bool ok = load(anim, data, mime, w, h);
    std::free(data);
    return ok ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jfloat JNICALL
Java_com_robotoss_thorvg_1plus_ThorvgTexture_nativeDuration(
        JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    if (!handle) return 0.0f;
    return duration(reinterpret_cast<FlutterLottieAnimation*>(handle));
}

JNIEXPORT jfloat JNICALL
Java_com_robotoss_thorvg_1plus_ThorvgTexture_nativeTotalFrame(
        JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    if (!handle) return 0.0f;
    return totalFrame(reinterpret_cast<FlutterLottieAnimation*>(handle));
}

JNIEXPORT void JNICALL
Java_com_robotoss_thorvg_1plus_ThorvgTexture_nativeSize(
        JNIEnv* env, jobject /*thiz*/, jlong handle, jfloatArray out) {
    if (!handle || !out) return;
    float* sz = size(reinterpret_cast<FlutterLottieAnimation*>(handle));
    if (!sz) return;
    env->SetFloatArrayRegion(out, 0, 2, sz);
}

JNIEXPORT void JNICALL
Java_com_robotoss_thorvg_1plus_ThorvgTexture_nativeResize(
        JNIEnv* /*env*/, jobject /*thiz*/, jlong handle, jint w, jint h) {
    if (!handle) return;
    // GL: resize -> GlCanvas::target needs the EGL context current.
    {
        std::lock_guard<std::mutex> lk(g_windowsMutex);
        if (auto* gl = lookupGlContextLocked(handle)) {
            if (!gl->makeCurrent()) {
                LOGE("eglMakeCurrent failed in nativeResize");
                return;
            }
        }
    }
    resize(reinterpret_cast<FlutterLottieAnimation*>(handle), w, h);
}

JNIEXPORT jboolean JNICALL
Java_com_robotoss_thorvg_1plus_ThorvgTexture_nativeFrame(
        JNIEnv* /*env*/, jobject /*thiz*/, jlong handle, jfloat no) {
    if (!handle) return JNI_FALSE;
    return frame(reinterpret_cast<FlutterLottieAnimation*>(handle), no)
               ? JNI_TRUE
               : JNI_FALSE;
}

JNIEXPORT jstring JNICALL
Java_com_robotoss_thorvg_1plus_ThorvgTexture_nativeError(
        JNIEnv* env, jobject /*thiz*/, jlong handle) {
    if (!handle) return env->NewStringUTF("invalid handle");
    const char* err = error(reinterpret_cast<FlutterLottieAnimation*>(handle));
    return env->NewStringUTF(err ? err : "");
}

JNIEXPORT jboolean JNICALL
Java_com_robotoss_thorvg_1plus_ThorvgTexture_nativeRenderFrame(
        JNIEnv* /*env*/, jobject /*thiz*/,
        jlong handle, jfloat frameNo, jint w, jint h) {
    if (!handle) return JNI_FALSE;
    auto* anim = reinterpret_cast<FlutterLottieAnimation*>(handle);

    // Pull the cached ANativeWindow + (optionally) the EGL context.
    // Single mutex acquisition to keep the lookup atomic against an
    // attach/detach interleaved by another thread.
    ANativeWindow* window;
    thorvg_plus::EglRenderContext* gl;
    {
        std::lock_guard<std::mutex> lk(g_windowsMutex);
        window = lookupWindowLocked(handle);
        gl = lookupGlContextLocked(handle);
    }
    if (!window) {
        LOGE("nativeRenderFrame called with no attached surface");
        return JNI_FALSE;
    }

    if (gl) {
        // GL path: thorvg writes straight into FBO 0 (the EGL window
        // surface, which sits on top of SurfaceProducer's ImageReader);
        // eglSwapBuffers hands the buffer to Flutter's raster thread.
        // No CPU memcpy, no ANativeWindow_lock.
        if (!gl->makeCurrent()) {
            LOGE("eglMakeCurrent failed in nativeRenderFrame (GL)");
            return JNI_FALSE;
        }
        frame(anim, frameNo);
        if (!update(anim)) {
            LOGE("update() failed (GL): %s", error(anim));
            return JNI_FALSE;
        }
        // render() returns nullptr in GL mode; the FBO is the output.
        // We still call it to drive draw + sync inside thorvg.
        (void)render(anim);
        if (!gl->swapBuffers()) {
            LOGE("eglSwapBuffers failed");
            return JNI_FALSE;
        }
        return JNI_TRUE;
    }

    // SW path (unchanged from pre-sprint-6).
    frame(anim, frameNo);
    if (!update(anim)) {
        LOGE("update() failed: %s", error(anim));
        return JNI_FALSE;
    }
    uint8_t* pixels = render(anim);
    if (!pixels) {
        LOGE("render() returned null: %s", error(anim));
        return JNI_FALSE;
    }

    // No-op when geometry is unchanged, so cheap to call per frame.
    if (ANativeWindow_setBuffersGeometry(window, w, h,
                                         WINDOW_FORMAT_RGBA_8888) != 0) {
        LOGE("setBuffersGeometry(%d,%d) failed", w, h);
        return JNI_FALSE;
    }

    ANativeWindow_Buffer buf;
    if (ANativeWindow_lock(window, &buf, nullptr) < 0) {
        LOGE("ANativeWindow_lock failed");
        return JNI_FALSE;
    }

    // thorvg writes ColorSpace::ABGR8888S, which on little-endian Android maps
    // to a (R,G,B,A) byte order in memory — identical to ANativeWindow's
    // WINDOW_FORMAT_RGBA_8888. No swizzle required.
    //
    // buf.stride is in pixels and may be padded by the driver; copy row by row.
    const int copyRows = (h < buf.height) ? h : buf.height;
    const int copyCols = (w < buf.width) ? w : buf.width;
    const size_t srcStride = static_cast<size_t>(w) * 4;
    const size_t dstStride = static_cast<size_t>(buf.stride) * 4;
    const size_t copyBytes = static_cast<size_t>(copyCols) * 4;
    auto* dst = static_cast<uint8_t*>(buf.bits);
    for (int y = 0; y < copyRows; ++y) {
        std::memcpy(dst + y * dstStride, pixels + y * srcStride, copyBytes);
    }

    ANativeWindow_unlockAndPost(window);
    return JNI_TRUE;
}

}  // extern "C"
