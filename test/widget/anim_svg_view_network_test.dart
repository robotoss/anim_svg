import 'package:anim_svg/anim_svg.dart';
import 'package:file/file.dart' as fs;
import 'package:file/memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _EmptyCache extends Fake implements BaseCacheManager {
  final fs.FileSystem _fs = MemoryFileSystem();

  @override
  Future<FileInfo?> getFileFromCache(String key,
          {bool ignoreMemCache = false}) async =>
      null;

  @override
  Future<fs.File> putFile(
    String url,
    dynamic fileBytes, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) async {
    final f = _fs.file('/cache/${url.hashCode}.$fileExtension');
    await f.create(recursive: true);
    return f;
  }
}

void main() {
  testWidgets('network 404 renders default broken_image icon',
      (tester) async {
    final client = MockClient((_) async => http.Response('gone', 404));
    final loader = NetworkSvgLoader(
      cacheManager: _EmptyCache(),
      httpClient: client,
      logger: SilentLogger(),
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AnimSvgView.network(
          'https://x/missing.svg',
          width: 100,
          height: 100,
          loader: loader,
          logger: SilentLogger(),
        ),
      ),
    ));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('custom errorBuilder overrides default icon', (tester) async {
    final client = MockClient((_) async => http.Response('gone', 404));
    final loader = NetworkSvgLoader(
      cacheManager: _EmptyCache(),
      httpClient: client,
      logger: SilentLogger(),
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AnimSvgView.network(
          'https://x/missing.svg',
          width: 100,
          height: 100,
          loader: loader,
          logger: SilentLogger(),
          errorBuilder: (ctx, err, st) => const Text('custom-error'),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('custom-error'), findsOneWidget);
    expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
  });
}
