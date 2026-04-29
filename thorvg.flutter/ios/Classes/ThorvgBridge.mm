#import "ThorvgBridge.h"
#import "AngleRenderContext.h"
#import <Accelerate/Accelerate.h>

#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <unordered_map>

#include "tvgFlutterLottieAnimation.h"

// Per-handle AngleRenderContext registry. Presence of a handle in this
// map is the authoritative "this is a GL animation" check — destroy:
// uses it to tear down the EGL bits before delete'ing the C++ side.
//
// All access is serialized through ThorvgEngineSerialQueue (on the
// create / destroy edges) and through the plugin's render queue (on
// the per-frame path), so a single std::mutex guarding the map itself
// is enough to keep the unordered_map safe under concurrent insert
// from create vs lookup from renderFrameGl.
static std::mutex& angleMapMutex() {
    static std::mutex m;
    return m;
}
static std::unordered_map<intptr_t,
                          std::unique_ptr<thorvg_plus::AngleRenderContext>>&
angleMap() {
    static std::unordered_map<intptr_t,
                              std::unique_ptr<thorvg_plus::AngleRenderContext>>
        m;
    return m;
}

// Serializes the global thorvg engine init/term reference counter that lives
// inside `TvgLottieAnimation`'s constructor / destructor. Without this, a
// burst of texture creations or disposals on different per-texture
// dispatch queues races on the non-atomic `engineInit++`/`--` counter inside
// thorvg's `Initializer`, which corrupts global state and crashes deep
// inside `canvas->update()`.
static dispatch_queue_t ThorvgEngineSerialQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create(
            "io.thorvg.engine_init", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

@implementation ThorvgBridge

+ (intptr_t)create {
    __block intptr_t h = 0;
    dispatch_sync(ThorvgEngineSerialQueue(), ^{
        h = (intptr_t)create();
    });
    return h;
}

+ (intptr_t)createGl {
    __block intptr_t h = 0;
    dispatch_sync(ThorvgEngineSerialQueue(), ^{
        // Allocate the EGL/ANGLE bits FIRST. If ANGLE refuses to come up
        // (rare — wrong binary, broken Metal device) we never publish a
        // half-built handle.
        auto angleCtx = thorvg_plus::AngleRenderContext::create();
        if (!angleCtx) {
            NSLog(@"[ThorvgBridge] AngleRenderContext::create failed; "
                  @"GL handle not produced — Swift falls back to SW.");
            return;
        }
        FlutterLottieAnimation *anim = create_gl();
        if (!anim) return;
        h = (intptr_t)anim;
        std::lock_guard<std::mutex> lk(angleMapMutex());
        angleMap().emplace(h, std::move(angleCtx));
    });
    return h;
}

+ (BOOL)renderFrameGl:(intptr_t)handle
              frameNo:(float)frameNo
        intoPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!handle || !pixelBuffer) return NO;

    // Lookup the per-handle AngleRenderContext under the map mutex,
    // then drop the mutex before doing any GL work — the GL context
    // is process-shared and the render queue is serial, so no other
    // thread can touch the same handle while we hold the bare pointer.
    thorvg_plus::AngleRenderContext *gl = nullptr;
    {
        std::lock_guard<std::mutex> lk(angleMapMutex());
        auto it = angleMap().find(handle);
        if (it == angleMap().end()) return NO;
        gl = it->second.get();
    }
    if (!gl) return NO;

    if (!gl->bindPixelBuffer(pixelBuffer)) return NO;
    if (!gl->makeCurrent()) return NO;

    // Re-target the GlCanvas at FBO 0 of the now-current EGLSurface
    // (different CVPixelBuffer per frame from the pool means a
    // different EGLSurface). Cheap — thorvg internally updates the
    // viewport state, no shader recompilation.
    set_gl_context((FlutterLottieAnimation *)handle,
                   gl->display(), gl->currentSurface(), gl->context());

    FlutterLottieAnimation *anim = (FlutterLottieAnimation *)handle;
    frame(anim, frameNo);
    if (!update(anim)) return NO;
    // render() returns nullptr in GL mode; the IOSurface-backed pbuffer
    // bound via AngleRenderContext IS the output. We ignore the return
    // value but still call so thorvg performs draw + sync internally.
    (void)render(anim);

    if (!gl->present()) return NO;
    return YES;
}

