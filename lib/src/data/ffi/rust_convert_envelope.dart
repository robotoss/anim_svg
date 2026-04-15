import 'dart:convert';

import 'package:meta/meta.dart';

import '../../core/logger.dart';

/// Kinds of error the native core can report. Kept in sync with
/// `ErrorKind` in native/anim_svg_core/src/error.rs.
enum RustErrorKind { parse, unsupportedFeature, conversion, unknown }

/// Structured error returned in the native envelope.
@immutable
class RustConvertError {
  const RustConvertError({
    required this.kind,
    required this.message,
    this.source,
    this.feature,
    this.reason,
  });

  factory RustConvertError.fromJson(Map<String, Object?> json) {
    return RustConvertError(
      kind: _parseKind(json['kind'] as String?),
      message: (json['message'] as String?) ?? '',
      source: json['source'] as String?,
      feature: json['feature'] as String?,
      reason: json['reason'] as String?,
    );
  }

  final RustErrorKind kind;
  final String message;
  final String? source;
  final String? feature;
  final String? reason;

  static RustErrorKind _parseKind(String? raw) {
    switch (raw) {
      case 'parse':
        return RustErrorKind.parse;
      case 'unsupported_feature':
        return RustErrorKind.unsupportedFeature;
      case 'conversion':
        return RustErrorKind.conversion;
      default:
        return RustErrorKind.unknown;
    }
  }

  @override
  String toString() =>
      'RustConvertError(kind: $kind, message: $message, feature: $feature)';
}

/// Typed view over the `{lottie, svg_raw, logs, error}` JSON the native
/// core returns. Holds the parsed Lottie and SvgDocument as dynamic trees
/// and the original JSON string for `convertToJson` callers that want
/// zero re-encoding overhead.
@immutable
class RustConvertEnvelope {
  const RustConvertEnvelope({
    required this.lottieJson,
    required this.lottie,
    required this.svgRaw,
    required this.logs,
    required this.error,
  });

  factory RustConvertEnvelope.parse(String envelopeJson) {
    final decoded = json.decode(envelopeJson);
    if (decoded is! Map<String, Object?>) {
      throw FormatException(
          'native envelope must be a JSON object, got ${decoded.runtimeType}');
    }

    final lottie = decoded['lottie'];
    final svgRaw = decoded['svg_raw'];
    final rawLogs = decoded['logs'];
    final rawError = decoded['error'];

    final logs = <RustLogEntry>[];
    if (rawLogs is List) {
      for (final entry in rawLogs) {
        if (entry is Map<String, Object?>) {
          logs.add(RustLogEntry.fromJson(entry));
        }
      }
    }

    RustConvertError? err;
    if (rawError is Map<String, Object?>) {
      err = RustConvertError.fromJson(rawError);
    }

    // Re-encode lottie sub-tree once so callers wanting `convertToJson`
    // don't pay to re-stringify the whole envelope. Cheap: serde already
    // built the string, we just slice it out conceptually.
    final lottieString = lottie == null ? 'null' : json.encode(lottie);

    return RustConvertEnvelope(
      lottieJson: lottieString,
      lottie: lottie,
      svgRaw: svgRaw,
      logs: List.unmodifiable(logs),
      error: err,
    );
  }

  /// JSON-encoded Lottie sub-tree. Empty string never; `'null'` if the
  /// pipeline failed before producing Lottie.
  final String lottieJson;

  /// Decoded Lottie (typically `Map<String, dynamic>`) or null on failure.
  final Object? lottie;

  /// Decoded SvgDocument (typically `Map<String, dynamic>`) or null.
  final Object? svgRaw;

  /// Log entries captured during conversion, in order.
  final List<RustLogEntry> logs;

  /// Populated iff the native call reported an error.
  final RustConvertError? error;

  bool get hasError => error != null;

  /// Replay every log entry onto the supplied logger using the same
  /// level/stage/message/fields the native side emitted. Handy so
  /// existing `AnimSvgLogger` consumers see Rust logs transparently.
  void replayTo(AnimSvgLogger logger) {
    for (final entry in logs) {
      entry.replayTo(logger);
    }
  }
}

/// One log entry returned from the native core.
@immutable
class RustLogEntry {
  const RustLogEntry({
    required this.level,
    required this.stage,
    required this.message,
    required this.fields,
  });

  factory RustLogEntry.fromJson(Map<String, Object?> json) {
    final rawFields = json['fields'];
    final fields = <String, Object?>{};
    if (rawFields is Map<String, Object?>) {
      fields.addAll(rawFields);
    }
    return RustLogEntry(
      level: _parseLevel(json['level'] as String?),
      stage: (json['stage'] as String?) ?? '',
      message: (json['message'] as String?) ?? '',
      fields: Map.unmodifiable(fields),
    );
  }

  final AnimSvgLogLevel level;
  final String stage;
  final String message;
  final Map<String, Object?> fields;

  void replayTo(AnimSvgLogger logger) {
    logger.log(level, stage, message, fields: fields);
  }

  static AnimSvgLogLevel _parseLevel(String? raw) {
    switch (raw) {
      case 'trace':
        return AnimSvgLogLevel.trace;
      case 'debug':
        return AnimSvgLogLevel.debug;
      case 'info':
        return AnimSvgLogLevel.info;
      case 'warn':
      case 'warning':
        return AnimSvgLogLevel.warn;
      case 'error':
        return AnimSvgLogLevel.error;
      default:
        return AnimSvgLogLevel.info;
    }
  }
}
