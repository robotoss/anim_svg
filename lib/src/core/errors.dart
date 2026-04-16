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

class NetworkSvgException implements Exception {
  NetworkSvgException(this.url, {this.statusCode, this.reason});

  final String url;
  final int? statusCode;
  final String? reason;

  @override
  String toString() {
    final parts = <String>['NetworkSvgException: $url'];
    if (statusCode != null) parts.add('status=$statusCode');
    if (reason != null) parts.add(reason!);
    return parts.join(' — ');
  }
}
