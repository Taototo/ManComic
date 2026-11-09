import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/utils/image.dart';
import 'package:venera/utils/file_type.dart';

import 'app_dio.dart';

abstract class ImageDownloader {
  static Stream<ImageDownloadProgress> loadThumbnail(
      String url, String? sourceKey,
      [String? cid]) async* {
    final cacheKey = "$url@$sourceKey${cid != null ? '@$cid' : ''}";
    final cache = await CacheManager().findCache(cacheKey);

    // 缓存里也可能躺着半张图（旧版本就是这么写进去的），先用再说等于
    // 一直修不好。不完整就当没有，走网络重下并覆盖掉这份坏缓存。
    if (cache != null) {
      var data = await cache.readAsBytes();
      if (isCompleteImageBytes(data)) {
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
      }
    }

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs = comicSource?.getThumbnailLoadingConfig?.call(url) ?? {};
    }
    configs['headers'] ??= {};
    if (configs['headers']['user-agent'] == null &&
        configs['headers']['User-Agent'] == null) {
      configs['headers']['user-agent'] = webUA;
    }

    if (((configs['url'] as String?) ?? url).startsWith('cover.') &&
        sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      if(comicSource != null) {
        var comicInfo = await comicSource.loadComicInfo!(cid!);
        yield* loadThumbnail(comicInfo.data.cover, sourceKey);
        return;
      }
    }

    var dio = AppDio(BaseOptions(
      headers: Map<String, dynamic>.from(configs['headers']),
      method: configs['method'] ?? 'GET',
      responseType: ResponseType.stream,
    ));

    String requestUrl = configs['url'] ?? url;
    if (requestUrl.startsWith('//')) {
      requestUrl = 'https:$requestUrl';
    }
    var req = await dio.request<ResponseBody>(requestUrl,
        data: configs['data']);
    var stream = req.data?.stream ?? (throw "Error: Empty response body.");
    int? expectedBytes = req.data!.contentLength;
    if (expectedBytes == -1) {
      expectedBytes = null;
    }
    var buffer = <int>[];
    await for (var data in stream) {
      buffer.addAll(data);
      if (expectedBytes != null) {
        yield ImageDownloadProgress(
          currentBytes: buffer.length,
          totalBytes: expectedBytes,
        );
      }
    }

    _ensureCompleteBody(buffer.length, expectedBytes, requestUrl);

    if (configs['onResponse'] is JSInvokable) {
      final uint8List = Uint8List.fromList(buffer);
      buffer = (configs['onResponse'] as JSInvokable)([uint8List]);
      (configs['onResponse'] as JSInvokable).free();
    }

