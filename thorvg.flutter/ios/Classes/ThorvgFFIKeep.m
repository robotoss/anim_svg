#import <Foundation/Foundation.h>
#import "tvgFlutterLottieAnimation.h"

// Prevent linker dead-stripping of FFI-exported C symbols when the
// plugin is compiled as a static library and resolved via
// DynamicLibrary.process() on iOS.
@interface ThorvgFFIKeep : NSObject
@end

@implementation ThorvgFFIKeep
+ (void)load
{
    static void* const keep[] = {
        (void*)&create,
        (void*)&destroy,
        (void*)&error,
        (void*)&size,
        (void*)&duration,
        (void*)&totalFrame,
        (void*)&curFrame,
        (void*)&resize,
        (void*)&load,
        (void*)&render,
        (void*)&frame,
        (void*)&update,
    };
    (void)keep;
}
@end
