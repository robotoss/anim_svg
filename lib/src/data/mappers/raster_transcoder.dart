import 'dart:convert';

import 'package:image/image.dart' as img;

import '../../core/errors.dart';
import '../parsers/data_uri_decoder.dart';

/// Transcodes raster data URIs into formats thorvg can decode.
///
/// thorvg 1.0's Flutter build ships with loaders `lottie, png, jpg` only —
/// WebP data URIs render as empty pixels. This class decodes WebP bytes and
/// re-encodes them as PNG, leaving PNG/JPEG URIs untouched.
class RasterTranscoder {
  const RasterTranscoder();

  DataUri transcodeIfNeeded(DataUri uri) {
    if (uri.mime != 'image/webp') return uri;
    img.Image? decoded;
    try {
      decoded = img.decodeWebP(uri.decode());
    } catch (e) {
      throw ConversionException('image/webp decode failed: $e');
    }
    if (decoded == null) {
      throw ConversionException('image/webp decode returned null');
    }
    final pngBytes = img.encodePng(decoded);
    final b64 = base64Encode(pngBytes);
    return DataUri(
      mime: 'image/png',
      base64: b64,
      raw: 'data:image/png;base64,$b64',
    );
  }
}
