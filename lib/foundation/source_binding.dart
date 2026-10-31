import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/app.dart';

/// 一条「备用源」记录：同一本书在另一个源里的位置。
class SourceBinding {
  /// 备用源 key
  final String sourceKey;

  /// 备用源中的漫画 id
  final String comicId;

  /// 备用源中的标题
  final String title;

  /// 备用源中的封面（可能为空）
  final String? cover;

  final int addTime;

  const SourceBinding({
    required this.sourceKey,
    required this.comicId,
    required this.title,
    this.cover,
    required this.addTime,
  });
}

/// 多源绑定管理。
///
/// 收藏里的某本书在 A 源失效后，可以把它在 B/C 源的同一个漫画绑定成备用源；
/// 再次打开 A 源失败时会自动跳到第一个可用的备用源。
class SourceBindingManager {
  static Database? _db;

  static Database get _database {
    var db = _db;
    if (db != null) {
      return db;
    }
    final dir = Directory(App.dataPath);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    db = sqlite3.open("${App.dataPath}/source_binding.db");
    db.execute("""
      create table if not exists source_binding (
        owner_source text not null,
        owner_id text not null,
        source_key text not null,
        comic_id text not null,
        title text not null,
        cover text,
        add_time integer not null,
        primary key (owner_source, owner_id, source_key, comic_id)
      );
    """);
    _db = db;
    return db;
  }

  /// 同一本书的主键
  static String ownerKey(String sourceKey, String comicId) =>
      "$sourceKey::$comicId";

  static List<SourceBinding> alternatives(String sourceKey, String comicId) {
    try {
      final rows = _database.select(
        "select source_key, comic_id, title, cover, add_time from source_binding "
        "where owner_source = ? and owner_id = ? order by add_time asc;",
        [sourceKey, comicId],
      );
      return rows
          .map((e) => SourceBinding(
                sourceKey: e["source_key"] as String,
                comicId: e["comic_id"] as String,
                title: e["title"] as String,
                cover: e["cover"] as String?,
                addTime: e["add_time"] as int,
              ))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static bool isBound(
    String ownerSource,
    String ownerId,
    String sourceKey,
    String comicId,
  ) {
    try {
      final rows = _database.select(
        "select 1 from source_binding where owner_source = ? and owner_id = ? "
        "and source_key = ? and comic_id = ? limit 1;",
        [ownerSource, ownerId, sourceKey, comicId],
      );
      return rows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static void bind({
    required String ownerSource,
    required String ownerId,
    required String sourceKey,
    required String comicId,
    required String title,
    String? cover,
  }) {
    try {
      _database.execute(
        "insert or replace into source_binding "
        "(owner_source, owner_id, source_key, comic_id, title, cover, add_time) "
        "values (?, ?, ?, ?, ?, ?, ?);",
        [
          ownerSource,
          ownerId,
          sourceKey,
          comicId,
          title,
          cover,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
    } catch (_) {
      // 绑定失败不影响主流程
    }
  }

  static void unbind({
    required String ownerSource,
    required String ownerId,
    required String sourceKey,
    required String comicId,
  }) {
    try {
      _database.execute(
        "delete from source_binding where owner_source = ? and owner_id = ? "
        "and source_key = ? and comic_id = ?;",
        [ownerSource, ownerId, sourceKey, comicId],
      );
    } catch (_) {}
  }

  /// 该作品一共绑定了多少个备用源
  static int countOf(String ownerSource, String ownerId) {
    try {
      final rows = _database.select(
        "select count(*) as c from source_binding "
        "where owner_source = ? and owner_id = ?;",
        [ownerSource, ownerId],
      );
      return (rows.first["c"] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }
}
