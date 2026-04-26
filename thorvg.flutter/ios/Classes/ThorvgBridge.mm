#import "ThorvgBridge.h"
#import <Accelerate/Accelerate.h>

#include <cstdlib>
#include <cstring>

#include "tvgFlutterLottieAnimation.h"

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

+ (void)destroy:(intptr_t)handle {
    if (!handle) return;
    dispatch_sync(ThorvgEngineSerialQueue(), ^{
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
