import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/image_provider/local_favorite_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';
import 'dart:io';

import 'app.dart';
import 'comic_source/comic_source.dart';
import 'comic_type.dart';
import 'source_health.dart';

String _getTimeString(DateTime time) {
  return time.toIso8601String().replaceFirst("T", " ").substring(0, 19);
}

class FavoriteItem implements Comic {
  String name;
  String author;
  ComicType type;
  @override
  List<String> tags;
  @override
  String id;
  String coverPath;
  late String time;

  FavoriteItem({
    required this.id,
    required this.name,
    required this.coverPath,
    required this.author,
    required this.type,
    required this.tags,
    DateTime? favoriteTime,
  }) {
    var t = favoriteTime ?? DateTime.now();
    time = _getTimeString(t);
  }

  FavoriteItem.fromRow(Row row)
    : name = row["name"],
      author = row["author"],
      type = ComicType(row["type"]),
      tags = (row["tags"] as String).split(","),
      id = row["id"],
      coverPath = row["cover_path"],
      time = row["time"] {
    tags.remove("");
  }

  @override
  bool operator ==(Object other) {
    return other is FavoriteItem && other.id == id && other.type == type;
  }

  @override
  int get hashCode => id.hashCode ^ type.hashCode;

  @override
  String toString() {
    var s = "FavoriteItem: $name $author $coverPath $hashCode $tags";
    if (s.length > 100) {
      return s.substring(0, 100);
    }
    return s;
  }

  @override
  String get cover => coverPath;

  @override
  String get description {
    var time = this.time.substring(0, 10);
    return appdata.settings['comicDisplayMode'] == 'detailed'
        ? "$time | ${type == ComicType.local ? 'local' : type.comicSource?.name ?? "Unknown"}"
        : "${type.comicSource?.name ?? "Unknown"} | $time";
  }

  @override
  String? get favoriteId => null;

  @override
  String? get language => null;

  @override
  int? get maxPage => null;

  @override
  String get sourceKey => type == ComicType.local
      ? 'local'
      : type.comicSource?.key ?? "Unknown:${type.value}";

  @override
  double? get stars => null;

  @override
  String? get subtitle => author;

  @override
  String get title => name;

  @override
  Map<String, dynamic> toJson() {
    return {
      "name": name,
      "author": author,
      "type": type.value,
      "tags": tags,
      "id": id,
      "coverPath": coverPath,
    };
  }

  static FavoriteItem fromJson(Map<String, dynamic> json) {
    var type = json["type"] as int;
    if (type == 0 && json['coverPath'].toString().startsWith('http')) {
      type = 'picacg'.hashCode;
    } else if (type == 1) {
      type = 'ehentai'.hashCode;
    } else if (type == 2) {
      type = 'jm'.hashCode;
    } else if (type == 3) {
      type = 'hitomi'.hashCode;
    } else if (type == 4) {
      type = 'wnacg'.hashCode;
    } else if (type == 6) {
      type = 'nhentai'.hashCode;
    }
    return FavoriteItem(
      id: json["id"] ?? json['target'],
      name: json["name"],
      author: json["author"],
      coverPath: json["coverPath"],
      type: ComicType(type),
      tags: List<String>.from(json["tags"] ?? []),
    );
  }
}

class FavoriteItemWithFolderInfo extends FavoriteItem {
  String folder;

  FavoriteItemWithFolderInfo(FavoriteItem item, this.folder)
    : super(
        id: item.id,
        name: item.name,
        coverPath: item.coverPath,
        author: item.author,
        type: item.type,
        tags: item.tags,
      );
}

class FavoriteItemWithUpdateInfo extends FavoriteItem {
  String? updateTime;

  DateTime? lastCheckTime;

  bool hasNewUpdate;

  FavoriteItemWithUpdateInfo(
    FavoriteItem item,
    this.updateTime,
    this.hasNewUpdate,
    int? lastCheckTime,
  ) : lastCheckTime = lastCheckTime == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastCheckTime),
      super(
        id: item.id,
        name: item.name,
        coverPath: item.coverPath,
        author: item.author,
        type: item.type,
        tags: item.tags,
      );

  @override
  String get description {
    var updateTime = this.updateTime ?? "Unknown";
    var sourceName = type.comicSource?.name ?? "Unknown";
    return "$updateTime | $sourceName";
  }

  @override
  operator ==(Object other) {
    return other is FavoriteItemWithUpdateInfo &&
        other.updateTime == updateTime &&
        other.hasNewUpdate == hasNewUpdate &&
        super == other;
  }

  @override
  int get hashCode =>
      super.hashCode ^ updateTime.hashCode ^ hasNewUpdate.hashCode;
}

class LocalFavoritesManager with ChangeNotifier {
  factory LocalFavoritesManager() =>
      cache ?? (cache = LocalFavoritesManager._create());

  LocalFavoritesManager._create();

  static LocalFavoritesManager? cache;

  /// 「已阅」专用表名。
  ///
  /// 它是一张真实的收藏夹表（结构与普通收藏夹完全一致，复用同一套增删
  /// 移动逻辑），但被排除在 [folderNames] 之外——「全部」与文件夹列表都
  /// 通过 [folderNames] 枚举，所以移入已阅的漫画会自动从这两处消失，
  /// 不需要逐处过滤。UI 里用 `_localReadFolderLabel` 指代它。
  static const readFolderName = '__read__';

  /// 「失效」专用表名。和「已阅」同构：真实存在的一张表，但不在
  /// [folderNames] 里，所以进了失效分类的漫画自然从「全部」和各分类里
  /// 消失。原本这里只会被 [removeInvalid] 直接删掉——用户没来得及确认
  /// 哪些是真没了，收藏连同标签一起消失。现在先收进这张表，看得见、
  /// 删得掉，也能重新收藏回去。
  static const invalidFolderName = '__invalid__';

  late Database _db;

  late Map<String, int> counts;

  var _hashedIds = <int, int>{};

  /// 「已阅」表内漫画的 hash 集合，与普通收藏夹分开维护：
  /// totalComics（「全部」数量）不能包含已阅，但收藏标识（isExist）要包含。
  var _readHashedIds = <int, int>{};

  /// 「失效」表内漫画的 hash 集合，同上。
  var _invalidHashedIds = <int, int>{};

  int get totalComics {
    return _hashedIds.length;
  }

  int folderComics(String folder) {
    return counts[folder] ?? 0;
  }