    await CacheManager().writeCache(cacheKey, buffer);
    yield ImageDownloadProgress(
      currentBytes: buffer.length,
      totalBytes: buffer.length,
      imageBytes: Uint8List.fromList(buffer),
    );
  }

  static final _loadingImages = <String, _StreamWrapper<ImageDownloadProgress>>{};

  /// Cancel all loading images.
  static void cancelAllLoadingImages() {
    for (var wrapper in _loadingImages.values) {
      wrapper.cancel();
    }
    _loadingImages.clear();
  }

  /// Load a comic image from the network or cache.
  /// The function will prevent multiple requests for the same image.
  static Stream<ImageDownloadProgress> loadComicImage(
      String imageKey, String? sourceKey, String cid, String eid) {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    if (_loadingImages.containsKey(cacheKey)) {
      return _loadingImages[cacheKey]!.stream;
    }
    final stream = _StreamWrapper<ImageDownloadProgress>(
      _loadComicImage(imageKey, sourceKey, cid, eid),
      (wrapper) {
        _loadingImages.remove(cacheKey);
      },
    );
    _loadingImages[cacheKey] = stream;
    return stream.stream;
  }

  /// [useCache] 为 false 时既不读也不写图片缓存。
  ///
  /// 下载任务要把图存进漫画目录，缓存那份纯属重复：一次下载写两遍盘、
  /// 多一条缓存库记录。多任务并发时这些 IO 会把主线程挤爆。
  static Stream<ImageDownloadProgress> loadComicImageUnwrapped(
    String imageKey,
    String? sourceKey,
    String cid,
    String eid, {
    bool useCache = true,
  }) {
    return _loadComicImage(imageKey, sourceKey, cid, eid, useCache: useCache);
  }

  static Stream<ImageDownloadProgress> _loadComicImage(
      String imageKey, String? sourceKey, String cid, String eid,
      {bool useCache = true}) async* {
    final cacheKey = "$imageKey@$sourceKey@$cid@$eid";
    final cache = useCache ? await CacheManager().findCache(cacheKey) : null;

    if (cache != null) {
      var data = await cache.readAsBytes();
      // 同上：半张图留在缓存里会让「断点续传」永远补不回来。
      if (isCompleteImageBytes(data)) {
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        // 缓存里就是完整的一张，不用再去网络拿一遍。以前这里会继续往
        // 下走，同一张图下两次、写两遍。
        return;
      }
    }

    Future<Map<String, dynamic>?> Function()? onLoadFailed;

    var configs = <String, dynamic>{};
    if (sourceKey != null) {
      var comicSource = ComicSource.find(sourceKey);
      configs = (await comicSource!.getImageLoadingConfig
              ?.call(imageKey, cid, eid)) ??
          {};
    }
    var retryLimit = 5;
    while (true) {
      try {
        configs['headers'] ??= {
          'user-agent': webUA,
        };

        if (configs['onLoadFailed'] is JSInvokable) {
          onLoadFailed = () async {
            dynamic result = (configs['onLoadFailed'] as JSInvokable)([]);
            if (result is Future) {
              result = await result;
            }
            if (result is! Map<String, dynamic>) return null;
            return result;
          };
        }

        var dio = AppDio(BaseOptions(
          headers: configs['headers'],
          method: configs['method'] ?? 'GET',
          responseType: ResponseType.stream,
        ));

        var req = await dio.request<ResponseBody>(configs['url'] ?? imageKey,
            data: configs['data']);
        var stream = req.data?.stream ?? (throw "Error: Empty response body.");
        int? expectedBytes = req.data!.contentLength;
        if (expectedBytes == -1) {
          expectedBytes = null;
        }
        // BytesBuilder 而不是 List<int> + addAll：一张 2MB 的图要收几百个
        // chunk，逐个 add 到可增长 List 里是「每个字节搬进一个 int 槽」，
        // 十几张并发时这部分能吃掉主线程相当一块时间。
        var builder = BytesBuilder(copy: false);
        var received = 0;
        await for (var data in stream) {
          builder.add(data);
          received += data.length;
          yield ImageDownloadProgress(
            currentBytes: received,
            totalBytes: expectedBytes,
          );
        }

        _ensureCompleteBody(
          received,
          expectedBytes,
          '${configs['url'] ?? imageKey}',
        );

        var data = builder.takeBytes();
        if (configs['onResponse'] is JSInvokable) {
          dynamic result = (configs['onResponse'] as JSInvokable)([data]);
          if (result is Future) {
            result = await result;
          }
          if (result is List<int>) {
            data = result is Uint8List ? result : Uint8List.fromList(result);
          } else {
            throw "Error: Invalid onResponse result.";
          }
          (configs['onResponse'] as JSInvokable).free();
        }

        if (configs['modifyImage'] != null) {
          var newData = await modifyImageWithScript(
            data,
            configs['modifyImage'],
          );
          data = newData;
        }

        if (useCache) {
          await CacheManager().writeCache(cacheKey, data);
        }
        yield ImageDownloadProgress(
          currentBytes: data.length,
          totalBytes: data.length,
          imageBytes: data,
        );
        return;
      } catch (e) {
        if (retryLimit < 0 || onLoadFailed == null) {
          rethrow;
        }
        var newConfig = await onLoadFailed();
        (configs['onLoadFailed'] as JSInvokable).free();
        onLoadFailed = null;
        if (newConfig == null) {
          rethrow;
        }
        configs = newConfig;
        retryLimit--;
      } finally {
        if (onLoadFailed != null) {
          (configs['onLoadFailed'] as JSInvokable).free();
        }
      }
    }
  }
}

/// A wrapper class for a stream that
/// allows multiple listeners to listen to the same stream.
class _StreamWrapper<T> {
  final Stream<T> _stream;

  final List<StreamController> controllers = [];

  final void Function(_StreamWrapper<T> wrapper) onClosed;

  bool isClosed = false;

  _StreamWrapper(this._stream, this.onClosed) {
    _listen();
  }

  void _listen() async {
    try {
      await for (var data in _stream) {
        if (isClosed) {
          break;
        }
        for (var controller in controllers) {
          if (!controller.isClosed) {
            controller.add(data);
          }
        }
      }
    }
    catch (e) {
      for (var controller in controllers) {
        if (!controller.isClosed) {
          controller.addError(e);
        }
      }
    }
    finally {
      for (var controller in controllers) {
        if (!controller.isClosed) {
          controller.close();
        }
      }
    }
    controllers.clear();
    isClosed = true;
    onClosed(this);
  }

  Stream<T> get stream {
    if (isClosed) {
      throw Exception('Stream is closed');
    }
    var controller = StreamController<T>();
    controllers.add(controller);
    controller.onCancel = () {
      controllers.remove(controller);
    };
    return controller.stream;
  }

  void cancel() {
    for (var controller in controllers) {
      controller.close();
    }
    controllers.clear();
    isClosed = true;
  }
}

class ImageDownloadProgress {
  final int currentBytes;

  final int? totalBytes;

  final Uint8List? imageBytes;

  const ImageDownloadProgress({
    required this.currentBytes,
    required this.totalBytes,
    this.imageBytes,
  });
}

/// 拦截「响应流提前结束但没报错」的响应。
///
/// 断线、代理掐连接、服务端限速踢人时，dio 的流可能只是干净地结束，缓冲区
/// 里留半张图。上层看到有 imageBytes 就当成功，把半张图写进磁盘和缓存，
/// 之后就再也修不好了：封面一直是加载失败，而且任务记录已记成下过，恢复
/// 下载时会整个跳过封面。
///
/// 只判「少」不判「多」：开了 gzip 的响应，contentLength 是压缩后的长度，
/// 解压后的字节数会比它大，那不是截断。
void _ensureCompleteBody(int received, int? expected, String url) {
  if (expected == null || expected <= 0) {
    return;
  }
  if (received < expected) {
    throw "Error: Incomplete response ($received/$expected bytes) for $url";
  }
}
