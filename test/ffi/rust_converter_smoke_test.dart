// FFI smoke test — exercises the phase-1 stub Rust core end-to-end:
// load dylib → call convert → decode envelope. Skips cleanly when the
// cargo artifact hasn't been built.

import 'dart:ffi';
import 'dart:io';

import 'package:anim_svg/src/data/ffi/rust_convert_envelope.dart';
import 'package:anim_svg/src/data/ffi/rust_converter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final libPath = _findLocalDylib();

  if (libPath == null) {
    test('native dylib not built (run `cargo build` in native/anim_svg_core)',
        () {
      // Print a friendly hint but don't fail; CI will build first.
      // ignore: avoid_print
      print('[skip] libanim_svg_core dylib not found under target/debug');
    }, skip: 'native crate not built');
    return;
  }

  late RustConverter converter;

  setUpAll(() {
    converter = RustConverter.fromLibrary(DynamicLibrary.open(libPath));
  });

  test('reports non-empty native version', () {
    expect(converter.nativeVersion, isNotEmpty);
  });

  test('returns envelope with phase-1 stub error for arbitrary svg', () {
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"/>';
    final env = converter.convertToEnvelope(svg);
    expect(env.error, isNotNull,
        reason: 'phase 1 stub always reports unsupported_feature');
    expect(env.error!.kind, RustErrorKind.unsupportedFeature);
    expect(env.logs, isNotEmpty);
    expect(env.lottieJson, 'null');
  });

  test('handles non-UTF-8 pathological input gracefully', () {
    // Dart strings are always valid Unicode; this just exercises the path
    // with long input to make sure large allocs don't misbehave.
    final svg = '<svg>${'x' * 10000}</svg>';
    final env = converter.convertToEnvelope(svg);
    expect(env, isNotNull);
    expect(env.logs, isNotEmpty);
  });
}

String? _findLocalDylib() {
  final ext = Platform.isMacOS
      ? 'dylib'
      : Platform.isLinux
          ? 'so'
          : Platform.isWindows
              ? 'dll'
              : null;
  if (ext == null) return null;

  final candidates = <String>[
    'native/anim_svg_core/target/debug/libanim_svg_core.$ext',
    'native/anim_svg_core/target/release/libanim_svg_core.$ext',
  ];
  for (final rel in candidates) {
    final f = File(rel);
    if (f.existsSync()) return f.absolute.path;
  }
  return null;
}
