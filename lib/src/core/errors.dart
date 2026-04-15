class ParseException implements Exception {
  ParseException(this.message, {this.source});

  final String message;
  final String? source;

  @override
  String toString() =>
      source == null ? 'ParseException: $message' : 'ParseException: $message (at $source)';
}

class UnsupportedFeatureException implements Exception {
  UnsupportedFeatureException(this.feature, this.reason);

  final String feature;
  final String reason;

  @override
  String toString() => 'UnsupportedFeatureException: <$feature> — $reason';
}

class ConversionException implements Exception {
  ConversionException(this.message);

  final String message;

  @override
  String toString() => 'ConversionException: $message';
}
