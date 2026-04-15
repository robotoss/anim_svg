import 'dart:convert';
import 'dart:typed_data';

import '../../core/errors.dart';

class DataUri {
  const DataUri({
    required this.mime,
    required this.base64,
    required this.raw,
  });

  final String mime;
  final String base64;
  final String raw;

  Uint8List decode() => base64Decode(base64);

  String asDataUri() => raw;
}

class DataUriDecoder {
  const DataUriDecoder();

  DataUri parse(String href) {
    if (!href.startsWith('data:')) {
      throw ParseException('not a data URI: ${_preview(href)}');
    }
    final comma = href.indexOf(',');
    if (comma < 0) {
      throw ParseException('data URI missing comma: ${_preview(href)}');
    }
    final meta = href.substring(5, comma); // strip 'data:'
    final payload = href.substring(comma + 1);
    if (!meta.endsWith(';base64')) {
      throw UnsupportedFeatureException(
        'data-uri[non-base64]',
        'only base64 data URIs are supported',
      );
    }
    final mime = meta.substring(0, meta.length - ';base64'.length);
    return DataUri(mime: mime, base64: payload, raw: href);
  }

  String _preview(String href) =>
      href.length > 40 ? '${href.substring(0, 40)}...' : href;
}
