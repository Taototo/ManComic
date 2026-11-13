import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:ffi' as ffi;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/image_provider/image_favorites_provider.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/channel.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';

import 'app.dart';
import 'consts.dart';

part "image_favorites.dart";

typedef HistoryType = ComicType;

abstract mixin class HistoryMixin {
  String get title;

  String? get subTitle;

  String get cover;

  String get id;

  int? get maxPage => null;

  HistoryType get historyType;
}

class History implements Comic {
  HistoryType type;

  DateTime time;

  @override
  String title;

  @override
  String subtitle;

  @override
  String cover;

  /// index of chapters. 1-based.
  int ep;

  /// index of pages. 1-based.
  int page;

  /// index of chapter groups. 1-based.
  /// If [group] is not null, [ep] is the index of chapter in the group.
  int? group;

  @override
  String id;

  /// readEpisode is a set of episode numbers that have been read.
  /// For normal chapters, it is a set of chapter numbers.
  /// For grouped chapters, it is a set of strings in the format of "group_number-chapter_number".
  /// 1-based.
  Set<String> readEpisode;

  @override
  int? maxPage;

  History.fromModel(
      {required HistoryMixin model,
      required this.ep,
      required this.page,
      this.group,
      Set<String>? readChapters,
      DateTime? time})
      : type = model.historyType,
        title = model.title,
        subtitle = model.subTitle ?? '',
        cover = model.cover,
        id = model.id,
        readEpisode = readChapters ?? <String>{},
        time = time ?? DateTime.now();

  History.fromMap(Map<String, dynamic> map)
      : type = HistoryType(map["type"]),
        time = DateTime.fromMillisecondsSinceEpoch(map["time"]),
        title = map["title"],
        subtitle = map["subtitle"],
        cover = map["cover"],
        ep = map["ep"],
        page = map["page"],
        id = map["id"],
        readEpisode = Set<String>.from(
            (map["readEpisode"] as List<dynamic>?)?.toSet() ??
                const <String>{}),
        maxPage = map["max_page"];

  @override
  String toString() {
    return 'History{type: $type, time: $time, title: $title, subtitle: $subtitle, cover: $cover, ep: $ep, page: $page, id: $id}';
  }

  History.fromRow(Row row)
      : type = HistoryType(row["type"]),
        time = DateTime.fromMillisecondsSinceEpoch(row["time"]),
        title = row["title"],
        subtitle = row["subtitle"],
        cover = row["cover"],
        ep = row["ep"],
        page = row["page"],
        id = row["id"],
        readEpisode = Set<String>.from((row["readEpisode"] as String)
            .split(',')
            .where((element) => element != "")),
        maxPage = row["max_page"],
        group = row["chapter_group"];

  @override
  bool operator ==(Object other) {
    return other is History && type == other.type && id == other.id;
  }

  @override
  int get hashCode => Object.hash(id, type);

  @override
  String get description {
    var res = "";
    if (group != null){
      res += "${"Group @group".tlParams({
        "group": group!,
      })} - ";
    }
    if (ep >= 1) {
      res += "Chapter @ep".tlParams({
        "ep": ep,
      });
    }
    if (page >= 1) {
      if (ep >= 1) {
        res += " - ";
      }
      res += "Page @page".tlParams({
        "page": page,
      });
    }
    return res;
  }

  @override
  String? get favoriteId => null;

  @override
  String? get language => null;

  @override
  String get sourceKey => type == ComicType.local
      ? 'local'
      : type.comicSource?.key ?? "Unknown:${type.value}";

  @override
  double? get stars => null;

  @override
  List<String>? get tags => null;

  @override
  Map<String, dynamic> toJson() {
    throw UnimplementedError();
  }
}

class HistoryManager with ChangeNotifier {
  static HistoryManager? cache;

  HistoryManager.create();

  factory HistoryManager() =>
      cache == null ? (cache = HistoryManager.create()) : cache!;

