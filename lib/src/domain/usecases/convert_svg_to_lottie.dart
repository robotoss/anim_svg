import '../../core/errors.dart';
import '../../core/logger.dart';
import '../../data/ffi/rust_convert_envelope.dart';
import '../../data/ffi/rust_converter.dart';

/// Façade use-case: SVG (string) → Lottie (JSON / Map / envelope).
///
/// Delegates every conversion to the native `anim_svg_core` Rust library
/// via FFI. The native path returns a rich envelope (lottie + raw SVG +
/// logs + structured error) so nothing produced by the pipeline is
/// dropped silently.
class ConvertSvgToLottie {
  ConvertSvgToLottie({
    AnimSvgLogger? logger,
    RustConverter? rustConverter,
  })  : _log = logger ?? SilentLogger(),
        _rust = rustConverter;

  final AnimSvgLogger _log;
  final RustConverter? _rust;

  Map<String, dynamic> convertToMap(String svgXml) {
    final envelope = _rustConvert(svgXml);
    final lottie = envelope.lottie;
    if (lottie is! Map<String, dynamic>) {
      throw ConversionException('native core returned non-object lottie');
    }
    return lottie;
  }

  String convertToJson(String svgXml) => _rustConvert(svgXml).lottieJson;

  /// Rich conversion: returns the full envelope (lottie + raw SVG +
  /// logs + error) produced by the native core.
  RustConvertEnvelope convertToEnvelope(String svgXml) => _rustConvert(svgXml);

  RustConvertEnvelope _rustConvert(String svgXml) {
    final rust = _rust ?? RustConverter.instance();
    final envelope = rust.convertToEnvelope(svgXml);
    envelope.replayTo(_log);
    final err = envelope.error;
    if (err != null) {
      switch (err.kind) {
        case RustErrorKind.parse:
          throw ParseException(err.message);
        case RustErrorKind.unsupportedFeature:
          throw UnsupportedFeatureException(
              err.feature ?? 'unknown', err.reason ?? err.message);
        case RustErrorKind.conversion:
          throw ConversionException(err.message);
        case RustErrorKind.unknown:
          throw ConversionException(err.message);
      }
    }
    return envelope;
  }
}
