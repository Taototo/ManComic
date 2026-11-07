import 'dart:convert';

import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';

/// 把在线源的详情页内容缓存一份到已下载漫画的目录里。
///
/// 已下载的漫画在列表里点封面，打开的是**在线源**的详情页（ComicPage），这个
/// 页面每次都要向源站要一次 loadComicInfo。断网时它只能显示一张错误页——整本
/// 漫画就在手机里，却连章节列表都看不见，还得再点一次「阅读」抄近路。
///
/// 所以下载时顺手把 ComicDetails 存成 `<漫画目录>/details.json`：
/// - 它跟着漫画走，删漫画时目录一起消失，不用另做清理策略，也不会无限增长；
/// - 用户搬动本地漫画库、做备份恢复，缓存跟着一起走；
/// - 断网时详情页直接拿这份渲染，联网时再静默刷新。
///
/// 只缓存「详情」这一层（标题、简介、标签、章节表）。截图里的图、评论、推荐位
/// 不存：离线时它们本来也用不上，存了只是让文件变大。
class ComicDetailsCache {
  static const String fileName = "details.json";

  static File? _fileOf(String comicId, ComicType type) {
    try {
      final local = LocalManager().find(comicId, type);
      if (local == null) {
        return null;
      }
      return File(FilePath.join(local.baseDir, fileName));
    } catch (e, s) {
      // 本地库没初始化、目录被删、路径非法……缓存是尽力而为的东西，
      // 失败就当没有，不能把下载或详情页带崩。
      Log.error("ComicDetailsCache", "resolve path failed: $e", s);
      return null;
    }
  }

  /// 写入（覆盖）该漫画的详情快照。
  ///
  /// [directory] 用于下载途中：那时漫画目录刚建好，还没有写进 LocalManager
  /// 的数据库，按 id 查不到本地漫画，只能由调用方把目录直接告诉我们。
  static void save(
    ComicDetails details,
    ComicType type, {
    String? directory,
  }) {
    final file = directory != null
        ? File(FilePath.join(directory, fileName))
        : _fileOf(details.id, type);
    if (file == null) {
      return;
    }
    try {
      file.parent.forceCreateSync();
      file.writeAsStringSync(jsonEncode(details.toJson()), flush: true);
    } catch (e, s) {
      Log.error("ComicDetailsCache", "write failed: $e", s);
    }
  }

  /// 读取详情快照，没有或已损坏时返回 null。
  static ComicDetails? load(String comicId, ComicType type) {
    final file = _fileOf(comicId, type);
    if (file == null || !file.existsSync()) {
      return null;
    }
    try {
      final json = jsonDecode(file.readAsStringSync());
      if (json is! Map) {
        return null;
      }
      final details = ComicDetails.fromJson(Map<String, dynamic>.from(json));
      // 标题是详情页的骨架，缺了说明文件不可用；章节表可以缺（有的源本来
      // 就是单本图集）。
      if (details.title.trim().isEmpty) {
        return null;
      }
      return details;
    } catch (e, s) {
      Log.error("ComicDetailsCache", "read failed: $e", s);
      return null;
    }
  }

  /// 删除该漫画的详情快照（漫画被删除或被移动到别处时用）。
  static void remove(String comicId, ComicType type) {
    final file = _fileOf(comicId, type);
    if (file == null) {
      return;
    }
    try {
      file.deleteIgnoreError();
    } catch (e, s) {
      Log.error("ComicDetailsCache", "delete failed: $e", s);
    }
  }
}