  Future<void> init() async {
    counts = {};
    _db = sqlite3.open("${App.dataPath}/local_favorite.db");
    _db.execute("""
      create table if not exists folder_order (
        folder_name text primary key,
        order_value int
      );
    """);
    _db.execute("""
      create table if not exists folder_sync (
        folder_name text primary key,
        source_key text,
        source_folder text
      );
    """);
    // 「已阅」表必须先于任何 folderNames 枚举创建，保证升级用户也能用。
    _db.execute("""
      create table if not exists "$readFolderName"(
        id text,
        name TEXT,
        author TEXT,
        type int,
        tags TEXT,
        cover_path TEXT,
        time TEXT,
        display_order int,
        translated_tags TEXT,
        primary key (id, type)
      );
    """);
    // 「失效」表同理：这次升级引入，老库里没有，必须先建出来。
    // `origin` 记住「是从哪个分类挪进来的」，源恢复后能原路退回去。
    _db.execute("""
      create table if not exists "$invalidFolderName"(
        id text,
        name TEXT,
        author TEXT,
        type int,
        tags TEXT,
        cover_path TEXT,
        time TEXT,
        display_order int,
        translated_tags TEXT,
        origin TEXT,
        primary key (id, type)
      );
    """);
    // 1.4.46 造的表没有 origin，补一列（SQLite 的 add column 不会重写整表）。
    var invalidColumns = _db.select('pragma table_info("$invalidFolderName");');
    if (!invalidColumns.any((e) => e["name"] == "origin")) {
      _db.execute('alter table "$invalidFolderName" add column origin TEXT;');
    }
    var folderNames = _getFolderNamesWithDB();
    for (var folder in folderNames) {
      var columns = _db.select("""
        pragma table_info("$folder");
      """);
      if (!columns.any((element) => element["name"] == "translated_tags")) {
        _db.execute("""
          alter table "$folder"
          add column translated_tags TEXT;
        """);
        var comics = getFolderComics(folder);
        for (var comic in comics) {
          var translatedTags = _translateTags(comic.tags);
          _db.execute(
            """
            update "$folder"
            set translated_tags = ?
            where id == ? and type == ?;
          """,
            [translatedTags, comic.id, comic.type.value],
          );
        }
      } else {
        break;
      }
    }
    await appdata.ensureInit();
    // Make sure the follow updates folder is ready
    var followUpdateFolder = appdata.settings['followUpdatesFolder'];
    if (followUpdateFolder is String &&
        folderNames.contains(followUpdateFolder)) {
      prepareTableForFollowUpdates(followUpdateFolder, false);
    } else {
      appdata.settings['followUpdatesFolder'] = null;
    }
    _normalizeExclusiveFolders();
    initCounts();
  }

  /// 数据规范化：一本漫画只允许属于一个分类。
  /// 历史数据可能存在多分类共存，这里统一只保留最先创建的分类（已阅/失效
  /// 优先级最低，排在最后处理），在启动时一次性清理。
  void _normalizeExclusiveFolders() {
    var folders = [..._getFolderNamesWithDB(), readFolderName, invalidFolderName];
    var seen = <int>{};
    var changed = false;
    for (var folder in folders) {
      var rows = _db.select("""
        select id, type from "$folder";
      """);
      for (var row in rows) {
        var hash = (row['id'] as String).hashCode ^ (row['type'] as int);
        if (seen.contains(hash)) {
          _db.execute(
            """
            delete from "$folder"
            where id == ? and type == ?;
          """,
            [row['id'], row['type']],
          );
          changed = true;
        } else {
          seen.add(hash);
        }
      }
    }
    if (changed) {
      Log.info(
        "Favorites",
        "Removed comics that existed in multiple folders (exclusive policy)",
      );
    }
  }

  void initCounts() {
    for (var folder in folderNames) {
      counts[folder] = count(folder);
    }
    counts[readFolderName] = count(readFolderName);
    counts[invalidFolderName] = count(invalidFolderName);
    _refreshHashedIds();
  }

  void refreshHashedIds() {
    _refreshHashedIds();
  }

  /// 在一个 Isolate 里同时重建普通收藏夹、「已阅」「失效」的 hash 映射。
  void _refreshHashedIds() {
    _initHashedIds(
      [...folderNames, readFolderName, invalidFolderName],
      _db.handle,
    ).then((value) {
      var merged = <int, int>{};
      for (var folder in folderNames) {
        merged.addAll(value[folder] ?? const {});
      }
      _hashedIds = merged;
      _readHashedIds = value[readFolderName] ?? {};
      _invalidHashedIds = value[invalidFolderName] ?? {};
      notifyListeners();
    });
  }

  void reduceHashedId(String id, int type) {
    var hash = id.hashCode ^ type;
    if (_hashedIds.containsKey(hash)) {
      if (_hashedIds[hash]! > 1) {
        _hashedIds[hash] = _hashedIds[hash]! - 1;
      } else {
        _hashedIds.remove(hash);
      }
    }
  }

  void _reduceReadHashedId(String id, int type) {
    var hash = id.hashCode ^ type;
    if (_readHashedIds.containsKey(hash)) {
      if (_readHashedIds[hash]! > 1) {
        _readHashedIds[hash] = _readHashedIds[hash]! - 1;
      } else {
        _readHashedIds.remove(hash);
      }
    }
  }

  void _reduceInvalidHashedId(String id, int type) {
    var hash = id.hashCode ^ type;
    if (_invalidHashedIds.containsKey(hash)) {
      if (_invalidHashedIds[hash]! > 1) {
        _invalidHashedIds[hash] = _invalidHashedIds[hash]! - 1;
      } else {
        _invalidHashedIds.remove(hash);
      }
    }
  }

  static Future<Map<String, Map<int, int>>> _initHashedIds(
    List<String> folders,
    Pointer<void> p,
  ) {
    return Isolate.run(() {
      var db = sqlite3.fromPointer(p);
      var result = <String, Map<int, int>>{};
      for (var folder in folders) {
        var hashedIds = <int, int>{};
        var rows = db.select("""
          select id, type from "$folder";
        """);
        for (var row in rows) {
          var id = row["id"] as String;
          var type = row["type"] as int;
          var hash = id.hashCode ^ type;
          hashedIds[hash] = (hashedIds[hash] ?? 0) + 1;
        }
        result[folder] = hashedIds;
      }
      return result;
    });
  }

  /// 该漫画所在的收藏夹（表名）。包含「已阅」「失效」两个内置表——
  /// 本地漫画被删掉时要连带清掉它们，否则已阅里会留下一个点不开的条目。
  List<String> find(String id, ComicType type) {
    var res = <String>[];
    for (var folder in [...folderNames, readFolderName, invalidFolderName]) {
      var rows = _db.select(
        """
        select * from "$folder"
        where id == ? and type == ?;
      """,
        [id, type.value],
      );
      if (rows.isNotEmpty) {
        res.add(folder);
      }
    }
    return res;
  }

