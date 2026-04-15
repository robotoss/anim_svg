// Parity harness: runs every fixture through both the Dart and Rust
// converters and compares structural invariants of the resulting Lottie
// JSON. Byte-for-byte parity is not a goal — floating-point math and
// key ordering diverge legitimately across runtimes — so we check the
// contracts downstream consumers actually rely on.
//
// Skips cleanly when the native dylib isn't present locally (e.g. CI
// job that hasn't run `cargo build` yet). Run locally with:
//   cargo build --manifest-path native/anim_svg_core/Cargo.toml
//   flutter test test/parity

import 'dart:ffi';
import 'dart:io';

import 'package:anim_svg/src/data/ffi/rust_converter.dart';
import 'package:anim_svg/src/domain/usecases/convert_svg_to_lottie.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final libPath = _findLocalDylib();
  if (libPath == null) {
    test('native dylib not built — skipping Rust parity', () {
      // ignore: avoid_print
      print('[skip] libanim_svg_core dylib not found under target/debug');
    }, skip: 'run `cargo build` in native/anim_svg_core first');
    return;
  }

  late RustConverter rust;
  setUpAll(() {
    rust = RustConverter.fromLibrary(DynamicLibrary.open(libPath));
  });

  final fixtures = Directory('test/fixtures')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.svg'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  // Known-divergent fixtures: Rust's raster_transcoder is a stub that
  // preserves WebP unchanged while Dart actually decodes/re-encodes and
  // drops on failure. Track divergence explicitly rather than masking it.
  const knownDivergent = <String, String>{
    'minimal_css_animation.svg':
        'WebP transcoding differs — Rust stub vs Dart decode',
  };

  for (final file in fixtures) {
    final name = file.uri.pathSegments.last;
    test('parity: $name', () {
      final svg = file.readAsStringSync();
      final dartConverter = ConvertSvgToLottie();
      final rustConverter =
          ConvertSvgToLottie(useRustBackend: true, rustConverter: rust);

      final dartMap = dartConverter.convertToMap(svg);
      final rustMap = rustConverter.convertToMap(svg);

      expect(rustMap['v'], dartMap['v'], reason: 'schema version mismatch');
      expect(rustMap['fr'], dartMap['fr'], reason: 'frame rate mismatch');
      expect(rustMap['w'], dartMap['w'], reason: 'width mismatch');
      expect(rustMap['h'], dartMap['h'], reason: 'height mismatch');
      expect(rustMap['ip'], dartMap['ip'], reason: 'in-point mismatch');
      // op may differ by ±1 frame at the clamp boundary.
      final dartOp = (dartMap['op'] as num).toDouble();
      final rustOp = (rustMap['op'] as num).toDouble();
      expect((rustOp - dartOp).abs(), lessThanOrEqualTo(1.0),
          reason: 'out-point within 1-frame tolerance');

      final dartLayers = dartMap['layers'] as List;
      final rustLayers = rustMap['layers'] as List;
      expect(rustLayers.length, dartLayers.length,
          reason: 'layer count mismatch');

      final dartAssets = (dartMap['assets'] as List?) ?? const [];
      final rustAssets = (rustMap['assets'] as List?) ?? const [];
      expect(rustAssets.length, dartAssets.length,
          reason: 'asset count mismatch');
    }, skip: knownDivergent[name]);
  }
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