  late Database _db;

  int get length => _db.select(
    "select count(*) from history where coalesce(cleared, 0) = 0;",
  ).first[0] as int;

  /// Cache of history ids. Improve the performance of find operation.
  Map<String, bool>? _cachedHistoryIds;

  /// Cache records recently modified by the app. Improve the performance of listeners.
  final cachedHistories = <String, History>{};

  bool isInitialized = false;

  Future<void> init() async {
    if (isInitialized) {
      return;
    }
    _db = sqlite3.open("${App.dataPath}/history.db");

    _db.execute(_createHistoryTableSql);

    var columns = _db.select("PRAGMA table_info(history);");
    if (!columns.any((element) => element["name"] == "chapter_group")) {
      _db.execute("alter table history add column chapter_group int;");
    }
    // `cleared` = 「从历史列表里清掉了，但进度还在」。
    //
    // 以前「清除历史」是 `delete from history`，而这一张表同时存着读到第几
    // 话第几页、哪些话读过——用户清个列表，进度、已读标记、「继续阅读」全
    // 跟着消失。历史是「我看过什么」的流水，进度是进度，两件事得分开。
    if (!columns.any((element) => element["name"] == "cleared")) {
      _db.execute("alter table history add column cleared int default 0;");
    }

    _migratePrimaryKey();

    notifyListeners();
    ImageFavoriteManager().init();
    isInitialized = true;
  }

  /// 主键必须是 `(id, type)`。
  ///
  /// 老库只有 `id text primary key`，而接口层一直按 `(id, type)` 找。本地导入
  /// 书的 id 是 `"1"`、`"2"`…，网络源也常见 `"1"`/`"12345"`，两边撞上就
  /// `insert or replace` 互相顶掉：读一本会改掉另一本的进度，删一条会「删了
  /// 还在」。DDL 走一次重命名 + 建新表 + 搬数据，单表几百行，启动时几十毫秒。
  void _migratePrimaryKey() {
    var tableInfo = _db.select(
      "select sql from sqlite_master where type = 'table' and name = 'history';",
    );
    var createSql = tableInfo.isEmpty
        ? ""
        : (tableInfo.first["sql"] as String? ?? "");
    var normalized = createSql.toLowerCase().replaceAll(RegExp(r"\s+"), " ");
    if (normalized.isEmpty ||
        normalized.contains("primary key (id, type)") ||
        normalized.contains("primary key(id, type)")) {
      return;
    }
    _db.execute("alter table history rename to history_legacy;");
    _db.execute(_createHistoryTableSql);
    // 显式列名，别用 `select *`：老库的列顺序不保证和当前一致。
    _db.execute("""
        insert or replace into history
          (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group, cleared)
        select id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group, cleared
        from history_legacy;
      """);
    _db.execute("drop table history_legacy;");
    Log.info("History", "Rebuilt history table with (id, type) primary key");
  }

  static const _createHistoryTableSql = """
        create table if not exists history  (
          id text,
          title text,
          subtitle text,
          cover text,
          time int,
          type int,
          ep int,
          page int,
          readEpisode text,
          max_page int,
          chapter_group int,
          cleared int default 0,
          primary key (id, type)
        );
      """;

  static String _cacheKey(String id, int type) => "$type\u0000$id";

  /// 每次写进度都把 `cleared` 归零：用户又打开这本书了，它就该重新回到
  /// 历史列表里（进度本来就是从这里恢复的，列表和进度不能各说各话）。
  static const _insertHistorySql = """
        insert or replace into history (id, title, subtitle, cover, time, type, ep, page, readEpisode, max_page, chapter_group, cleared)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0);
      """;