  Future<List<String>> findWithModel(FavoriteItem item) async {
    var res = <String>[];
    for (var folder in folderNames) {
      var rows = _db.select(
        """
        select * from "$folder"
        where id == ? and type == ?;
      """,
        [item.id, item.type.value],
      );
      if (rows.isNotEmpty) {
        res.add(folder);
      }
    }
    return res;
  }

  List<String> _getTablesWithDB() {
    final tables = _db
        .select("SELECT name FROM sqlite_master WHERE type='table';")
        .map((element) => element["name"] as String)
        .toList();
    return tables;
  }

  List<String> _getFolderNamesWithDB() {
    final folders = _getTablesWithDB();
    folders.remove('folder_sync');
    folders.remove('folder_order');
    // 「已阅」「失效」不是普通收藏夹，永远不出现在文件夹枚举里
    folders.remove(readFolderName);
    folders.remove(invalidFolderName);
    var folderToOrder = <String, int>{};
    for (var folder in folders) {
      var res = _db.select(
        """
        select * from folder_order
        where folder_name == ?;
      """,
        [folder],
      );
      if (res.isNotEmpty) {
        folderToOrder[folder] = res.first["order_value"];
      } else {
        folderToOrder[folder] = 0;
      }
    }
    folders.sort((a, b) {
      return folderToOrder[a]! - folderToOrder[b]!;
    });
    return folders;
  }

  void updateOrder(List<String> folders) {
    for (int i = 0; i < folders.length; i++) {
      _db.execute(
        """
        insert or replace into folder_order (folder_name, order_value)
        values (?, ?);
      """,
        [folders[i], i],
      );
    }
    notifyListeners();
  }

  int count(String folderName) {
    return _db.select("""
      select count(*) as c
      from "$folderName"
    """).first["c"];
  }

  List<String> get folderNames => _getFolderNamesWithDB();

  int maxValue(String folder) {
    return _db.select("""
        SELECT MAX(display_order) AS max_value
        FROM "$folder";
      """).firstOrNull?["max_value"] ??
        0;
  }

  int minValue(String folder) {
    return _db.select("""
        SELECT MIN(display_order) AS min_value
        FROM "$folder";
      """).firstOrNull?["min_value"] ??
        0;
  }

  List<FavoriteItem> getFolderComics(String folder) {
    var rows = _db.select("""
        select * from "$folder"
        ORDER BY display_order;
      """);
    return rows.map((element) => FavoriteItem.fromRow(element)).toList();
  }

  static Future<List<FavoriteItem>> _getFolderComicsAsync(
    String folder,
    Pointer<void> p,
  ) {
    return Isolate.run(() {
      var db = sqlite3.fromPointer(p);
      var rows = db.select("""
        select * from "$folder"
        ORDER BY display_order;
      """);
      return rows.map((element) => FavoriteItem.fromRow(element)).toList();
    });
  }

  /// Start a new isolate to get the comics in the folder
  Future<List<FavoriteItem>> getFolderComicsAsync(String folder) {
    return _getFolderComicsAsync(folder, _db.handle);
  }

  List<FavoriteItem> getAllComics() {
    var res = <FavoriteItem>{};
    for (final folder in folderNames) {
      var comics = _db.select("""
        select * from "$folder";
      """);
      res.addAll(comics.map((element) => FavoriteItem.fromRow(element)));
    }
    return res.toList();
  }

  static Future<List<FavoriteItem>> _getAllComicsAsync(
    List<String> folders,
    Pointer<void> p,
  ) {
    return Isolate.run(() {
      var db = sqlite3.fromPointer(p);
      var res = <FavoriteItem>{};
      for (final folder in folders) {
        var comics = db.select("""
          select * from "$folder";
        """);
        res.addAll(comics.map((element) => FavoriteItem.fromRow(element)));
      }
      return res.toList();
    });
  }

  /// Start a new isolate to get all the comics
  Future<List<FavoriteItem>> getAllComicsAsync() {
    return _getAllComicsAsync(folderNames, _db.handle);
  }

  void addTagTo(String folder, String id, String tag) {
    _db.execute(
      """
      update "$folder"
      set tags = '$tag,' || tags
      where id == ?
    """,
      [id],
    );
    notifyListeners();
  }

  List<FavoriteItemWithFolderInfo> allComics() {
    var res = <FavoriteItemWithFolderInfo>[];
    for (final folder in folderNames) {
      var comics = _db.select("""
        select * from "$folder";
      """);
      res.addAll(
        comics.map(
          (element) =>
              FavoriteItemWithFolderInfo(FavoriteItem.fromRow(element), folder),
        ),
      );
    }
    return res;
  }

  bool existsFolder(String name) {
    // 「已阅」「失效」表不在 folderNames 枚举里，但对增删改查而言它们就是
    // 两张普通收藏夹表，直接放行。
    if (name == readFolderName || name == invalidFolderName) {
      return _getTablesWithDB().contains(name);
    }
    return folderNames.contains(name);
  }

  /// create a folder
  String createFolder(String name, [bool renameWhenInvalidName = false]) {
    if (name.isEmpty) {
      if (renameWhenInvalidName) {
        int i = 0;
        while (existsFolder(i.toString())) {
          i++;
        }
        name = i.toString();
      } else {
        throw "name is empty!";
      }
    }
    if (existsFolder(name)) {
      if (renameWhenInvalidName) {
        var prevName = name;
        int i = 0;
        while (existsFolder(i.toString())) {
          i++;
        }
        name = prevName + i.toString();
      } else {
        throw Exception("Folder is existing");
      }
    }
    _db.execute("""
      create table "$name"(
        id text,
        name TEXT,
        author TEXT,
        type int,
        tags TEXT,
        cover_path TEXT,
        time TEXT,
        display_order int,
        translated_tags TEXT,
        primary key (id, type)
      );
    """);
    notifyListeners();
    counts[name] = 0;
    return name;
  }

  void linkFolderToNetwork(String folder, String source, String networkFolder) {
    _db.execute(
      """
      insert or replace into folder_sync (folder_name, source_key, source_folder)
      values (?, ?, ?);
    """,
      [folder, source, networkFolder],
    );
  }

