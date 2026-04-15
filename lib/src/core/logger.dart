import 'dart:developer' as developer;

/// Log severity. Maps to `dart:developer.log` levels.
enum AnimSvgLogLevel {
  trace(500),
  debug(700),
  info(800),
  warn(900),
  error(1000);

  const AnimSvgLogLevel(this.value);
  final int value;
}

/// Pluggable logger. Default is [DeveloperLogger] which prints to
/// `dart:developer` (visible in Flutter DevTools / IDE console with the
/// `anim_svg` tag).
abstract class AnimSvgLogger {
  void log(
    AnimSvgLogLevel level,
    String stage,
    String message, {
    Object? error,
    StackTrace? stack,
    Map<String, Object?> fields,
  });

  void trace(String stage, String message, {Map<String, Object?> fields = const {}}) =>
      log(AnimSvgLogLevel.trace, stage, message, fields: fields);

  void debug(String stage, String message, {Map<String, Object?> fields = const {}}) =>
      log(AnimSvgLogLevel.debug, stage, message, fields: fields);

  void info(String stage, String message, {Map<String, Object?> fields = const {}}) =>
      log(AnimSvgLogLevel.info, stage, message, fields: fields);

  void warn(String stage, String message, {Map<String, Object?> fields = const {}}) =>
      log(AnimSvgLogLevel.warn, stage, message, fields: fields);

  void error(
    String stage,
    String message, {
    Object? error,
    StackTrace? stack,
    Map<String, Object?> fields = const {},
  }) =>
      log(AnimSvgLogLevel.error, stage, message,
          error: error, stack: stack, fields: fields);

  /// Times a synchronous block and logs `stage.duration_ms`.
  T time<T>(String stage, T Function() body) {
    final sw = Stopwatch()..start();
    try {
      final r = body();
      sw.stop();
      debug(stage, 'done', fields: {'duration_ms': sw.elapsedMilliseconds});
      return r;
    } catch (e, s) {
      sw.stop();
      error(stage, 'threw ${e.runtimeType}',
          error: e, stack: s, fields: {'duration_ms': sw.elapsedMilliseconds});
      rethrow;
    }
  }
}

class SilentLogger extends AnimSvgLogger {
  @override
  void log(
    AnimSvgLogLevel level,
    String stage,
    String message, {
    Object? error,
    StackTrace? stack,
    Map<String, Object?> fields = const {},
  }) {}
}

/// Default production logger — pipes to `dart:developer.log`.
class DeveloperLogger extends AnimSvgLogger {
  DeveloperLogger({this.minLevel = AnimSvgLogLevel.debug});

  final AnimSvgLogLevel minLevel;

  @override
  void log(
    AnimSvgLogLevel level,
    String stage,
    String message, {
    Object? error,
    StackTrace? stack,
    Map<String, Object?> fields = const {},
  }) {
    if (level.value < minLevel.value) return;
    final suffix = fields.isEmpty
        ? ''
        : ' ${fields.entries.map((e) => '${e.key}=${e.value}').join(' ')}';
    developer.log(
      '[$stage] $message$suffix',
      name: 'anim_svg',
      level: level.value,
      error: error,
      stackTrace: stack,
    );
  }
}

/// Print-based logger — for tests and CLI.
class PrintLogger extends AnimSvgLogger {
  PrintLogger({this.minLevel = AnimSvgLogLevel.debug});

  final AnimSvgLogLevel minLevel;

  @override
  void log(
    AnimSvgLogLevel level,
    String stage,
    String message, {
    Object? error,
    StackTrace? stack,
    Map<String, Object?> fields = const {},
  }) {
    if (level.value < minLevel.value) return;
    final buf = StringBuffer('[anim_svg][${level.name}][$stage] $message');
    if (fields.isNotEmpty) {
      buf.write(' ');
      buf.writeAll(fields.entries.map((e) => '${e.key}=${e.value}'), ' ');
    }
    if (error != null) buf.write('\n  error: $error');
    if (stack != null) buf.write('\n$stack');
    // ignore: avoid_print
    print(buf);
  }
}
