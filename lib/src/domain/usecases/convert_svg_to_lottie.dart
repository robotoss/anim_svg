import 'dart:convert';

import '../../core/errors.dart';
import '../../core/logger.dart';
import '../../data/ffi/rust_convert_envelope.dart';
import '../../data/ffi/rust_converter.dart';
import '../../data/mappers/svg_to_lottie_mapper.dart';
import '../../data/parsers/svg_parser.dart';
import '../../data/serializers/lottie_serializer.dart';
import '../entities/lottie_animation.dart';

/// Façade use-case: SVG (string) → Lottie (Map/JSON).
///
/// By default runs the pure-Dart pipeline. Pass `useRustBackend: true`
/// to delegate to the native `anim_svg_core` library; the native path
/// returns a richer envelope (lottie + raw SVG + logs + structured
/// error) so nothing produced by the pipeline is dropped silently.
class ConvertSvgToLottie {
  ConvertSvgToLottie({
    SvgParser? parser,
    SvgToLottieMapper? mapper,
    LottieSerializer? serializer,
    AnimSvgLogger? logger,
    this.useRustBackend = true,
    RustConverter? rustConverter,
  })  : _log = logger ?? SilentLogger(),
        _parser = parser ?? SvgParser(logger: logger),
        _mapper = mapper ?? SvgToLottieMapper(logger: logger),
        _serializer = serializer ?? const LottieSerializer(),
        _rust = rustConverter;

  final SvgParser _parser;
  final SvgToLottieMapper _mapper;
  final LottieSerializer _serializer;
  final AnimSvgLogger _log;
  final bool useRustBackend;
  final RustConverter? _rust;

  LottieDoc convert(String svgXml) {
    _log.info('convert', 'start', fields: {'svg_bytes': svgXml.length});
    final doc = _log.time('convert.parse', () => _parser.parse(svgXml));
    _log.debug('convert.parse', 'svg parsed', fields: {
      'viewBox': '${doc.viewBox.w}x${doc.viewBox.h}',
      'defs_count': doc.defs.byId.length,
      'root_children': doc.root.children.length,
    });
    final lottie = _log.time('convert.map', () => _mapper.map(doc));
    _log.info('convert', 'done', fields: {
      'layers': lottie.layers.length,
      'assets': lottie.assets.length,
      'op_frames': lottie.outPoint,
      'fr': lottie.frameRate,
    });
    return lottie;
  }

  Map<String, dynamic> convertToMap(String svgXml) {
    if (useRustBackend) {
      final envelope = _rustConvert(svgXml);
      final lottie = envelope.lottie;
      if (lottie is! Map<String, dynamic>) {
        throw ConversionException('native core returned non-object lottie');
      }
      return lottie;
    }
    final doc = convert(svgXml);
    return _log.time('convert.serialize', () => _serializer.toMap(doc));
  }

  String convertToJson(String svgXml) {
    if (useRustBackend) {
      final envelope = _rustConvert(svgXml);
      return envelope.lottieJson;
    }
    final map = convertToMap(svgXml);
    final encoded = _log.time('convert.encode', () => json.encode(map));
    _log.debug('convert.encode', 'json ready',
        fields: {'json_bytes': encoded.length});
    return encoded;
  }

  /// Rich conversion: returns the full envelope (lottie + raw SVG +
  /// logs + error) produced by the native core. Falls back to running
  /// the Dart pipeline and wrapping its output when `useRustBackend`
  /// is `false`, so callers get a uniform shape either way.
  RustConvertEnvelope convertToEnvelope(String svgXml) {
    if (useRustBackend) {
      return _rustConvert(svgXml);
    }
    final doc = _parser.parse(svgXml);
    final lottieDoc = _mapper.map(doc);
    final lottieMap = _serializer.toMap(lottieDoc);
    final lottieString = json.encode(lottieMap);
    return RustConvertEnvelope(
      lottieJson: lottieString,
      lottie: lottieMap,
      svgRaw: null,
      logs: const [],
      error: null,
    );
  }

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
