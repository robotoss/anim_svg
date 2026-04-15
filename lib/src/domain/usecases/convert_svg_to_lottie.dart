import 'dart:convert';

import '../../core/logger.dart';
import '../../data/mappers/svg_to_lottie_mapper.dart';
import '../../data/parsers/svg_parser.dart';
import '../../data/serializers/lottie_serializer.dart';
import '../entities/lottie_animation.dart';

/// Façade use-case: pure-Dart SVG (string) → Lottie (Map/JSON).
///
/// Each stage is timed and logged through [AnimSvgLogger]. Pass a custom
/// logger to trace the pipeline end-to-end; default is [SilentLogger].
class ConvertSvgToLottie {
  ConvertSvgToLottie({
    SvgParser? parser,
    SvgToLottieMapper? mapper,
    LottieSerializer? serializer,
    AnimSvgLogger? logger,
  })  : _log = logger ?? SilentLogger(),
        _parser = parser ?? SvgParser(logger: logger),
        _mapper = mapper ?? SvgToLottieMapper(logger: logger),
        _serializer = serializer ?? const LottieSerializer();

  final SvgParser _parser;
  final SvgToLottieMapper _mapper;
  final LottieSerializer _serializer;
  final AnimSvgLogger _log;

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
    final doc = convert(svgXml);
    return _log.time('convert.serialize', () => _serializer.toMap(doc));
  }

  String convertToJson(String svgXml) {
    final map = convertToMap(svgXml);
    final encoded = _log.time('convert.encode', () => json.encode(map));
    _log.debug('convert.encode', 'json ready',
        fields: {'json_bytes': encoded.length});
    return encoded;
  }
}
