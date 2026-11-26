import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/cloud_bootstrap.dart';

/// 网盘漫画的图在压缩包/PDF 里，没有可请求的地址，只能由源把字节读出来
/// （`loadBytes`）。以前 `ImageDownloader` 只认 `url`，这类 key 被当成 URL
/// 丢给 dio/rhttp，直接 `builder error for url (remote-zip:...)`：封面空白、
/// 阅读页整屏「重试」。
void main() {
  const sourceKey = 'test-cloud-source';

  // 一段最小但完整的 JPEG（FF D8 … FF D9）。
  final jpeg = Uint8List.fromList([0xFF, 0xD8, 0x11, 0x22, 0x33, 0xFF, 0xD9]);

  tearDown(() {
    ComicSourceManager().remove(sourceKey);
  });

  ComicSource sourceWith({
    required Future<Uint8List> Function(CancelToken token) loader,
  }) {
    return ComicSource.builtin(
      'Test Cloud',
      sourceKey,
      getImageLoadingConfig: (imageKey, comicId, epId) async => {
        'loadBytes': loader,
      },
      getThumbnailLoadingConfig: (imageKey) => {'loadBytes': loader},
    );
  }

  test('阅读页图片走 loadBytes，不再把 key 当 URL 请求', () async {
    var calls = 0;
    ComicSourceManager().add(
      sourceWith(
        loader: (token) async {
          calls++;
          return jpeg;
        },
      ),
    );

    final events = await ImageDownloader.loadComicImageUnwrapped(
      'remote-zip:abc',
      sourceKey,
      'cid',
      'ep',
      useCache: false,
    ).toList();

    expect(events.last.imageBytes, jpeg);
    expect(calls, 1);
  });

  test('loadBytes 瞬时失败会重试一次再放弃', () async {
    var calls = 0;
    ComicSourceManager().add(
      sourceWith(
        loader: (token) async {
          calls++;
          if (calls == 1) throw 'Remote archive is temporarily unavailable';
          return jpeg;
        },
      ),
    );

    final events = await ImageDownloader.loadComicImageUnwrapped(
      'remote-zip:abc',
      sourceKey,
      'cid',
      'ep',
      useCache: false,
    ).toList();

    expect(events.last.imageBytes, jpeg);
    expect(calls, 2);
  });

  test('loadBytes 连续失败时把错误抛出来（阅读页显示重试而不是空白）', () async {
    var calls = 0;
    ComicSourceManager().add(
      sourceWith(
        loader: (token) async {
          calls++;
          throw 'Remote archive is unavailable';
        },
      ),
    );

    await expectLater(
      ImageDownloader.loadComicImageUnwrapped(
        'remote-zip:abc',
        sourceKey,
        'cid',
        'ep',
        useCache: false,
      ).toList(),
      throwsA(contains('unavailable')),
    );
    expect(calls, 2);
  });

  group('「继续阅读」认出网盘漫画', () {
    test('网盘库的 sourceKey 认得出来，普通源不会误判', () {
      expect(CloudBootstrap.isCloudSourceKey('remote_library_3f2a'), isTrue);
      expect(CloudBootstrap.isCloudSourceKey('webdav_library'), isTrue);
      expect(CloudBootstrap.isCloudSourceKey('local'), isFalse);
      expect(CloudBootstrap.isCloudSourceKey('some_js_source'), isFalse);
    });

    test('库被删到只剩 Unknown:<type> 时，靠封面 key 仍然认得出', () {
      expect(
        CloudBootstrap.looksLikeCloudComic('remote-zip:W10'),
        isTrue,
      );
      expect(
        CloudBootstrap.looksLikeCloudComic('remote-work-image:W10'),
        isTrue,
      );
      expect(
        CloudBootstrap.looksLikeCloudComic('https://example.com/cover.jpg'),
        isFalse,
      );
      expect(CloudBootstrap.looksLikeCloudComic('cover.1'), isFalse);
    });
  });
}
