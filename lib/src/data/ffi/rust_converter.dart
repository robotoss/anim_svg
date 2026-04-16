import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

import 'anim_svg_core_bindings.dart';
import 'rust_convert_envelope.dart';

/// Dart-side wrapper around the native `anim_svg_core` library.
///
/// Each `convertToEnvelope` call:
///   1. Encodes the SVG as UTF-8 into native memory,
///   2. Calls `anim_svg_convert`,
///   3. Copies the returned C-string into a Dart String,
///   4. Immediately calls `anim_svg_free_string`,
///   5. Parses the JSON envelope into typed Dart objects.
///
/// The bindings are resolved once at construction; call overhead is a
/// single FFI indirect plus one UTF-8 alloc and one JSON parse.
class RustConverter {
  RustConverter._(this._bindings);

  /// Default instance that loads the shared library using platform
  /// conventions. iOS/macOS: symbols are statically linked into the host
  /// process (xcframework), so `DynamicLibrary.process()`. Android: load
  /// `libanim_svg_core.so`.
  factory RustConverter.instance() {
    _singleton ??= RustConverter._(AnimSvgCoreBindings(_loadLibrary()));
    return _singleton!;
  }

  /// Inject a pre-loaded library, for tests or non-default deployments.
  factory RustConverter.fromLibrary(DynamicLibrary lib) =>
      RustConverter._(AnimSvgCoreBindings(lib));

  static RustConverter? _singleton;

  final AnimSvgCoreBindings _bindings;

  /// Version reported by the native core (Cargo.toml `version`).
  String get nativeVersion {
    final ptr = _bindings.coreVersion();
    return ptr.toDartString();
  }

  /// Run conversion. Never throws for a parse/conversion error — those
  /// live inside `envelope.error`. Does throw on contract violations
  /// (null pointer return from a valid call).
  RustConvertEnvelope convertToEnvelope(String svgXml, {String? logLevel}) {
    final svgPtr = svgXml.toNativeUtf8();
    final optsPtr = calloc<AnimSvgConvertOptions>();
    final logLevelPtr =
        logLevel == null ? nullptr.cast<Utf8>() : logLevel.toNativeUtf8();

    try {
      optsPtr.ref.logLevel = logLevelPtr;
      optsPtr.ref.reserved = 0;

      final outPtr = _bindings.convert(svgPtr, optsPtr);
      if (outPtr == nullptr) {
        throw StateError(
            'anim_svg_convert returned null — allocation failure or invalid input');
      }

      final jsonString = outPtr.toDartString();
      _bindings.freeString(outPtr);

      return RustConvertEnvelope.parse(jsonString);
    } finally {
      malloc.free(svgPtr);
      if (logLevelPtr != nullptr) malloc.free(logLevelPtr);
      calloc.free(optsPtr);
    }
  }
}

DynamicLibrary _loadLibrary() {
  // iOS/macOS: the xcframework is statically linked; look up by symbol
  // in the host process.
  if (Platform.isIOS || Platform.isMacOS) {
    return DynamicLibrary.process();
  }
  // Android: packaged as a shared object under jniLibs.
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libanim_svg_core.so');
  }
  // Desktop (dev-only): look next to the executable or use a local build
  // output so `dart test` in the crate root can resolve it.
  if (Platform.isLinux) return DynamicLibrary.open('libanim_svg_core.so');
  if (Platform.isWindows) return DynamicLibrary.open('anim_svg_core.dll');
  throw UnsupportedError(
      'anim_svg_core: unsupported platform ${Platform.operatingSystem}');
}
