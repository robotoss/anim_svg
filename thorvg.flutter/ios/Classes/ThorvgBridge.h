#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Obj-C bridge over the C++ TvgLottieAnimation API.
//
// Exists so Swift can drive the renderer without a custom modulemap or
// bridging-header gymnastics: ObjC class methods are visible to Swift via
// the auto-generated pod module, and ARGB swizzling lives here so the
// Swift caller can hand us a CVPixelBuffer base address directly.
@interface ThorvgBridge : NSObject

+ (intptr_t)create;
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
