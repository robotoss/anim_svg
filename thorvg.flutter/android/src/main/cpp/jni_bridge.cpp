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
#include <mutex>

#include "tvgFlutterLottieAnimation.h"

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

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_robotoss_thorvg_1plus_ThorvgTexture_nativeCreate(
        JNIEnv* /*env*/, jobject /*thiz*/) {
    std::lock_guard<std::mutex> lk(engineInitMutex());
    return reinterpret_cast<jlong>(create());
}

JNIEXPORT void JNICALL
Java_com_robotoss_thorvg_1plus_ThorvgTexture_nativeDestroy(
        JNIEnv* /*env*/, jobject /*thiz*/, jlong handle) {
    if (!handle) return;
    std::lock_guard<std::mutex> lk(engineInitMutex());
    destroy(reinterpret_cast<FlutterLottieAnimation*>(handle));
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
Java_com_robotoss_thorvg_1plus_ThorvgTexture_nativeRenderToSurface(
        JNIEnv* env, jobject /*thiz*/,
        jlong handle, jfloat frameNo, jint w, jint h, jobject jsurface) {
    if (!handle || !jsurface) return JNI_FALSE;
    auto* anim = reinterpret_cast<FlutterLottieAnimation*>(handle);

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

    ANativeWindow* window = ANativeWindow_fromSurface(env, jsurface);
    if (!window) {
        LOGE("ANativeWindow_fromSurface failed");
        return JNI_FALSE;
    }

    // No-op when geometry is unchanged, so cheap to call per frame.
    if (ANativeWindow_setBuffersGeometry(window, w, h,
                                         WINDOW_FORMAT_RGBA_8888) != 0) {
        LOGE("setBuffersGeometry(%d,%d) failed", w, h);
        ANativeWindow_release(window);
        return JNI_FALSE;
    }

    ANativeWindow_Buffer buf;
    if (ANativeWindow_lock(window, &buf, nullptr) < 0) {
        LOGE("ANativeWindow_lock failed");
        ANativeWindow_release(window);
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
    ANativeWindow_release(window);
    return JNI_TRUE;
}

}  // extern "C"
