import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/artwork_fixture.dart';

class _CountingCache extends FakeArtworkCacheManager {
  _CountingCache(super.file);
  int reads = 0;
  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) {
    reads++;
    return super.getFileStream(
      url,
      key: key,
      headers: headers,
      withProgress: withProgress,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _CountingCache cache;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('artwork-observer-');
    cache = _CountingCache(
      await writeTestPng(directory, width: 32, height: 24),
    );
    PaintingBinding.instance.imageCache.clear();
  });
  tearDown(() async {
    CachedNetworkImage.performanceObserver = null;
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    await directory.delete(recursive: true);
  });

  testWidgets('observer sees an existing decode without a second cache read', (
    tester,
  ) async {
    final stages = <String>[];
    CachedNetworkImage.performanceObserver = (stage, _, width, height) =>
        stages.add(stage);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: CachedNetworkImage(
            imageUrl: 'https://artwork.example/one',
            cacheManager: cache,
            width: 32,
            height: 24,
            fadeInDuration: Duration.zero,
            fadeOutDuration: Duration.zero,
          ),
        ),
      ),
    );
    for (var i = 0; i < 100 && !stages.contains('painted_in_viewport'); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(
      stages,
      containsAllInOrder(['requested', 'ready', 'painted_in_viewport']),
    );
    expect(cache.reads, 1);
    expect(find.byType(RawImage), findsOneWidget);
    expect(tester.takeException(), isNull);
    // A broken diagnostic sink cannot turn a successfully decoded image into an error.
    CachedNetworkImage.performanceObserver = (_, _, _, _) =>
        throw StateError('sink');
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: CachedNetworkImage(
            imageUrl: 'https://artwork.example/one',
            cacheManager: cache,
            width: 32,
            height: 24,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(cache.reads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