+ (void)destroy:(intptr_t)handle {
    if (!handle) return;
    dispatch_sync(ThorvgEngineSerialQueue(), ^{
        // Tear down the EGL bits first (decrements the shared
        // EGLDisplay+EGLContext refcount; destroys per-handle
        // EGLSurfaces). For SW handles this is a no-op (entry absent).
        {
            std::lock_guard<std::mutex> lk(angleMapMutex());
            angleMap().erase(handle);
        }
        destroy((FlutterLottieAnimation *)handle);
    });
}

+ (BOOL)load:(intptr_t)handle
        data:(NSData *)data
       width:(int)width
      height:(int)height {
    if (!handle || data.length == 0) return NO;
    char *buf = (char *)std::malloc(data.length + 1);
    if (!buf) return NO;
    std::memcpy(buf, data.bytes, data.length);
    buf[data.length] = '\0';  // thorvg's load() uses strlen()
    char mime[] = "json";
    bool ok = load((FlutterLottieAnimation *)handle, buf, mime, width, height);
    std::free(buf);
    return ok ? YES : NO;
}

+ (float)duration:(intptr_t)handle {
    return handle ? duration((FlutterLottieAnimation *)handle) : 0.0f;
}

+ (float)totalFrame:(intptr_t)handle {
    return handle ? totalFrame((FlutterLottieAnimation *)handle) : 0.0f;
}

+ (NSArray<NSNumber *> *)size:(intptr_t)handle {
    if (!handle) return @[@0, @0];
    float *sz = size((FlutterLottieAnimation *)handle);
    if (!sz) return @[@0, @0];
    return @[@(sz[0]), @(sz[1])];
}

+ (void)resize:(intptr_t)handle width:(int)width height:(int)height {
    if (handle) resize((FlutterLottieAnimation *)handle, width, height);
}

+ (BOOL)frame:(intptr_t)handle no:(float)no {
    if (!handle) return NO;
    return frame((FlutterLottieAnimation *)handle, no) ? YES : NO;
}

+ (NSString *)errorMessage:(intptr_t)handle {
    if (!handle) return @"invalid handle";
    const char *err = error((FlutterLottieAnimation *)handle);
    return err ? [NSString stringWithUTF8String:err] : @"";
}

+ (BOOL)renderFrame:(intptr_t)handle
            frameNo:(float)frameNo
              width:(int)width
             height:(int)height
         intoBuffer:(void *)destination
           rowBytes:(size_t)rowBytes {
    if (!handle || !destination || width <= 0 || height <= 0) return NO;
    FlutterLottieAnimation *anim = (FlutterLottieAnimation *)handle;

    frame(anim, frameNo);
    if (!update(anim)) return NO;
    uint8_t *pixels = render(anim);
    if (!pixels) return NO;

    // thorvg writes ColorSpace::ABGR8888S — little-endian byte order R,G,B,A.
    // CVPixelBuffer kCVPixelFormatType_32BGRA byte order is B,G,R,A.
    // Swap channels 0 and 2 (R<->B); leave G and A. SIMD-accelerated via vImage.
    vImage_Buffer src = {
        .data     = pixels,
        .height   = (vImagePixelCount)height,
        .width    = (vImagePixelCount)width,
        .rowBytes = (size_t)width * 4,
    };
    vImage_Buffer dst = {
        .data     = destination,
        .height   = (vImagePixelCount)height,
        .width    = (vImagePixelCount)width,
        .rowBytes = rowBytes,
    };
    const uint8_t permute[4] = {2, 1, 0, 3};  // R<->B
    vImage_Error err = vImagePermuteChannels_ARGB8888(&src, &dst, permute, kvImageNoFlags);
    return err == kvImageNoError ? YES : NO;
}

@end