  static Future<void> _addHistoryAsync(int dbAddr, History newItem) {
    return Isolate.run(() {
      var db = sqlite3.fromPointer(ffi.Pointer.fromAddress(dbAddr));
      db.execute(_insertHistorySql, [
        newItem.id,
        newItem.title,
        newItem.subtitle,
        newItem.cover,
        newItem.time.millisecondsSinceEpoch,
        newItem.type.value,
        newItem.ep,
        newItem.page,
        newItem.readEpisode.join(','),
        newItem.maxPage,
        newItem.group
      ]);
    });
  }

  bool _haveAsyncTask = false;

  /// Create a isolate to add history to prevent blocking the UI thread.
  Future<void> addHistoryAsync(History newItem) async {
    while (_haveAsyncTask) {
      await Future.delayed(Duration(milliseconds: 20));
    }

    _haveAsyncTask = true;
    try {
      await _addHistoryAsync(_db.handle.address, newItem);
    } finally {
      // 必须放 finally：写库抛一次（库被关、磁盘满、导入数据换了句柄）之后，
      // 这个标志会永远停在 true，后面每次 addHistoryAsync 都在上面的 while
      // 里无限等待——本次运行内所有阅读进度都不再落盘。
      _haveAsyncTask = false;
    }
    if (_cachedHistoryIds == null) {
      updateCache();
    } else {
      _cachedHistoryIds![_cacheKey(newItem.id, newItem.type.value)] = true;
    }
    cachedHistories[_cacheKey(newItem.id, newItem.type.value)] = newItem;
    if (cachedHistories.length > 10) {
      cachedHistories.remove(cachedHistories.keys.first);
    }
    notifyListeners();
  }

  /// add history. if exists, update time.
  ///
  /// This function would be called when user start reading.
  void addHistory(History newItem) {
    _db.execute(_insertHistorySql, [
      newItem.id,
      newItem.title,
      newItem.subtitle,
      newItem.cover,
      newItem.time.millisecondsSinceEpoch,
      newItem.type.value,
      newItem.ep,
      newItem.page,
      newItem.readEpisode.join(','),
      newItem.maxPage,
      newItem.group
    ]);
    if (_cachedHistoryIds == null) {
      updateCache();
    } else {
      _cachedHistoryIds![_cacheKey(newItem.id, newItem.type.value)] = true;
    }
    cachedHistories[_cacheKey(newItem.id, newItem.type.value)] = newItem;
    if (cachedHistories.length > 10) {
      cachedHistories.remove(cachedHistories.keys.first);
    }
    notifyListeners();
  }

  /// 清空历史列表。
  ///
  /// 默认**只清列表**：`cleared = 1` 把记录从列表、最近阅读、计数里藏起来，
  /// 但读到第几话第几页、哪些话读过都还在。以前直接 `delete from history`，
  /// 用户点一下「清除历史」，进度、已读标记、「继续阅读」全没了——历史只是
  /// 「我看过什么」，不是进度本身。
  ///
  /// [withProgress] 为真才是真正的「忘掉」：连进度一起删，退回没读过的状态。
  void clearHistory({bool withProgress = false}) {
    if (withProgress) {
      _db.execute("delete from history;");
    } else {
      _db.execute("update history set cleared = 1;");
    }
    updateCache();
    notifyListeners();
  }

