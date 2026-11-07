import 'dart:convert';

import 'package:venera/foundation/cloud_library.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/app_dio.dart';
import 'package:webdav_client/webdav_client.dart' hide File;

/// 网盘线路：把镜像到 WebDAV 上的本地漫画当成一个漫画源来读。
///
/// 之所以做成 ComicSource 而不是另建一套类型：详情页、阅读器、历史、
/// 收藏、图片缓存全都按「sourceKey + id」工作，注册一个源就等于全部复用，
/// 一行阅读器代码都不用改。图片是 WebDAV 上的独立文件，所以阅读器只会
/// 拉当前页，不需要把整本下回来。
///
/// 这里用漫画的**目录名**当 id。目录名本来就在上传时确定（标题转义），
/// 且远端结构就是按它组织的，直接拿它定位最省事，不需要额外维护映射表。
class CloudSource {
  static const String key = "cloud";

  static ComicSource create() {
    return ComicSource.builtin(
      "Cloud Library",
      key,
      loadComicInfo: _loadComicInfo,
      loadComicPages: _loadComicPages,
      getImageLoadingConfig: (imageKey, comicId, epId) async => _headers(),
      getThumbnailLoadingConfig: (imageKey) => _headers(),
    );
  }

  static Client? _client() {
    final config = CloudLibrary().config;
    if (config == null) {
      return null;
    }
    return newClient(
      config[0],
      user: config[1],
      password: config[2],
      adapter: RHttpAdapter(),
    );
  }

  /// 图片请求要带 Basic Auth。WebDAV 的图片就是一个普通 HTTP 资源，
  /// 不带认证头会拿到 401，阅读器和封面都会是空白。
  static Map<String, dynamic> _headers() {
    final config = CloudLibrary().config;
    if (config == null) {
      return {};
    }
    final token = base64Encode(utf8.encode("${config[1]}:${config[2]}"));
    return {"authorization": "Basic $token"};
  }

  /// 拼出图片直链，编码规则放在 CloudLibrary 里，上传与读取共用一份。
  static String _imageUrl(String path) => CloudLibrary().imageUrl(path);

  static Future<Res<ComicDetails>> _loadComicInfo(String id) async {
    final client = _client();
    if (client == null) {
      return const Res.error("Comic Cloud is not configured");
    }
    try {
      // 详情快照是下载时写进漫画目录的，上传时一起镜像过去。
      // 有了它，网盘线路不联网也能显示章节表和封面。
      final bytes = await client.read("/$id/details.json");
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map) {
        return const Res.error("Invalid details.json on the cloud");
      }
      final map = Map<String, dynamic>.from(json);
      // 快照里的 cover 是相对路径（本地的写法），换成本次配置对应的直链。
      // 不做这一步，封面会被当成一个叫 "cover.jpg" 的网络地址去请求。
      final cover = map["cover"];
      if (cover is String &&
          cover.isNotEmpty &&
          !cover.startsWith("http")) {
        map["cover"] = _imageUrl("/$id/$cover");
      }
      return Res(ComicDetails.fromJson(map));
    } catch (e, s) {
      Log.error("CloudSource", "loadComicInfo $id failed: $e", s);
      return Res.error(e.toString());
    }
  }

  static Future<Res<List<String>>> _loadComicPages(
    String id,
    String? ep,
  ) async {
    final client = _client();
    if (client == null) {
      return const Res.error("Comic Cloud is not configured");
    }
    try {
      final chapterDir =
          ep == null ? null : LocalManager.getChapterDirectoryName(ep);
      final path = chapterDir == null ? "/$id" : "/$id/$chapterDir";
      final files = await client.readDir(path);
      final names = <String>[];
      for (final file in files) {
        if (file.isDir == true) {
          continue;
        }
        final name = _baseName(file.name ?? '');
        // 和本地 getImages 一个规则：跳过 cover.* 与隐藏文件，
        // 否则封面会变成第一页，且 .nomedia 会被当成一张图。
        if (name.isEmpty || name.startsWith('.') || name.startsWith('cover.')) {
          continue;
        }
        names.add(name);
      }
      if (names.isEmpty) {
        return const Res.error("No pages found on the cloud");
      }
      names.sort((a, b) {
        final ai = int.tryParse(a.split('.').first);
        final bi = int.tryParse(b.split('.').first);
        if (ai != null && bi != null) {
          return ai.compareTo(bi);
        }
        return a.compareTo(b);
      });
      return Res(
        names.map((e) => _imageUrl("$path/$e")).toList(),
      );
    } catch (e, s) {
      Log.error("CloudSource", "loadComicPages $id failed: $e", s);
      return Res.error(e.toString());
    }
  }

  static String _baseName(String path) {
    final p = path.replaceAll('\\', '/');
    final index = p.lastIndexOf('/');
    return index == -1 ? p : p.substring(index + 1);
  }
}
