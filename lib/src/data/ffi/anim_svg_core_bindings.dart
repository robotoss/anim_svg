// Hand-written C ABI bindings for native/anim_svg_core. Mirror
// native/anim_svg_core/include/anim_svg_core.h exactly. Keep the surface
// tiny so drift between the header and this file is obvious.

import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Per-call options. Matches struct AnimSvgConvertOptions in the C header.
final class AnimSvgConvertOptions extends Struct {
  external Pointer<Utf8> logLevel;

  @Uint32()
  external int reserved;
}

typedef _AnimSvgConvertC = Pointer<Utf8> Function(
  Pointer<Utf8> svg,
  Pointer<AnimSvgConvertOptions> opts,
);
typedef AnimSvgConvertDart = Pointer<Utf8> Function(
  Pointer<Utf8> svg,
  Pointer<AnimSvgConvertOptions> opts,
);

typedef _AnimSvgFreeStringC = Void Function(Pointer<Utf8> s);
typedef AnimSvgFreeStringDart = void Function(Pointer<Utf8> s);

typedef _AnimSvgCoreVersionC = Pointer<Utf8> Function();
typedef AnimSvgCoreVersionDart = Pointer<Utf8> Function();

/// Thin wrapper over a loaded DynamicLibrary. Resolves symbols once on
/// construction so per-call overhead is a single indirect call.
class AnimSvgCoreBindings {
  AnimSvgCoreBindings(DynamicLibrary lib)
      : convert = lib
            .lookupFunction<_AnimSvgConvertC, AnimSvgConvertDart>('anim_svg_convert'),
        freeString = lib.lookupFunction<_AnimSvgFreeStringC, AnimSvgFreeStringDart>(
            'anim_svg_free_string'),
        coreVersion = lib.lookupFunction<_AnimSvgCoreVersionC, AnimSvgCoreVersionDart>(
            'anim_svg_core_version');

  final AnimSvgConvertDart convert;
  final AnimSvgFreeStringDart freeString;
  final AnimSvgCoreVersionDart coreVersion;
}
