// Keep-alive shim for Dart FFI on iOS.
//
// Dart FFI resolves native symbols via DynamicLibrary.process(), but the
// iOS linker aggressively dead-strips unreferenced static library code.
// Force a live reference to one symbol from the Rust core so the entire
// compilation unit graph survives.
//
// This file intentionally does nothing at runtime beyond printing a
// version string into a throwaway sink.

#include <stdio.h>

extern const char* anim_svg_core_version(void);

__attribute__((used))
const char* anim_svg_core_keep_alive(void) {
    return anim_svg_core_version();
}
