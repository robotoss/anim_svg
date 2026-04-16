import 'dart:convert';
import 'dart:typed_data';

import 'package:anim_svg/anim_svg.dart';
import 'package:file/file.dart' as fs;
import 'package:file/memory.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _FakeCache extends Fake implements BaseCacheManager {
  final fs.FileSystem _fs = MemoryFileSystem();
  Uint8List? _stored;
  DateTime _validTill = DateTime(2000);
  int putCalls = 0;

  void preload(Uint8List bytes, {required Duration validFor}) {
    _stored = bytes;
    _validTill = DateTime.now().add(validFor);
  }

  @override
  Future<FileInfo?> getFileFromCache(String key,
      {bool ignoreMemCache = false}) async {
    final bytes = _stored;
    if (bytes == null) return null;
    final f = _fs.file('/cache/${key.hashCode}.json');
    await f.create(recursive: true);
    await f.writeAsBytes(bytes);
    return FileInfo(f, FileSource.Cache, _validTill, key);
  }

  @override
  Future<fs.File> putFile(
    String url,
    Uint8List fileBytes, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) async {
    _stored = fileBytes;
    _validTill = DateTime.now().add(maxAge);
    putCalls += 1;
    final f = _fs.file('/cache/put_${url.hashCode}.$fileExtension');
    await f.create(recursive: true);
    await f.writeAsBytes(fileBytes);
    return f;
  }
}

class _StubConverter extends ConvertSvgToLottie {
  _StubConverter(this._json) : super();
  final String _json;
  int calls = 0;

  @override
  RustConvertEnvelope convertToEnvelope(String svgXml) {
    calls += 1;
    return RustConvertEnvelope(
      lottieJson: _json,
      lottie: jsonDecode(_json),
      svgRaw: null,
      logs: const [],
      error: null,
    );
  }
}

void main() {
  group('NetworkSvgException', () {
    test('toString includes URL and status', () {
      final e = NetworkSvgException('https://x/y.svg', statusCode: 404);
      expect(e.toString(), contains('https://x/y.svg'));
      expect(e.toString(), contains('404'));
    });

    test('toString includes reason when no status', () {
      final e = NetworkSvgException('https://x/y.svg', reason: 'timeout');
      expect(e.toString(), contains('timeout'));
    });
  });

  group('NetworkSvgLoader', () {
    const lottieJson = '{"v":"5.7","layers":[{"ty":4}]}';
    final lottieBytes = Uint8List.fromList(utf8.encode(lottieJson));

    test('cache hit returns stored bytes without HTTP or conversion', () async {
      final cache = _FakeCache()
        ..preload(lottieBytes, validFor: const Duration(days: 1));
      final stub = _StubConverter(lottieJson);
      var httpCalled = false;
      final client = MockClient((req) async {
        httpCalled = true;
        return http.Response('', 500);
      });

      final loader = NetworkSvgLoader(
        cacheManager: cache,
        httpClient: client,
        converter: stub,
      );
      final out = await loader.loadLottieBytes('https://x/cached.svg');

      expect(out, equals(lottieBytes));
      expect(httpCalled, isFalse);
      expect(stub.calls, 0);
      expect(cache.putCalls, 0);
    });

    test('cache miss fetches, converts and stores', () async {
      final cache = _FakeCache();
      final stub = _StubConverter(lottieJson);
      const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"/>';
      final client = MockClient((req) async {
        expect(req.url.toString(), 'https://x/fresh.svg');
        return http.Response(svg, 200);
      });

      final loader = NetworkSvgLoader(
        cacheManager: cache,
        httpClient: client,
        converter: stub,
      );
      final out = await loader.loadLottieBytes('https://x/fresh.svg');

      expect(stub.calls, 1);
      expect(cache.putCalls, 1);
      expect(utf8.decode(out), lottieJson);
    });

    test('non-200 response throws NetworkSvgException with status', () async {
      final cache = _FakeCache();
      final client = MockClient((_) async => http.Response('not found', 404));

      final loader = NetworkSvgLoader(
        cacheManager: cache,
        httpClient: client,
        converter: _StubConverter(lottieJson),
      );

      await expectLater(
        loader.loadLottieBytes('https://x/missing.svg'),
        throwsA(isA<NetworkSvgException>()
            .having((e) => e.statusCode, 'statusCode', 404)
            .having((e) => e.url, 'url', 'https://x/missing.svg')),
      );
      expect(cache.putCalls, 0);
    });

    test('expired cache entry triggers refetch', () async {
      final cache = _FakeCache()
        ..preload(lottieBytes, validFor: const Duration(days: -1));
      final stub = _StubConverter(lottieJson);
      var httpCalled = false;
      final client = MockClient((_) async {
        httpCalled = true;
        return http.Response('<svg/>', 200);
      });

      final loader = NetworkSvgLoader(
        cacheManager: cache,
        httpClient: client,
        converter: stub,
      );
      await loader.loadLottieBytes('https://x/stale.svg');

      expect(httpCalled, isTrue);
      expect(stub.calls, 1);
      expect(cache.putCalls, 1);
    });
  });
}
