import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

import '../../core/errors.dart';
import '../../core/logger.dart';
import '../../domain/usecases/convert_svg_to_lottie.dart';
import '../cache/lottie_cache_manager.dart';

/// Fetches an SVG over HTTP, converts it to Lottie JSON via the Rust core,
/// and caches the result on disk for [Duration].days = 7.
///
/// Cache key is the URL string (one cached file per unique URL). On a hit
/// neither the network nor the FFI converter is touched.
class NetworkSvgLoader {
  NetworkSvgLoader({
    BaseCacheManager? cacheManager,
    AnimSvgLogger? logger,
    http.Client? httpClient,
    ConvertSvgToLottie? converter,
  })  : _cache = cacheManager ?? LottieCacheManager.instance,
        _log = logger ?? SilentLogger(),
        _http = httpClient ?? http.Client(),
        _converter = converter;

  final BaseCacheManager _cache;
  final AnimSvgLogger _log;
  final http.Client _http;
  final ConvertSvgToLottie? _converter;

  Future<Uint8List> loadLottieBytes(String url) async {
    final hit = await _cache.getFileFromCache(url);
    if (hit != null && hit.validTill.isAfter(DateTime.now())) {
      final bytes = await hit.file.readAsBytes();
      _log.info('network.cache', 'hit', fields: {
        'url': url,
        'json_bytes': bytes.length,
        'valid_till': hit.validTill.toIso8601String(),
      });
      return bytes;
    }

    _log.info('network.fetch', 'GET', fields: {'url': url});
    final sw = Stopwatch()..start();
    final http.Response resp;
    try {
      resp = await _http.get(Uri.parse(url));
    } catch (e, s) {
      _log.error('network.fetch', 'transport failure',
          error: e, stack: s, fields: {'url': url});
      throw NetworkSvgException(url, reason: e.toString());
    }
    sw.stop();
    if (resp.statusCode != 200) {
      _log.error('network.fetch', 'non-200',
          fields: {'url': url, 'status': resp.statusCode, 'duration_ms': sw.elapsedMilliseconds});
      throw NetworkSvgException(url, statusCode: resp.statusCode);
    }
    _log.debug('network.fetch', 'ok', fields: {
      'url': url,
      'svg_bytes': resp.bodyBytes.length,
      'duration_ms': sw.elapsedMilliseconds,
    });

    final converter = _converter ?? ConvertSvgToLottie(logger: _log);
    final envelope = converter.convertToEnvelope(resp.body);
    final bytes = Uint8List.fromList(utf8.encode(envelope.lottieJson));

    await _cache.putFile(
      url,
      bytes,
      fileExtension: 'json',
      maxAge: const Duration(days: 7),
    );
    _log.info('network.cache', 'store',
        fields: {'url': url, 'json_bytes': bytes.length});
    return bytes;
  }
}