  /// 清掉「没收藏的那些」的历史列表条目，收藏着的留着。
  ///
  /// 和 [clearHistory] 一样，默认保留进度；[withProgress] 为真时连进度一起删。
  void clearUnfavoritedHistory({bool withProgress = false}) {
    _db.execute('BEGIN TRANSACTION;');
    try {
      final idAndTypes = _db.select("""
      select id, type from history;
    """);
      for (var element in idAndTypes) {
        final id = element["id"] as String;
        final type = ComicType(element["type"] as int);
        if (!LocalFavoritesManager().isExist(id, type)) {
          if (withProgress) {
            _db.execute("""
          delete from history
          where id == ? and type == ?;
        """, [id, type.value]);
          } else {
            _db.execute("""
          update history set cleared = 1
          where id == ? and type == ?;
        """, [id, type.value]);
          }
        }
      }
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    updateCache();
    notifyListeners();
  }

  /// 把一条历史从列表里移出，**保留阅读进度**。
  ///
  /// 单条删除和整页清空必须是同一套语义：用户删的是「列表里的这一行」，不
  /// 是「我读过这本书」。真要连进度一起清，用 [forget]。
  void hide(String id, ComicType type) {
    _db.execute("""
      update history set cleared = 1
      where id == ? and type == ?;
    """, [id, type.value]);
    notifyListeners();
  }

  void hideAll(List<ComicID> histories) {
    if (histories.isEmpty) {
      return;
    }
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (var history in histories) {
        _db.execute("""
          update history set cleared = 1
          where id == ? and type == ?;
        """, [history.id, history.type.value]);
      }
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    notifyListeners();
  }

  /// 真正忘掉这本书：列表、阅读进度、已读章节标记一起删。
  ///
  /// 删漫画（本地书连带文件）时用它——书都不在了，留一条进度只会让以后重新
  /// 下载的那本「一打开就跳到第 40 话」。[forget] 是它的另一个名字，语义
  /// 比 `remove` 直白，新的调用点用它。
  void remove(String id, ComicType type) => forget(id, type);

  void forget(String id, ComicType type) {
    _db.execute("""
      delete from history
      where id == ? and type == ?;
    """, [id, type.value]);
    updateCache();
    notifyListeners();
  }

  void updateCache() {
    _cachedHistoryIds = {};
    var res = _db.select("""
        select id, type from history;
      """);
    for (var element in res) {
      // 缓存键必须带 type：只按 id 索引时，本地书和网络书 id 相同会让
      // find() 直接命中对方那条记录（进度串书）。
      _cachedHistoryIds![_cacheKey(
        element["id"] as String,
        element["type"] as int,
      )] = true;
    }
    for (var key in cachedHistories.keys.toList()) {
      if (!_cachedHistoryIds!.containsKey(key)) {
        cachedHistories.remove(key);
      }
    }
  }

  History? find(String id, ComicType type) {
    if (_cachedHistoryIds == null) {
      updateCache();
    }
    var key = _cacheKey(id, type.value);
    if (!_cachedHistoryIds!.containsKey(key)) {
      return null;
    }
    if (cachedHistories.containsKey(key)) {
      return cachedHistories[key];
    }

    var res = _db.select("""
      select * from history
      where id == ? and type == ?;
    """, [id, type.value]);
    if (res.isEmpty) {
      return null;
    }
    return History.fromRow(res.first);
  }

  /// 列表、最近阅读、计数一律只看「没被清掉」的那些；[find] 不看 `cleared`
  /// ——进度还在，详情页/阅读器当然还要能接着读。
  static const _visible = "coalesce(cleared, 0) = 0";

  List<History> getAll() {
    var res = _db.select("""
      select * from history
      where $_visible
      order by time DESC;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  /// 获取最近阅读的漫画
  List<History> getRecent() {
    var res = _db.select("""
      select * from history
      where $_visible
      order by time DESC
      limit 20;
    """);
    return res.map((element) => History.fromRow(element)).toList();
  }

  /// 获取历史记录的数量
  int count() {
    var res = _db.select("""
      select count(*) from history where $_visible;
    """);
    return res.first[0] as int;
  }

  void close() {
    isInitialized = false;
    _db.dispose();
  }

  void batchDeleteHistories(List<ComicID> histories) {
    if (histories.isEmpty) return;
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (var history in histories) {
        _db.execute("""
          delete from history
          where id == ? and type == ?;
        """, [history.id, history.type.value]);
      }
      _db.execute('COMMIT;');
    } catch (e) {
      _db.execute('ROLLBACK;');
      rethrow;
    }
    updateCache();
    notifyListeners();
  }

  /// Refresh history info from comic source.
  /// Fetches the latest cover, title and subtitle from the source.
  /// Keeps the reading progress (ep, page, etc.).
  Future<bool> refreshHistoryInfo(History history) async {
    if (history.sourceKey == 'local') {
      // Local comics don't need refresh
      return false;
    }

    return await _refreshSingleHistory(history);
  }

  /// Internal method to refresh a single history
  /// Retries up to 3 times on failure with 2 second delay between retries
  Future<bool> _refreshSingleHistory(History history) async {
    var comicSource = ComicSource.find(history.sourceKey);
    if (comicSource == null || comicSource.loadComicInfo == null) {
      return false;
    }

    int retries = 3;
    while (true) {
      try {
        var res = await comicSource.loadComicInfo!(history.id);
        if (res.error) {
          await Future.delayed(const Duration(seconds: 2));
          retries--;
          if (retries == 0) {
            return false;
          }
          continue;
        }

        var comicDetails = res.data;
        // Update history info while keeping reading progress
        var updatedHistory = History.fromMap({
          'type': history.type.value,
          'time': history.time.millisecondsSinceEpoch,
          'title': comicDetails.title,
          'subtitle': comicDetails.subTitle ?? '',
          'cover': comicDetails.cover,
          'ep': history.ep,
          'page': history.page,
          'id': history.id,
          'readEpisode': history.readEpisode.toList(),
          'max_page': history.maxPage,
        });
        updatedHistory.group = history.group;

        addHistory(updatedHistory);
        return true;
      } catch (e, s) {
        Log.error("History", "Exception while refreshing history info: $e\n$s");
        await Future.delayed(const Duration(seconds: 2));
        retries--;
        if (retries == 0) {
          return false;
        }
      }
    }
  }

  /// Refresh all histories from comic sources.
  /// Returns a stream with progress updates.
  /// From e0ea449c.
  Stream<RefreshProgress> refreshAllHistoriesStream() {
    var controller = StreamController<RefreshProgress>();
    _refreshAllHistoriesBase(controller);
    return controller.stream;
  }

  void _refreshAllHistoriesBase(
    StreamController<RefreshProgress> controller,
  ) async {
    var histories = getAll();
    int total = histories.length;
    int current = 0;
    int success = 0;
    int failed = 0;
    int skipped = 0;

    controller.add(RefreshProgress(total, current, success, failed, skipped));

    var historiesToRefresh = <History>[];
    for (var history in histories) {
      if (history.sourceKey == 'local') {
        skipped++;
        current++;
        controller.add(RefreshProgress(total, current, success, failed, skipped));
        continue;
      }
      historiesToRefresh.add(history);
    }

    total = historiesToRefresh.length;
    current = 0;
    controller.add(RefreshProgress(total, current, success, failed, skipped));

    var channel = Channel<History>(10);

    () async {
      var c = 0;
      for (var history in historiesToRefresh) {
        await channel.push(history);
        c++;
        if (c % 5 == 0) {
          var delay = c % 100 + 1;
          if (delay > 10) {
            delay = 10;
          }
          await Future.delayed(Duration(seconds: delay));
        }
      }
      channel.close();
    }();

    var updateFutures = <Future>[];
    for (var i = 0; i < 5; i++) {
      var f = () async {
        while (true) {
          var history = await channel.pop();
          if (history == null) {
            break;
          }
          var result = await _refreshSingleHistory(history);
          current++;
          if (result) {
            success++;
          } else {
            failed++;
          }
          controller.add(
            RefreshProgress(total, current, success, failed, skipped),
          );
        }
      }();
      updateFutures.add(f);
    }

    await Future.wait(updateFutures);

    notifyListeners();
    controller.close();
  }
}

class RefreshProgress {
  final int total;
  final int current;
  final int success;
  final int failed;
  final int skipped;

  RefreshProgress(
    this.total,
    this.current,
    this.success,
    this.failed,
    this.skipped,
  );
}
