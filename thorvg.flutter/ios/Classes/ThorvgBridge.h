#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

// Obj-C bridge over the C++ TvgLottieAnimation API.
//
// Exists so Swift can drive the renderer without a custom modulemap or
// bridging-header gymnastics: ObjC class methods are visible to Swift via
// the auto-generated pod module, and ARGB swizzling lives here so the
// Swift caller can hand us a CVPixelBuffer base address directly.
@interface ThorvgBridge : NSObject

+ (intptr_t)create;

// GL counterpart of create — sprint 6. Allocates BOTH the C++
// TvgLottieAnimation around tvg::GlCanvas (see
// tvgFlutterLottieAnimation.cpp::create_gl) AND the per-instance
// AngleRenderContext that owns the EGLSurface cache. The Swift side
// stays oblivious to the EGL/ANGLE handles entirely; renderFrameGl:
// below is the only call needed per frame.
//
// Returns the animation handle (same shape as create); the matching
// AngleRenderContext is keyed off this handle in a private static
// map and torn down by destroy:.
+ (intptr_t)createGl;

// GL render path — composite per-frame call:
//   1. AngleRenderContext.bindPixelBuffer(pb) — looks up or lazily
//      builds an EGLSurface for the IOSurface backing pb.
//   2. AngleRenderContext.makeCurrent — binds the surface.
//   3. set_gl_context — re-targets the GlCanvas at FBO 0 of the
//      now-current surface. Cheap; thorvg just updates viewport state.
//   4. frame/update/render. render() returns nullptr in GL mode; we
//      ignore — the IOSurface IS the output.
//   5. AngleRenderContext.present — eglWaitGL flushes the GLES queue
//      and waits for the GPU to drain it, so the IOSurface is fully
//      written when Swift calls textureFrameAvailable.
+ (BOOL)renderFrameGl:(intptr_t)handle
              frameNo:(float)frameNo
        intoPixelBuffer:(CVPixelBufferRef)pixelBuffer;

+ (void)destroy:(intptr_t)handle;
+ (BOOL)load:(intptr_t)handle
        data:(NSData *)data
       width:(int)width
      height:(int)height;
+ (float)duration:(intptr_t)handle;
+ (float)totalFrame:(intptr_t)handle;
+ (NSArray<NSNumber *> *)size:(intptr_t)handle;
+ (void)resize:(intptr_t)handle
         width:(int)width
        height:(int)height;
+ (BOOL)frame:(intptr_t)handle no:(float)no;
+ (NSString *)errorMessage:(intptr_t)handle;

// Composite per-frame call:
//   1. set animation frame
//   2. update canvas
//   3. SwCanvas::draw + sync
//   4. swizzle ABGR8888 (thorvg) -> BGRA8888 (CVPixelBuffer 32BGRA) via
//      vImagePermuteChannels_ARGB8888 into the destination buffer
+ (BOOL)renderFrame:(intptr_t)handle
            frameNo:(float)frameNo
              width:(int)width
             height:(int)height
         intoBuffer:(void *)destination
           rowBytes:(size_t)rowBytes;

@end

NS_ASSUME_NONNULL_END