  bool isLinkedToNetworkFolder(
    String folder,
    String source,
    String networkFolder,
  ) {
    var res = _db.select(
      """
      select * from folder_sync
      where folder_name == ? and source_key == ? and source_folder == ?;
    """,
      [folder, source, networkFolder],
    );
    return res.isNotEmpty;
  }

  (String?, String?) findLinked(String folder) {
    var res = _db.select(
      """
      select * from folder_sync
      where folder_name == ?;
    """,
      [folder],
    );
    if (res.isEmpty) {
      return (null, null);
    }
    return (res.first["source_key"], res.first["source_folder"]);
  }

  bool comicExists(String folder, String id, ComicType type) {
    var res = _db.select(
      """
      select * from "$folder"
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    return res.isNotEmpty;
  }

  FavoriteItem getComic(String folder, String id, ComicType type) {
    var res = _db.select(
      """
      select * from "$folder"
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    if (res.isEmpty) {
      throw Exception("Comic not found");
    }
    return FavoriteItem.fromRow(res.first);
  }

  String _translateTags(List<String> tags) {
    var res = <String>[];
    for (var tag in tags) {
      var translated = tag.translateTagsToCN;
      if (translated != tag) {
        res.add(translated);
      }
    }
    return res.join(",");
  }

  /// add comic to a folder.
  /// return true if success, false if already exists
  bool addComic(
    String folder,
    FavoriteItem comic, [
    int? order,
    String? updateTime,
  ]) {
    if (!existsFolder(folder)) {
      throw Exception("Folder does not exists");
    }
    var res = _db.select(
      """
      select * from "$folder"
      where id == ? and type == ?;
    """,
      [comic.id, comic.type.value],
    );
    if (res.isNotEmpty) {
      return false;
    }
    var translatedTags = _translateTags(comic.tags);
    final params = [
      comic.id,
      comic.name,
      comic.author,
      comic.type.value,
      comic.tags.join(","),
      comic.coverPath,
      comic.time,
      translatedTags,
    ];
    if (order != null) {
      _db.execute(
        """
        insert into "$folder" (id, name, author, type, tags, cover_path, time, translated_tags, display_order)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?);
      """,
        [...params, order],
      );
    } else if (appdata.settings['newFavoriteAddTo'] == "end") {
      _db.execute(
        """
        insert into "$folder" (id, name, author, type, tags, cover_path, time, translated_tags, display_order)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?);
      """,
        [...params, maxValue(folder) + 1],
      );
    } else {
      _db.execute(
        """
        insert into "$folder" (id, name, author, type, tags, cover_path, time, translated_tags, display_order)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?);
      """,
        [...params, minValue(folder) - 1],
      );
    }
    if (updateTime != null) {
      var columns = _db.select("""
      pragma table_info("$folder");
    """);
      if (columns.any((element) => element["name"] == "last_update_time")) {
        _db.execute(
          """
          update "$folder"
          set last_update_time = ?
          where id == ? and type == ?;
        """,
          [updateTime, comic.id, comic.type.value],
        );
      }
    }
    if (counts[folder] == null) {
      counts[folder] = count(folder);
    } else {
      counts[folder] = counts[folder]! + 1;
    }
    // 一本漫画同一时间只能属于一个普通分类：
    // 收进新分类时，自动从其他普通分类移除（防止多分类共存）。
    var movedFromOther = false;
    for (var f in folderNames) {
      if (f == folder) continue;
      if (comicExists(f, comic.id, comic.type)) {
        movedFromOther = true;
        _db.execute(
          """
          delete from "$f"
          where id == ? and type == ?;
        """,
          [comic.id, comic.type.value],
        );
        counts[f] = count(f);
      }
    }
    // 「已阅」不计入全部收藏的 hashedIds（totalComics 只统计普通收藏夹）
    var hash = comic.id.hashCode ^ comic.type.value;
    if (folder == readFolderName) {
      _readHashedIds[hash] = (_readHashedIds[hash] ?? 0) + 1;
    } else {
      // 从其他分类移过来的话，hash 的总数不变（只是换了位置）。
      if (!movedFromOther) {
        _hashedIds[hash] = (_hashedIds[hash] ?? 0) + 1;
      }
      // 「已阅」「失效」独占：把漫画重新收藏进普通收藏夹时，自动移出它们。
      if (_readHashedIds.containsKey(hash)) {
        _db.execute(
          """
          delete from "$readFolderName"
          where id == ? and type == ?;
        """,
          [comic.id, comic.type.value],
        );
        counts[readFolderName] = count(readFolderName);
        _readHashedIds.remove(hash);
      }
      if (_invalidHashedIds.containsKey(hash)) {
        _db.execute(
          """
          delete from "$invalidFolderName"
          where id == ? and type == ?;
        """,
          [comic.id, comic.type.value],
        );
        counts[invalidFolderName] = count(invalidFolderName);
        _invalidHashedIds.remove(hash);
      }
    }
    notifyListeners();
    return true;
  }

  /// 取消收藏：从所有普通分类与「已阅」中同时移除该漫画。
  ///
  /// 详情页收藏按钮在已收藏状态下点击时调用——由于一本漫画只属于一个分类，
  /// 「取消」不需要区分来源，直接全局移除即可。
  void unfavorite(String id, ComicType type) {
    var hash = id.hashCode ^ type.value;
    _db.execute("BEGIN TRANSACTION");
    try {
      for (var folder in _getFolderNamesWithDB()) {
        _db.execute(
          """
          delete from "$folder"
          where id == ? and type == ?;
        """,
          [id, type.value],
        );
      }
      _db.execute(
        """
        delete from "$readFolderName"
        where id == ? and type == ?;
      """,
        [id, type.value],
      );
      _db.execute(
        """
        delete from "$invalidFolderName"
        where id == ? and type == ?;
      """,
        [id, type.value],
      );
    } catch (e) {
      Log.error("Unfavorite", e.toString());
      _db.execute("ROLLBACK");
      return;
    }
    _db.execute("COMMIT");
    _hashedIds.remove(hash);
    _readHashedIds.remove(hash);
    _invalidHashedIds.remove(hash);
    initCounts();
    notifyListeners();
  }

  void moveFavorite(
    String sourceFolder,
    String targetFolder,
    String id,
    ComicType type,
  ) {
    if (!existsFolder(sourceFolder)) {
      throw Exception("Source folder does not exist");
    }
    if (!existsFolder(targetFolder)) {
      throw Exception("Target folder does not exist");
    }

    var res = _db.select(
      """
    select * from "$targetFolder"
    where id == ? and type == ?;
  """,
      [id, type.value],
    );

    if (res.isNotEmpty) {
      return;
    }

    _db.execute(
      """
      insert into "$targetFolder" (id, name, author, type, tags, cover_path, time, display_order)
      select id, name, author, type, tags, cover_path, time, ?
      from "$sourceFolder"
      where id == ? and type == ?;
    """,
      [minValue(targetFolder) - 1, id, type.value],
    );

    _db.execute(
      """
    delete from "$sourceFolder"
    where id == ? and type == ?;
  """,
      [id, type.value],
    );

    counts[sourceFolder] = count(sourceFolder);
    counts[targetFolder] = count(targetFolder);
    refreshHashedIds();

    notifyListeners();
  }

  void batchMoveFavorites(
    String sourceFolder,
    String targetFolder,
    List<FavoriteItem> items,
  ) {
    if (!existsFolder(sourceFolder)) {
      throw Exception("Source folder does not exist");
    }
    if (!existsFolder(targetFolder)) {
      throw Exception("Target folder does not exist");
    }

    _db.execute("BEGIN TRANSACTION");
    var displayOrder = maxValue(targetFolder) + 1;
    try {
      for (var item in items) {
        _db.execute(
          """
          insert or ignore into "$targetFolder" (id, name, author, type, tags, cover_path, time, display_order)
          select id, name, author, type, tags, cover_path, time, ?
          from "$sourceFolder"
          where id == ? and type == ?;
        """,
          [displayOrder, item.id, item.type.value],
        );

        _db.execute(
          """
          delete from "$sourceFolder"
          where id == ? and type == ?;
        """,
          [item.id, item.type.value],
        );

        displayOrder++;
      }
      notifyListeners();
    } catch (e) {
      Log.error("Batch Move Favorites", e.toString());
      _db.execute("ROLLBACK");
      return;
    }
    _db.execute("COMMIT");

    // Update counts
    counts[targetFolder] = count(targetFolder);
    counts[sourceFolder] = count(sourceFolder);
    refreshHashedIds();

    notifyListeners();
  }

  void batchCopyFavorites(
    String sourceFolder,
    String targetFolder,
    List<FavoriteItem> items,
  ) {
    if (!existsFolder(sourceFolder)) {
      throw Exception("Source folder does not exist");
    }
    if (!existsFolder(targetFolder)) {
      throw Exception("Target folder does not exist");
    }

    _db.execute("BEGIN TRANSACTION");
    var displayOrder = maxValue(targetFolder) + 1;
    try {
      for (var item in items) {
        _db.execute(
          """
          insert or ignore into "$targetFolder" (id, name, author, type, tags, cover_path, time, display_order)
          select id, name, author, type, tags, cover_path, time, ?
          from "$sourceFolder"
          where id == ? and type == ?;
        """,
          [displayOrder, item.id, item.type.value],
        );

        displayOrder++;
      }
      notifyListeners();
    } catch (e) {
      Log.error("Batch Copy Favorites", e.toString());
      _db.execute("ROLLBACK");
      return;
    }

    _db.execute("COMMIT");

    // Update counts
    counts[targetFolder] = count(targetFolder);
    refreshHashedIds();

    notifyListeners();
  }

  /// 「已阅」数量。
  int readCount() => count(readFolderName);

  /// 「失效」数量。
  int invalidCount() => count(invalidFolderName);

  bool isRead(String id, ComicType type) =>
      comicExists(readFolderName, id, type);

  bool isInvalid(String id, ComicType type) =>
      comicExists(invalidFolderName, id, type);

  /// 该漫画被收藏到的所有收藏夹显示名（含「已阅」「失效」），用于详情页展示。
  List<String> getComicFolders(String id, ComicType type) {
    var res = <String>[];
    for (var folder in folderNames) {
      if (comicExists(folder, id, type)) {
        res.add(getFavoriteDataOrNull(folder)?.title ?? folder);
      }
    }
    if (isRead(id, type)) {
      res.add("Finished Reading".tl);
    }
    if (isInvalid(id, type)) {
      res.add("Invalid".tl);
    }
    return res;
  }

  /// 移入「已阅」：从**所有**普通收藏夹删除，同时加入已阅表。
  /// 「已阅」是独占状态，不允许同时存在于已阅和任何普通收藏夹。
  void moveToRead(String sourceFolder, FavoriteItem comic) {
    if (comicExists(readFolderName, comic.id, comic.type)) {
      deleteComicWithId(sourceFolder, comic.id, comic.type);
      return;
    }
    addComic(readFolderName, comic, maxValue(readFolderName) + 1);
    for (var folder in _getFolderNamesWithDB()) {
      if (comicExists(folder, comic.id, comic.type)) {
        deleteComicWithId(folder, comic.id, comic.type);
      }
    }
  }

  /// 批量移入「已阅」（同样从所有普通收藏夹移除）。
  void batchMoveToRead(String sourceFolder, List<FavoriteItem> items) {
    if (!existsFolder(sourceFolder)) {
      throw Exception("Source folder does not exist");
    }
    _db.execute("BEGIN TRANSACTION");
    var displayOrder = maxValue(readFolderName) + 1;
    var allFolders = _getFolderNamesWithDB();
    try {
      for (var item in items) {
        if (!comicExists(readFolderName, item.id, item.type)) {
          _db.execute(
            """
            insert into "$readFolderName" (id, name, author, type, tags, cover_path, time, translated_tags, display_order)
            select id, name, author, type, tags, cover_path, time, translated_tags, ?
            from "$sourceFolder"
            where id == ? and type == ?;
          """,
            [displayOrder, item.id, item.type.value],
          );
          displayOrder++;
        }
        for (var folder in allFolders) {
          _db.execute(
            """
            delete from "$folder"
            where id == ? and type == ?;
          """,
            [item.id, item.type.value],
          );
        }
      }
    } catch (e) {
      Log.error("Batch Move To Read", e.toString());
      _db.execute("ROLLBACK");
      return;
    }
    _db.execute("COMMIT");
    for (var folder in allFolders) {
      counts[folder] = count(folder);
    }
    counts[sourceFolder] = count(sourceFolder);
    counts[readFolderName] = count(readFolderName);
    refreshHashedIds();
    notifyListeners();
  }

  /// 从「已阅」移回普通收藏夹。
  void moveFromRead(String targetFolder, FavoriteItem comic) {
    moveFavorite(readFolderName, targetFolder, comic.id, comic.type);
  }

  /// delete a folder
  void deleteFolder(String name) {
    if (name == readFolderName || name == invalidFolderName) {
      throw Exception("Built-in folder cannot be deleted");
    }
    _db.execute("""
      drop table "$name";
    """);
    _db.execute(
      """
      delete from folder_order
      where folder_name == ?;
    """,
      [name],
    );
    counts.remove(name);
    refreshHashedIds();
    notifyListeners();
  }

  void deleteComicWithId(String folder, String id, ComicType type) {
    LocalFavoriteImageProvider.delete(id, type.value);
    _db.execute(
      """
      delete from "$folder"
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
    if (counts[folder] != null) {
      counts[folder] = counts[folder]! - 1;
    } else {
      counts[folder] = count(folder);
    }
    if (folder == readFolderName) {
      _reduceReadHashedId(id, type.value);
    } else if (folder == invalidFolderName) {
      _reduceInvalidHashedId(id, type.value);
    } else {
      reduceHashedId(id, type.value);
    }
    notifyListeners();
  }

  void batchDeleteComics(String folder, List<FavoriteItem> comics) {
    _db.execute("BEGIN TRANSACTION");
    try {
      for (var comic in comics) {
        LocalFavoriteImageProvider.delete(comic.id, comic.type.value);
        _db.execute(
          """
          delete from "$folder"
          where id == ? and type == ?;
        """,
          [comic.id, comic.type.value],
        );
      }
      if (counts[folder] != null) {
        counts[folder] = counts[folder]! - comics.length;
      } else {
        counts[folder] = count(folder);
      }
    } catch (e) {
      Log.error("Batch Delete Comics", e.toString());
      _db.execute("ROLLBACK");
      return;
    }
    _db.execute("COMMIT");
    for (var comic in comics) {
      if (folder == readFolderName) {
        _reduceReadHashedId(comic.id, comic.type.value);
      } else if (folder == invalidFolderName) {
        _reduceInvalidHashedId(comic.id, comic.type.value);
      } else {
        reduceHashedId(comic.id, comic.type.value);
      }
    }
    notifyListeners();
  }

  void batchDeleteComicsInAllFolders(List<ComicID> comics) {
    _db.execute("BEGIN TRANSACTION");
    var folderNames = _getFolderNamesWithDB();
    try {
      for (var comic in comics) {
        LocalFavoriteImageProvider.delete(comic.id, comic.type.value);
        for (var folder in folderNames) {
          _db.execute(
            """
            delete from "$folder"
            where id == ? and type == ?;
          """,
            [comic.id, comic.type.value],
          );
        }
      }
    } catch (e) {
      Log.error("Batch Delete Comics in All Folders", e.toString());
      _db.execute("ROLLBACK");
      return;
    }
    initCounts();
    _db.execute("COMMIT");
    for (var comic in comics) {
      var hash = comic.id.hashCode ^ comic.type.value;
      _hashedIds.remove(hash);
    }
    notifyListeners();
  }

  /// 这条收藏还能不能打开。
  ///
  /// 两种情况算失效：
  /// - 本地漫画：本地库里已经没有它了（目录被删、被「删除文件」清掉）；
  /// - 网络漫画：它来自的那个源已经不存在了（源被删/改了 key）。
  ///
  /// 注意：这里**不会**去网络上探活。给几百条收藏逐个发请求既慢又容易被
  /// 风控，而「源没了」已经覆盖了绝大多数真正打不开的情况。
  bool _isInvalidItem(FavoriteItem item) {
    if (item.type == ComicType.local) {
      return LocalManager().find(item.id, item.type) == null;
    }
    final source = item.type.comicSource;
    if (source == null) {
      // 源被卸载/删掉了：这本书没有任何地方能打开。
      return true;
    }
    // 源还在，但源检测刚测出「失败」（超时、403、站挂了）。以前这里只看源
    // 对象在不在，于是这些源下的收藏一条也挪不动——用户在源检测页明明看到
    // 是红的，点「一键清理失效」却提示「没有失效的漫画」。
    //
    // 结果按 key 落盘（见 SourceHealthService），重启后依然有效；源恢复正常
    // 并重新检测通过后，这些作品可以在失效页「重新检测失效」里原路退回。
    return SourceHealthService.instance.hasFailed(source.key);
  }

  /// 把失效的收藏从各分类里挪进「失效」表。
  ///
  /// 和 [removeInvalid] 的区别就在「挪」和「删」：失效不代表用户想丢掉，
  /// 很多是源临时下线或者本地文件被清理工具扫走了，留着还能认出来。
  /// 返回移动的条数。
  Future<int> cleanupInvalid() async {
    if (!existsFolder(invalidFolderName)) {
      return 0;
    }
    var moved = 0;
    _db.execute("BEGIN TRANSACTION");
    try {
      var displayOrder = maxValue(invalidFolderName) + 1;
      for (var folder in _getFolderNamesWithDB()) {
        var rows = _db.select("""
          select * from "$folder";
        """);
        for (var row in rows) {
          var item = FavoriteItem.fromRow(row);
          if (!_isInvalidItem(item)) {
            continue;
          }
          if (!comicExists(invalidFolderName, item.id, item.type)) {
            _db.execute(
              """
              insert or ignore into "$invalidFolderName"
                (id, name, author, type, tags, cover_path, time, translated_tags, display_order, origin)
              select id, name, author, type, tags, cover_path, time, translated_tags, ?, ?
              from "$folder"
              where id == ? and type == ?;
            """,
              [displayOrder, folder, item.id, item.type.value],
            );
            displayOrder++;
          } else {
            // 之前从别的分类挪进来过（origin 那是旧记录）：补一次来源，
            // 否则「源恢复了移回去」只能退回默认分类。
            _db.execute(
              """
              update "$invalidFolderName"
              set origin = ?
              where id == ? and type == ? and origin is null;
            """,
              [folder, item.id, item.type.value],
            );
          }
          _db.execute(
            """
            delete from "$folder"
            where id == ? and type == ?;
          """,
            [item.id, item.type.value],
          );
          moved++;
        }
      }
    } catch (e, s) {
      Log.error("Cleanup Invalid", "failed: $e", s);
      _db.execute("ROLLBACK");
      return 0;
    }
    _db.execute("COMMIT");
    initCounts();
    notifyListeners();
    return moved;
  }

  /// 把「失效」里已经恢复的收藏退回原分类。
  ///
  /// 失效的原因可能是暂时的：源被删了又装回来、本地目录被清理工具扫走之后
  /// 用户重新下载了同一本。用户在失效页点一下重新检测，能打开的就原路退回
  /// ——没有 origin（老数据 / 原来那个分类被删了）就退回第一个普通分类。
  ///
  /// 返回恢复的条数。
  Future<int> restoreValidInvalid({String? fallbackFolder}) async {
    if (!existsFolder(invalidFolderName)) {
      return 0;
    }
    var folders = _getFolderNamesWithDB();
    if (folders.isEmpty) {
      return 0;
    }
    var targets = <FavoriteItem, String>{};
    for (var item in getFolderComics(invalidFolderName)) {
      if (_isInvalidItem(item)) {
        continue;
      }
      var origin = _originOf(item);
      var target = (origin != null && folders.contains(origin))
          ? origin
          : (fallbackFolder != null && folders.contains(fallbackFolder)
              ? fallbackFolder
              : folders.first);
      targets[item] = target;
    }
    if (targets.isEmpty) {
      return 0;
    }
    _db.execute("BEGIN TRANSACTION");
    try {
      for (var entry in targets.entries) {
        _db.execute(
          """
          insert or ignore into "${entry.value}"
            (id, name, author, type, tags, cover_path, time, translated_tags, display_order)
          select id, name, author, type, tags, cover_path, time, translated_tags, ?
          from "$invalidFolderName"
          where id == ? and type == ?;
        """,
          [minValue(entry.value) - 1, entry.key.id, entry.key.type.value],
        );
        _db.execute(
          """
          delete from "$invalidFolderName"
          where id == ? and type == ?;
        """,
          [entry.key.id, entry.key.type.value],
        );
      }
    } catch (e, s) {
      Log.error("Restore Invalid", "failed: $e", s);
      _db.execute("ROLLBACK");
      return 0;
    }
    _db.execute("COMMIT");
    initCounts();
    notifyListeners();
    return targets.length;
  }

  /// 一条失效记录是从哪个分类挪进来的。
  String? _originOf(FavoriteItem item) {
    try {
      var res = _db.select(
        'select origin from "$invalidFolderName" where id == ? and type == ?;',
        [item.id, item.type.value],
      );
      if (res.isEmpty) {
        return null;
      }
      var value = res.first["origin"];
      return value is String && value.isNotEmpty ? value : null;
    } catch (_) {
      return null;
    }
  }

  Future<int> removeInvalid() async {
    int count = 0;
    await Future.microtask(() {
      var all = <FavoriteItemWithFolderInfo>[
        ...allComics(),
        for (var comic in getFolderComics(invalidFolderName))
          FavoriteItemWithFolderInfo(comic, invalidFolderName),
      ];
      for (var c in all) {
        if (_isInvalidItem(c)) {
          deleteComicWithId(c.folder, c.id, c.type);
          count++;
        }
      }
    });
    return count;
  }

  Future<void> clearAll() async {
    _db.dispose();
    File("${App.dataPath}/local_favorite.db").deleteSync();
    await init();
  }

  void reorder(List<FavoriteItem> newFolder, String folder) async {
    if (!existsFolder(folder)) {
      throw Exception("Failed to reorder: folder not found");
    }
    _db.execute("BEGIN TRANSACTION");
    try {
      for (int i = 0; i < newFolder.length; i++) {
        _db.execute(
          """
          update "$folder"
          set display_order = ?
          where id == ? and type == ?;
        """,
          [i, newFolder[i].id, newFolder[i].type.value],
        );
      }
    } catch (e) {
      Log.error("Reorder", e.toString());
      _db.execute("ROLLBACK");
      return;
    }
    _db.execute("COMMIT");
    notifyListeners();
  }

  void rename(String before, String after) {
    if (existsFolder(after)) {
      throw "Name already exists!";
    }
    if (after.contains('"')) {
      throw "Invalid name";
    }
    _db.execute("""
      ALTER TABLE "$before"
      RENAME TO "$after";
    """);
    _db.execute(
      """
      update folder_order
      set folder_name = ?
      where folder_name == ?;
    """,
      [after, before],
    );
    _db.execute(
      """
      update folder_sync
      set folder_name = ?
      where folder_name == ?;
    """,
      [after, before],
    );
    counts[after] = counts[before] ?? 0;
    counts.remove(before);
    notifyListeners();
  }

  void onRead(String id, ComicType type) async {
    if (appdata.settings['moveFavoriteAfterRead'] == "none") {
      markAsRead(id, type);
      return;
    }
    var followUpdatesFolder = appdata.settings['followUpdatesFolder'];
    for (final folder in folderNames) {
      var rows = _db.select(
        """
        select * from "$folder"
        where id == ? and type == ?;
      """,
        [id, type.value],
      );
      if (rows.isNotEmpty) {
        var newTime = DateTime.now()
            .toIso8601String()
            .replaceFirst("T", " ")
            .substring(0, 19);
        String updateLocationSql = "";
        if (appdata.settings['moveFavoriteAfterRead'] == "end") {
          int maxValue =
              _db.select("""
            SELECT MAX(display_order) AS max_value
            FROM "$folder";
          """).firstOrNull?["max_value"] ??
              0;
          updateLocationSql = "display_order = ${maxValue + 1},";
        } else if (appdata.settings['moveFavoriteAfterRead'] == "start") {
          int minValue =
              _db.select("""
            SELECT MIN(display_order) AS min_value
            FROM "$folder";
          """).firstOrNull?["min_value"] ??
              0;
          updateLocationSql = "display_order = ${minValue - 1},";
        }
        _db.execute(
          """
            UPDATE "$folder"
            SET 
              $updateLocationSql
              ${followUpdatesFolder == folder ? "has_new_update = 0," : ""}
              time = ?
            WHERE id == ? and type == ?;
          """,
          [newTime, id, type.value],
        );
        if (followUpdatesFolder == folder) {
          updateFollowUpdatesUI();
        }
      }
    }
    notifyListeners();
  }

  List<FavoriteItem> searchInFolder(String folder, String keyword) {
    var keywordList = keyword.split(" ");
    keyword = keywordList.first;
    keyword = "%$keyword%";
    var res = _db.select(
      """
      SELECT * FROM "$folder" 
      WHERE name LIKE ? OR author LIKE ? OR tags LIKE ? OR translated_tags LIKE ?;
    """,
      [keyword, keyword, keyword, keyword],
    );
    var comics = res.map((e) => FavoriteItem.fromRow(e)).toList();
    bool test(FavoriteItem comic, String keyword) {
      if (comic.name.contains(keyword)) {
        return true;
      } else if (comic.author.contains(keyword)) {
        return true;
      } else if (comic.tags.any((element) => element.contains(keyword))) {
        return true;
      }
      return false;
    }

    for (var i = 1; i < keywordList.length; i++) {
      comics = comics
          .where((element) => test(element, keywordList[i]))
          .toList();
    }
    return comics;
  }

  List<FavoriteItem> search(String keyword) {
    var keywordList = keyword.split(" ");
    keyword = keywordList.first;
    var comics = <FavoriteItem>{};
    for (var table in folderNames) {
      keyword = "%$keyword%";
      var res = _db.select(
        """
        SELECT * FROM "$table" 
        WHERE name LIKE ? OR author LIKE ? OR tags LIKE ? OR translated_tags LIKE ?;
      """,
        [keyword, keyword, keyword, keyword],
      );
      for (var comic in res) {
        comics.add(FavoriteItem.fromRow(comic));
      }
      if (comics.length > 200) {
        break;
      }
    }

    bool test(FavoriteItem comic, String keyword) {
      keyword = keyword.trim();
      if (keyword.isEmpty) {
        return true;
      }
      if (comic.name.contains(keyword)) {
        return true;
      } else if (comic.author.contains(keyword)) {
        return true;
      } else if (comic.tags.any((element) => element.contains(keyword))) {
        return true;
      }
      return false;
    }

    return comics.where((element) {
      for (var i = 1; i < keywordList.length; i++) {
        if (!test(element, keywordList[i])) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  void editTags(String id, String folder, List<String> tags) {
    _db.execute(
      """
        update "$folder"
        set tags = ?
        where id == ?;
      """,
      [tags.join(","), id],
    );
    notifyListeners();
  }

  bool isExist(String id, ComicType type) {
    var hash = id.hashCode ^ type.value;
    // 收藏标识对「已阅」「失效」同样生效：进了这两个内置分类的漫画依然
    // 算已收藏，详情页的收藏按钮才不会显示成「未收藏」。
    return _hashedIds.containsKey(hash) ||
        _readHashedIds.containsKey(hash) ||
        _invalidHashedIds.containsKey(hash);
  }

  void updateInfo(String folder, FavoriteItem comic, [bool notify = true]) {
    _db.execute(
      """
      update "$folder"
      set name = ?, author = ?, cover_path = ?, tags = ?
      where id == ? and type == ?;
    """,
      [
        comic.name,
        comic.author,
        comic.coverPath,
        comic.tags.join(","),
        comic.id,
        comic.type.value,
      ],
    );
    if (notify) {
      notifyListeners();
    }
  }

  String folderToJson(String folder) {
    var res = _db.select("""
      select * from "$folder";
    """);
    return jsonEncode({
      "info": "Generated by Venera",
      "name": folder,
      "comics": res.map((e) => FavoriteItem.fromRow(e).toJson()).toList(),
    });
  }

  void fromJson(String json) {
    var data = jsonDecode(json);
    var folder = data["name"];
    if (folder == null || folder is! String) {
      throw "Invalid data";
    }
    if (existsFolder(folder)) {
      int i = 0;
      while (existsFolder("$folder($i)")) {
        i++;
      }
      folder = "$folder($i)";
    }
    createFolder(folder);
    for (var comic in data["comics"]) {
      try {
        addComic(folder, FavoriteItem.fromJson(comic));
      } catch (e) {
        Log.error("Import Data", e.toString());
      }
    }
  }

  void prepareTableForFollowUpdates(String table, [bool clearData = true]) {
    // check if the table has the column "last_update_time" "has_new_update" "last_check_time"
    var columns = _db.select("""
      pragma table_info("$table");
    """);
    if (!columns.any((element) => element["name"] == "last_update_time")) {
      _db.execute("""
        alter table "$table"
        add column last_update_time TEXT;
      """);
    }
    if (!columns.any((element) => element["name"] == "has_new_update")) {
      _db.execute("""
        alter table "$table"
        add column has_new_update int;
      """);
    }
    if (clearData) {
      _db.execute("""
        update "$table"
        set has_new_update = 0;
      """);
    }
    if (!columns.any((element) => element["name"] == "last_check_time")) {
      _db.execute("""
        alter table "$table"
        add column last_check_time int;
      """);
    }
  }

  void updateUpdateTime(
    String folder,
    String id,
    ComicType type,
    String updateTime,
  ) {
    var oldTime = _db
        .select(
          """
      select last_update_time from "$folder"
      where id == ? and type == ?;
    """,
          [id, type.value],
        )
        .first['last_update_time'];
    var hasNewUpdate = oldTime != updateTime;
    _db.execute(
      """
      update "$folder"
      set last_update_time = ?, has_new_update = ?, last_check_time = ?
      where id == ? and type == ?;
    """,
      [
        updateTime,
        hasNewUpdate ? 1 : 0,
        DateTime.now().millisecondsSinceEpoch,
        id,
        type.value,
      ],
    );
  }

  void updateCheckTime(String folder, String id, ComicType type) {
    _db.execute(
      """
      update "$folder"
      set last_check_time = ?
      where id == ? and type == ?;
    """,
      [DateTime.now().millisecondsSinceEpoch, id, type.value],
    );
  }

  int countUpdates(String folder) {
    return _db.select("""
      select count(*) as c from "$folder"
      where has_new_update == 1;
    """).first['c'];
  }

  List<FavoriteItemWithUpdateInfo> getUpdates(String folder) {
    if (!existsFolder(folder)) {
      return [];
    }
    var res = _db.select("""
      select * from "$folder"
      where has_new_update == 1;
    """);
    return res
        .map(
          (e) => FavoriteItemWithUpdateInfo(
            FavoriteItem.fromRow(e),
            e['last_update_time'],
            e['has_new_update'] == 1,
            e['last_check_time'],
          ),
        )
        .toList();
  }

  List<FavoriteItemWithUpdateInfo> getComicsWithUpdatesInfo(String folder) {
    if (!existsFolder(folder)) {
      return [];
    }
    var res = _db.select("""
      select * from "$folder";
    """);
    return res
        .map(
          (e) => FavoriteItemWithUpdateInfo(
            FavoriteItem.fromRow(e),
            e['last_update_time'],
            e['has_new_update'] == 1,
            e['last_check_time'],
          ),
        )
        .toList();
  }

  void markAsRead(String id, ComicType type) {
    var folder = appdata.settings['followUpdatesFolder'];
    if (!existsFolder(folder)) {
      return;
    }
    _db.execute(
      """
      update "$folder"
      set has_new_update = 0
      where id == ? and type == ?;
    """,
      [id, type.value],
    );
  }

  void close() {
    _db.dispose();
  }

  void notifyChanges() {
    notifyListeners();
  }
}
