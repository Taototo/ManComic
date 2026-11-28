import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/images.dart';
import '../history.dart';
import 'base_image_provider.dart';
import 'history_image_provider.dart' as image_provider;

class HistoryImageProvider
    extends BaseImageProvider<image_provider.HistoryImageProvider> {
  /// Image provider for normal image.
  ///
  /// [url] is the url of the image. Local file path is also supported.
  const HistoryImageProvider(this.history);

  final History history;

  /// 正在向源重新取封面地址的请求，按「源 + 作品 id」去重。
  ///
  /// 列表重建时同一部作品的封面可能被并发加载多次，
  /// 去重可以避免对源站发出重复的详情请求。
  static final Map<String, Future<String?>> _refreshing = {};

  @override
  Future<Uint8List> load(chunkEvents, checkStop) async {
    var url = history.cover;

    if (!url.contains('/')) {
      // 历史记录里存的是占位符（旧数据），只能现取。
      var localComic = LocalManager().find(history.id, history.type);
      if (localComic != null) {
        return localComic.coverFile.readAsBytes();
      }
      url = await _refreshCover() ?? (throw "Comic source not found.");
    } else if (_isSignatureExpired(url)) {
      // 部分源（Cloudflare R2 / S3 等）返回的是带有效期的预签名地址，
      // 历史记录把地址存下来后，超过 X-Amz-Expires 就必然 403。
      // 先换一张新地址，省掉一次注定失败的请求。
      url = await _refreshCover() ?? url;
    }

    try {
      return await _download(url, chunkEvents, checkStop);
    } catch (e) {
      // 落到这里通常是：预签名已过期但识别不出来（签名参数不是 X-Amz-*），
      // 或源换了鉴权方式。重新向源取一次封面地址，重试一次。
      if (!_isPermissionError(e)) {
        rethrow;
      }
      final refreshed = await _refreshCover();
      if (refreshed == null || refreshed == url) {
        rethrow;
      }
      return await _download(refreshed, chunkEvents, checkStop);
    }
  }

  Future<Uint8List> _download(
    String url,
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  ) async {
    await for (var progress in ImageDownloader.loadThumbnail(
      url,
      history.type.sourceKey,
      history.id,
    )) {
      checkStop();
      chunkEvents.add(ImageChunkEvent(
        cumulativeBytesLoaded: progress.currentBytes,
        expectedTotalBytes: progress.totalBytes,
      ));
      if (progress.imageBytes != null) {
        return progress.imageBytes!;
      }
    }
    throw "Error: Empty response body.";
  }

  /// 向漫画源重新取一次封面地址，并写回历史记录。
  ///
  /// 取不到（源不可用、作品已下架等）时返回 null，由调用方决定降级方式。
  Future<String?> _refreshCover() {
    final key = "${history.type.sourceKey}@${history.id}";
    final running = _refreshing[key];
    if (running != null) {
      return running;
    }
    final future = _doRefreshCover();
    _refreshing[key] = future;
    return future.whenComplete(() {
      _refreshing.remove(key);
    });
  }

  Future<String?> _doRefreshCover() async {
    final comicSource = history.type.comicSource;
    if (comicSource == null || comicSource.loadComicInfo == null) {
      return null;
    }
    try {
      final res = await comicSource.loadComicInfo!(history.id);
      if (res.error) {
        return null;
      }
      final cover = res.data.cover;
      if (cover.isEmpty) {
        return null;
      }
      if (cover != history.cover) {
        history.cover = cover;
        HistoryManager().addHistory(history);
      }
      return cover;
    } catch (e, s) {
      Log.error("Image Loading", "Failed to refresh cover: $e\n$s");
      return null;
    }
  }

  /// 预签名地址是否已过期（AWS S3 / Cloudflare R2 风格：X-Amz-Date + X-Amz-Expires）。
  ///
  /// 识别不出来时返回 false，交给 403 兜底，不会误判。
  static final _amzDateReg =
      RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$');

  static bool _isSignatureExpired(String url) {
    if (!url.contains('X-Amz-Signature')) {
      return false;
    }
    final params = Uri.tryParse(url)?.queryParameters;
    if (params == null) {
      return false;
    }
    final match = _amzDateReg.firstMatch(params['X-Amz-Date'] ?? '');
    final expires = int.tryParse(params['X-Amz-Expires'] ?? '');
    if (match == null || expires == null) {
      return false;
    }
    final start = DateTime.utc(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
      int.parse(match[4]!),
      int.parse(match[5]!),
      int.parse(match[6]!),
    );
    // 留 60 秒余量，避免刚好卡在临界点发出请求被服务端判过期。
    final deadline = start.add(Duration(seconds: expires - 60));
    return DateTime.now().toUtc().isAfter(deadline);
  }

  /// 是否为「无权限 / 签名失效」类错误。
  ///
  /// 用具体的错误文案匹配，避免 URL 里恰好带 403 时被误判。
  static final _permissionErrorReg =
      RegExp(r'Invalid Status Code: 40[13]|status code of 40[13]');

  static bool _isPermissionError(Object e) {
    return _permissionErrorReg.hasMatch(e.toString());
  }

  @override
  Future<HistoryImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  String get key => "history${history.id}${history.type.value}";
}
