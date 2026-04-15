#import <Foundation/Foundation.h>
#import "anim_svg_core.h"

// Prevent the iOS linker from omitting FFI symbols exported by the
// vendored anim_svg_core.xcframework static library. Dart resolves
// these via DynamicLibrary.process(); each symbol must be referenced
// at link time to survive into the final app binary. Pattern mirrors
// thorvg.flutter/ios/Classes/ThorvgFFIKeep.m.
@interface AnimSvgFFIKeep : NSObject
@end

@implementation AnimSvgFFIKeep
+ (void)load
{
    static void* const keep[] = {
        (void*)&anim_svg_convert,
        (void*)&anim_svg_free_string,
        (void*)&anim_svg_core_version,
    };
    (void)keep;
}
@end
