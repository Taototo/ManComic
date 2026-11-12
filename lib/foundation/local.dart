import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/download.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/download_background.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/title_sort.dart';

import 'app.dart';
import 'appdata.dart';
import 'history.dart';

class LocalComic with HistoryMixin implements Comic {
  @override
  final String id;

  @override
  final String title;

  @override
  final String subtitle;

  @override
  final List<String> tags;

  /// The name of the directory where the comic is stored
  final String directory;

  /// key: chapter id, value: chapter title
  ///
  /// chapter id is the name of the directory in `LocalManager.path/$directory`
  final ComicChapters? chapters;

  bool get hasChapters => chapters != null;

  /// relative path to the cover image
  @override
  final String cover;

  final ComicType comicType;

  final List<String> downloadedChapters;

  final DateTime createdAt;

  const LocalComic({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.tags,
    required this.directory,
    required this.chapters,
    required this.cover,
    required this.comicType,
    required this.downloadedChapters,
    required this.createdAt,
  });

  LocalComic.fromRow(Row row)
    : id = row[0] as String,
      title = row[1] as String,
      subtitle = row[2] as String,
      tags = List.from(jsonDecode(row[3] as String)),
      directory = row[4] as String,
      chapters = ComicChapters.fromJsonOrNull(jsonDecode(row[5] as String)),
      cover = row[6] as String,
      comicType = ComicType(row[7] as int),
      downloadedChapters = List.from(jsonDecode(row[8] as String)),
      createdAt = DateTime.fromMillisecondsSinceEpoch(row[9] as int);

  File get coverFile => File(FilePath.join(baseDir, cover));

  String get baseDir => (directory.contains('/') || directory.contains('\\'))
      ? directory
      : FilePath.join(LocalManager().path, directory);

  @override
  String get description => "";

  @override
  String get sourceKey =>
      comicType == ComicType.local ? "local" : comicType.sourceKey;

  @override
  Map<String, dynamic> toJson() {
    return {
      "title": title,
      "cover": cover,
      "id": id,
      "subTitle": subtitle,
      "tags": tags,
      "description": description,
      "sourceKey": sourceKey,
      "chapters": chapters?.toJson(),
    };
  }

  @override
  int? get maxPage => null;

  void read() {
    var history = HistoryManager().find(id, comicType);
    int? firstDownloadedChapter;
    int? firstDownloadedChapterGroup;
    if (downloadedChapters.isNotEmpty && chapters != null) {
      final chapters = this.chapters!;
      if (chapters.isGrouped) {
        groupLoop:
        for (int i = 0; i < chapters.groupCount; i++) {
          var group = chapters.getGroupByIndex(i);
          var keys = group.keys.toList();
          for (int j = 0; j < keys.length; j++) {
            var chapterId = keys[j];
            if (downloadedChapters.contains(chapterId)) {
              firstDownloadedChapter = j + 1;
              firstDownloadedChapterGroup = i + 1;
              // 必须跳出外层：只 break 内层的话，后面还有下载章的分组会
              // 覆盖成「最后一组」，点阅读不是从第一话已下章开始。
              break groupLoop;
            }
          }
        }
      } else {
        var keys = chapters.allChapters.keys;
        for (int i = 0; i < keys.length; i++) {
          if (downloadedChapters.contains(keys.elementAt(i))) {
            firstDownloadedChapter = i + 1;
            break;
          }
        }
      }
    }
    App.rootContext.to(
      () => Reader(
        type: comicType,
        cid: id,
        name: title,
        chapters: chapters,
        initialChapter: history?.ep ?? firstDownloadedChapter,
        initialPage: history?.page,
        initialChapterGroup: history?.group ?? firstDownloadedChapterGroup,
        history: history ?? History.fromModel(model: this, ep: 0, page: 0),
        author: subtitle,
        tags: tags,
      ),
    );
  }

  @override
  HistoryType get historyType => comicType;

  @override
  String? get subTitle => subtitle;

  @override
  String? get language => null;

  @override
  String? get favoriteId => null;

  @override
  double? get stars => null;
}

class LocalManager with ChangeNotifier {
  static LocalManager? _instance;

  LocalManager._();

  factory LocalManager() {
    return _instance ??= LocalManager._();
  }

  late Database _db;

  /// path to the directory where all the comics are stored
  late String path;

  Directory get directory => Directory(path);

  void _checkNoMedia() {
    if (App.isAndroid) {
      var file = File(FilePath.join(path, '.nomedia'));
      if (!file.existsSync()) {
        file.createSync();
      }
    }
  }

  // return error message if failed
  Future<String?> setNewPath(String newPath) async {
    var newDir = Directory(newPath);
    if (!await newDir.exists()) {
      return "Directory does not exist";
    }
    if (!await newDir.list().isEmpty) {
      return "Directory is not empty";
    }
    try {
      await copyDirectoryIsolate(directory, newDir);
      await File(
        FilePath.join(App.dataPath, 'local_path'),
      ).writeAsString(newPath);
    } catch (e, s) {
      Log.error("IO", e, s);
      return e.toString();
    }
    await directory.deleteContents(recursive: true);
    path = newPath;
    _checkNoMedia();
    return null;
  }

  Future<String> findDefaultPath() async {
    if (App.isAndroid) {
      var external = await getExternalStorageDirectories();
      if (external != null && external.isNotEmpty) {
        return FilePath.join(external.first.path, 'local');
      } else {
        return FilePath.join(App.dataPath, 'local');
      }
    } else if (App.isIOS) {
      var oldPath = FilePath.join(App.dataPath, 'local');
      if (Directory(oldPath).existsSync() &&
          Directory(oldPath).listSync().isNotEmpty) {
        return oldPath;
      } else {
        var directory = await getApplicationDocumentsDirectory();
        return FilePath.join(directory.path, 'local');
      }
    } else {
      return FilePath.join(App.dataPath, 'local');
    }
  }

  Future<void> _checkPathValidation() async {
    var testFile = File(FilePath.join(path, 'venera_test'));
    try {
      testFile.createSync();
      testFile.deleteSync();
    } catch (e) {
      Log.error(
        "IO",
        "Failed to create test file in local path: $e\nUsing default path instead.",
      );
      path = await findDefaultPath();
    }
  }

  Future<void> init() async {
    _db = sqlite3.open('${App.dataPath}/local.db');
    _db.execute('''
      CREATE TABLE IF NOT EXISTS comics (
        id TEXT NOT NULL,
        title TEXT NOT NULL,
        subtitle TEXT NOT NULL,
        tags TEXT NOT NULL,
        directory TEXT NOT NULL,
        chapters TEXT NOT NULL,
        cover TEXT NOT NULL,
        comic_type INTEGER NOT NULL,
        downloadedChapters TEXT NOT NULL,
        created_at INTEGER,
        PRIMARY KEY (id, comic_type)
      );
    ''');
    if (File(FilePath.join(App.dataPath, 'local_path')).existsSync()) {
      path = File(FilePath.join(App.dataPath, 'local_path')).readAsStringSync();
      if (!directory.existsSync()) {
        path = await findDefaultPath();
      }
    } else {
      path = await findDefaultPath();
    }
    try {
      if (!directory.existsSync()) {
        await directory.create();
      }
    } catch (e, s) {
      Log.error("IO", "Failed to create local folder: $e", s);
    }
    _checkPathValidation();
    _checkNoMedia();
    await ComicSourceManager().ensureInit();
    DownloadBackground.instance.summaryProvider = downloadSummary;
    restoreDownloadingTasks();
  }

  String findValidId(ComicType type) {
    final res = _db.select(
      '''
      SELECT id FROM comics WHERE comic_type = ?
      ORDER BY CAST(id AS INTEGER) DESC
      LIMIT 1;
      ''',
      [type.value],
    );
    if (res.isEmpty) {
      return '1';
    }
    return (int.parse((res.first[0])) + 1).toString();
  }

  Future<void> add(LocalComic comic, [String? id]) async {
    var old = find(id ?? comic.id, comic.comicType);
    // 用 Set 合并，别就地 addAll：`isDownloaded` 更新章节表时传进来的就是
    // 库里同一份 downloadedChapters，并自己会把它翻一倍。而「源站加一话」
    // 正好会走那条路，所以这不是极端情况——列表翻倍后删除章节弹窗同章两行、
    // 导出 cbz/pdf 出现重复章节、本地库显示「8/5」。
    var downloaded = <String>{...comic.downloadedChapters};
    if (old != null) {
      downloaded.addAll(old.downloadedChapters);
    }
    _db.execute(
      'INSERT OR REPLACE INTO comics VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      [
        id ?? comic.id,
        comic.title,
        comic.subtitle,
        jsonEncode(comic.tags),
        comic.directory,
        jsonEncode(comic.chapters),
        comic.cover,
        comic.comicType.value,
        jsonEncode(downloaded.toList()),
        comic.createdAt.millisecondsSinceEpoch,
      ],
    );
    notifyListeners();
  }

  void remove(String id, ComicType comicType) async {
    _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
      id,
      comicType.value,
    ]);
    notifyListeners();
  }

  void removeComic(LocalComic comic) {
    remove(comic.id, comic.comicType);
    notifyListeners();
  }

  /// 本地库里的漫画数量。
  ///
  /// 侧栏「本地」分类每帧都要显示它，所以只走 `count(*)`，不把整库读出来。
  int get length {
    var res = _db.select('SELECT count(*) FROM comics;');
    return res.first[0] as int;
  }

  List<LocalComic> getComics(LocalSortType sortType) {
    // A-Z 要按「读音」排，不能交给 SQLite：库里存的是 UTF-8，汉字会落成
    // 按码位排，结果是乱序。这里取全量再按首字母排（见 comicTitleSortKey）。
    if (sortType == LocalSortType.titleAZ) {
      var all = _db
          .select('SELECT * FROM comics;')
          .map((row) => LocalComic.fromRow(row))
          .toList();
      return sortByTitleAZ(all, (e) => e.title);
    }
    var res = _db.select('''
      SELECT * FROM comics
      ORDER BY
        ${sortType.value == 'name' ? 'title' : 'created_at'}
        ${sortType.value == 'time_asc' || sortType.value == 'name' ? 'ASC' : 'DESC'}
      ;
    ''');
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  LocalComic? find(String id, ComicType comicType) {
    final res = _db.select(
      'SELECT * FROM comics WHERE id = ? AND comic_type = ?;',
      [id, comicType.value],
    );
    if (res.isEmpty) {
      return null;
    }
    return LocalComic.fromRow(res.first);
  }

  /// 向源站要一次最新目录并写回本地库。
  ///
  /// 章节表有三个来源：源站、`details.json`、本地库。以前只有本地详情页会
  /// 刷新本地库，而「最近阅读 / 继续阅读」直接信本地快照——源站加了章节后，
  /// 同一本书从详情页进和从最近阅读进，章节序号会对不上，跳到另一话。
  ///
  /// 写回是安全的：章节目录按章节 id 建，换一份新表不会动已下好的文件。
  /// 返回是否真的更新了。失败静默（离线是常态）。
  Future<bool> refreshChapters(LocalComic comic) async {
    if (comic.comicType == ComicType.local) {
      return false;
    }
    var source = comic.comicType.comicSource;
    if (source?.loadComicInfo == null) {
      return false;
    }
    try {
      var res = await source!.loadComicInfo!(comic.id);
      if (res.error) {
        return false;
      }
      var remote = res.data.chapters;
      if (remote == null) {
        return false;
      }
      var old = comic.chapters;
      if (old != null && remote.ids.join(",") == old.ids.join(",")) {
        return false;
      }
      await add(
        LocalComic(
          id: comic.id,
          title: comic.title,
          subtitle: comic.subtitle,
          tags: comic.tags,
          directory: comic.directory,
          chapters: remote,
          cover: comic.cover,
          comicType: comic.comicType,
          downloadedChapters: comic.downloadedChapters,
          createdAt: comic.createdAt,
        ),
      );
      return true;
    } catch (_) {
      // 离线 / 源挂了：本地章节照样能读，不该因为刷新失败影响进入阅读。
      return false;
    }
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _progressTimer = null;
    super.dispose();
    _db.dispose();
  }

  List<LocalComic> getRecent() {
    final res = _db.select('''
      SELECT * FROM comics
      ORDER BY created_at DESC
      LIMIT 20;
    ''');
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  int get count {
    final res = _db.select('''
      SELECT COUNT(*) FROM comics;
    ''');
    return res.first[0] as int;
  }

  LocalComic? findByName(String name) {
    final res = _db.select(
      '''
      SELECT * FROM comics
      WHERE title = ? OR directory = ?;
    ''',
      [name, name],
    );
    if (res.isEmpty) {
      return null;
    }
    return LocalComic.fromRow(res.first);
  }

  List<LocalComic> search(String keyword) {
    final res = _db.select(
      '''
      SELECT * FROM comics
      WHERE title LIKE ? OR tags LIKE ? OR subtitle LIKE ?
      ORDER BY created_at DESC;
    ''',
      ['%$keyword%', '%$keyword%', '%$keyword%'],
    );
    return res.map((row) => LocalComic.fromRow(row)).toList();
  }

  /// 本地图片目录和章节表。
  ///
  /// 已入库的漫画从数据库拿；还在下载中的漫画数据库里没有记录，目录和
  /// 章节表都在下载任务上——「下载多少看多少」要靠这条路径才能读到已经
  /// 落到磁盘的那几章。
  ({String baseDir, ComicChapters? chapters})? _localTarget(
    String id,
    ComicType type,
  ) {
    var comic = find(id, type);
    if (comic != null) {
      return (baseDir: comic.baseDir, chapters: comic.chapters);
    }
    var task = findTask(id, type);
    if (task is ImagesDownloadTask && task.path != null) {
      return (baseDir: task.path!, chapters: task.comic?.chapters);
    }
    return null;
  }

  /// 一章在磁盘上的目录。
  ///
  /// 优先按 **章节 id**（下载写目录、阅读找目录、对账扫目录都用它）。id
  /// 找不到时再按**标题**找一次：源站换过章节 id 时，磁盘上还是老 id 的
  /// 目录名；早期版本也有按标题建目录的。两边都找不到就把 id 那份返回，
  /// 由调用方决定「当作没有」。
  ///
  /// 同步实现：`existsSync` 一次只有几微秒，而这条路径在阅读器首屏上，
  /// 不值得为了异步再串一个 event loop 轮次。
  static Directory resolveChapterDirectory(
    String dirPath,
    String chapterId,
    String? title,
  ) {
    var byId = Directory(
      FilePath.join(dirPath, getChapterDirectoryName(chapterId)),
    );
    if (byId.existsSync()) {
      return byId;
    }
    if (title != null && title != chapterId) {
      var byTitle = Directory(
        FilePath.join(dirPath, getChapterDirectoryName(title)),
      );
      if (byTitle.existsSync()) {
        return byTitle;
      }
    }
    return byId;
  }

  Future<Directory> _pageDirectory(String id, ComicType type, Object ep) async {
    var target = _localTarget(id, type) ?? (throw "Comic Not Found");
    var directory = Directory(target.baseDir);
    var chapters = target.chapters;
    if (chapters != null) {
      var cid = ep is int ? chapters.ids.elementAt(ep - 1) : (ep as String);
      return resolveChapterDirectory(
        directory.path,
        cid,
        chapters.allChapters[cid],
      );
    }
    return directory;
  }

  Future<List<File>> _pageFiles(String id, ComicType type, Object ep) async {
    var directory = await _pageDirectory(id, type, ep);
    var files = <File>[];
    if (!await directory.exists()) {
      // 记录说这一章下好了，目录却不在：取消下载、手工删了文件夹、或者旧
      // 版本的脏记录都会这样。以前这里直接 `list()`，PathNotFoundException
      // 一路抛到阅读器，整章变成红字错误页（「取消后重新下载的漫画打不开」
      // 就是这个）。现在返回空让调用方退回网络，顺手把这条记录清掉。
      _forgetMissingChapter(id, type, ep);
      return files;
    }
    await for (var entity in directory.list()) {
      if (entity is File) {
        // Do not exclude comic.cover, since it may be the first page of the chapter.
        // A file with name starting with 'cover.' is not a comic page.
        if (entity.name.startsWith('cover.')) {
          continue;
        }
        //Hidden file in some file system
        if (entity.name.startsWith('.')) {
          continue;
        }
        // 下载时顺手写进漫画目录的详情快照（details.json）不是漫画页。
        // 无章节的漫画所有图都在根目录，不排掉它就会出现「最后一页打不开」。
        if (entity.name.endsWith('.json')) {
          continue;
        }
        files.add(entity);
      }
    }
    return files;
  }

  /// 把「记录里有、磁盘上没有」的这一章从 [LocalComic.downloadedChapters]
  /// 里摘掉。
  ///
  /// 只在读图时发现目录缺失才会走到，命中一次就修一次，用户不用自己去
  /// 「清理失效」。整本一章不剩的情况不在这里处理：这里删记录会让正在读的
  /// 页面立刻变成「没下载」，那是详情页该干的事。
  void _forgetMissingChapter(String id, ComicType type, Object ep) {
    var comic = find(id, type);
    if (comic == null) {
      return;
    }
    var chapters = comic.chapters;
    if (chapters == null) {
      return;
    }
    var cid = ep is int ? chapters.ids.elementAtOrNull(ep - 1) : ep.toString();
    if (cid == null || !comic.downloadedChapters.contains(cid)) {
      return;
    }
    var remaining = comic.downloadedChapters.where((e) => e != cid).toList();
    try {
      _db.execute(
        'UPDATE comics SET downloadedChapters = ? WHERE id = ? AND comic_type = ?;',
        [jsonEncode(remaining), id, type.value],
      );
      notifyListeners();
    } catch (e) {
      Log.error("LocalManager", "Failed to forget missing chapter $cid: $e");
    }
  }

  /// 本地图片的 [File] 列表，按页码排好序。
  ///
  /// 这是「真正要读写文件」的入口（导出 cbz/epub/pdf、打包、复制）。阅读器
  /// 和图片控件要的是 URL，用 [getImages]——它只是给这里的路径加上
  /// `file://` 前缀。
  ///
  /// 两条路径必须共用同一份过滤规则（[_pageFiles]）：少了 `cover.*` 会把封面
  /// 当成第一页，少了 `details.json` 会把 JSON 当图片喂给解码器。之前导出
  /// 直接自己 listSync 目录、又各自贴 `file://`，cbz/epub/pdf 三个全挂。
  ///
  /// 注意：本方法会查本地数据库，只能在主 isolate 调用；后台 isolate 里
  /// 请先把路径列表算好再传进去。
  Future<List<File>> getImageFiles(String id, ComicType type, Object ep) async {
    if (ep is! String && ep is! int) {
      throw "Invalid ep";
    }
    var files = await _pageFiles(id, type, ep);
    files.sort(_comparePageFile);
    return files;
  }

  static int _comparePageFile(File a, File b) {
    var ai = int.tryParse(a.name.split('.').first);
    var bi = int.tryParse(b.name.split('.').first);
    if (ai != null && bi != null) {
      return ai.compareTo(bi);
    }
    return a.name.compareTo(b.name);
  }

  Future<List<String>> getImages(String id, ComicType type, Object ep) async {
    var files = await getImageFiles(id, type, ep);
    return files.map((e) => "file://${e.path}").toList();
  }

  /// 本地页的「页码 → 文件路径」映射。
  ///
  /// 边下边看时这一章可能只落了前几页，中间还可能因为某页失败缺一张，
  /// 所以不能拿「本地第 n 个文件」当「第 n 页」。地图按文件名里的序号
  /// 对齐，缺的页码自然留空，读的时候再去网络补那一页。
  ///
  /// 文件名不是数字的来源（导入的 epub/pdf 之类）无法对齐，返回空 Map，
  /// 调用方据此退回纯本地，不要拿它去拼网络列表。
  Future<Map<int, String>> getPageMap(
    String id,
    ComicType type,
    Object ep,
  ) async {
    if (ep is! String && ep is! int) {
      throw "Invalid ep";
    }
    var map = <int, String>{};
    var files = await _pageFiles(id, type, ep);
    for (var file in files) {
      var index = int.tryParse(file.name.split('.').first);
      if (index == null) {
        return {};
      }
      map[index] = "file://${file.path}";
    }
    return map;
  }

  /// 这一章本地是否已经有能读的图。
  ///
  /// 阅读器据此决定走本地还是走网络：下载中的漫画，已经落盘的那几章直接
  /// 本地读（秒开），还没开始下的仍然走源站，于是「下载多少看多少」自然
  /// 成立，不需要额外的下载引擎。
  Future<bool> hasLocalPages(String id, ComicType type, Object ep) async {
    try {
      return (await getImages(id, type, ep)).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  bool isDownloaded(
    String id,
    ComicType type, [
    int? ep,
    ComicChapters? chapters,
  ]) {
    var comic = find(id, type);
    if (comic == null) return false;
    if (comic.chapters == null || ep == null) return true;
    if (chapters != null) {
      if (comic.chapters?.length != chapters.length) {
        // update
        add(
          LocalComic(
            id: comic.id,
            title: comic.title,
            subtitle: comic.subtitle,
            tags: comic.tags,
            directory: comic.directory,
            chapters: chapters,
            cover: comic.cover,
            comicType: comic.comicType,
            downloadedChapters: comic.downloadedChapters,
            createdAt: comic.createdAt,
          ),
        );
      }
    }
    return comic.downloadedChapters.contains(
      (chapters ?? comic.chapters)!.ids.elementAtOrNull(ep - 1),
    );
  }

  /// 记录里是否已经算「下完了」，按章节 **id** 判。
  ///
  /// [isDownloaded] 要的是行号，而阅读器手里的目录和库里那份未必一样（源站
  /// 插话、翻正倒序、某一边刚刷新），同一个行号会指到不同的话。查文件用的是
  /// 章节 id，所以判断「缺不缺页」也得用同一把钥匙，否则会给已经下全的章节
  /// 白拉一次地址表，或者反过来把缺页的章节当成完整。
  bool isChapterRecorded(String id, ComicType type, Object ep) {
    var comic = find(id, type);
    if (comic == null) {
      return false;
    }
    var chapters = comic.chapters;
    if (chapters == null) {
      return true;
    }
    var cid = ep is int ? chapters.ids.elementAtOrNull(ep - 1) : ep.toString();
    if (cid == null) {
      return false;
    }
    return comic.downloadedChapters.contains(cid);
  }

  List<DownloadTask> downloadingTasks = [];

  /// 同时开跑的下载任务数上限。
  ///
  /// 单个任务内部还会按 `downloadThreads` 并发拉图，所以实际并发是
  /// 「任务数 × 线程数」。默认 3 是折中：再多很容易被源站限速或触发风控，
  /// 反而比串行更慢；而串行时后面的任务要等到天荒地老，用户会以为卡死了。
  int get maxConcurrentTasks {
    var value = appdata.settings['maxConcurrentDownloads'];
    if (value is num && value >= 1) {
      return value.toInt();
    }
    return 3;
  }

  bool isDownloading(String id, ComicType type) {
    return downloadingTasks.any(
      (element) => element.id == id && element.comicType == type,
    );
  }

  DownloadTask? findTask(String id, ComicType type) {
    for (var task in downloadingTasks) {
      if (task.id == id && task.comicType == type) {
        return task;
      }
    }
    return null;
  }

  /// 按并发上限把排队中的任务拉起来。
  ///
  /// 排队和手动暂停在 [DownloadTask.isPaused] 上长得一样，靠 `userPaused`
  /// 区分——否则这个函数会把用户按了暂停的任务重新启动。
  void pumpQueue() {
    var running = 0;
    for (var task in downloadingTasks) {
      if (!task.isPaused) {
        running++;
      }
    }
    for (var task in downloadingTasks) {
      if (running >= maxConcurrentTasks) {
        break;
      }
      if (!task.isPaused || task.isError || task.userPaused) {
        continue;
      }
      task.resume();
      running++;
    }
    // 排队里的任务被拉起来也算状态变化：下载页的秒级刷新、前台服务的
    // 通知都靠这个信号（单任务的 resume 只通知它自己的监听者）。
    _ensureWatchdog();
    notifyListeners();
    DownloadBackground.instance.refresh();
  }

  /// 让前台服务跟上当前状态（任务开跑/停下时调）。
  void refreshBackgroundService() {
    _ensureWatchdog();
    DownloadBackground.instance.refresh();
  }

  /// 后台下载看门狗。
  ///
  /// 前台服务只保证进程不被系统回收，**不保证下载还在动**：网络抖一下把
  /// 任务打成 error 之后，退避阶梯（5~160 秒）用完就彻底不动了，而后台没有
  /// 人去点「重试」，任务就那样一直躺到用户再打开应用为止——用户看到的
  /// 就是「切后台一段时间后下载自己停了，也不知道什么时候停的」。
  ///
  /// 这里每隔二十秒巡一次：补满并发槽、把出错的任务按分钟级节奏拉起来、
  /// 顺便确认前台服务还在。断网一小时回来也能自己接上。
  Timer? _downloadWatchdog;

  /// 每个任务上一次被看门狗拉起的时间（毫秒），键是 [DownloadTask.progressKey]。
  final Map<String, int> _lastWatchdogRetry = {};

  /// 每个任务被看门狗拉起过几次，用来把节奏放慢。
  final Map<String, int> _watchdogAttempts = {};

  static const _watchdogInterval = Duration(seconds: 20);

  /// 同一个任务两次自动复活的最小间隔。
  static const watchdogRetryIntervalMs = 60 * 1000;

  void _ensureWatchdog() {
    // 桌面端没有「后台被冻」这回事，也不需要凭空多一个定时器。
    if (!App.isAndroid) {
      return;
    }
    if (_downloadWatchdog != null) {
      return;
    }
    if (!downloadingTasks.any((e) => !e.userPaused)) {
      return;
    }
    _downloadWatchdog = Timer.periodic(_watchdogInterval, (_) {
      try {
        _watchdogTick();
      } catch (e, s) {
        Log.error("Download", "Watchdog tick failed: $e", s);
      }
    });
  }

  void _watchdogTick() {
    var pending = downloadingTasks.where((e) => !e.userPaused).toList();
    if (pending.isEmpty) {
      _downloadWatchdog?.cancel();
      _downloadWatchdog = null;
      DownloadBackground.instance.refresh();
      return;
    }
    var now = DateTime.now().millisecondsSinceEpoch;
    var slots = maxConcurrentTasks;
    for (var task in pending) {
      if (!task.isPaused && !task.isError) {
        slots--;
      }
    }
    var retried = 0;
    for (var task in pending) {
      var key = task.progressKey;
      if (!task.isError) {
        // 又跑起来了：记账清零，下次真出错时从快节奏重新开始
        _lastWatchdogRetry.remove(key);
        _watchdogAttempts.remove(key);
        continue;
      }
      if (slots <= 0) {
        break;
      }
      var attempts = _watchdogAttempts[key] ?? 0;
      if (!shouldRetryErroredTask(
        isError: task.isError,
        userPaused: task.userPaused,
        nowMs: now,
        lastAttemptMs: _lastWatchdogRetry[key] ?? 0,
        intervalMs: watchdogRetryInterval(attempts),
      )) {
        continue;
      }
      _watchdogAttempts[key] = attempts + 1;
      _lastWatchdogRetry[key] = now;
      Log.info("Download", "Watchdog: retry ${task.title} (${task.message})");
      task.resume();
      slots--;
      retried++;
    }
    if (retried > 0) {
      saveCurrentDownloadingTasks(full: true);
    }
    pumpQueue();
    DownloadBackground.instance.refresh();
  }

  /// 回到前台时把「被网络错误停下」的任务重新拉起来。
  ///
  /// 锁屏、VPN 重连、进电梯都可能让下载中途报错停下；任务自己会退避重试
  /// 几次，但如果断得久一点就用完了。用户回到应用说明网络多半也回来了，
  /// 这里再给一次机会，省得他们逐个点「重试」。
  void retryErroredTasks() {
    // 不能一口气全 resume：resume() 会立刻开跑，绕过并发上限。只补满空位，
    // 剩下的等前面的完成后由 pumpQueue 自然接手。
    //
    // 「空位」要先扣掉正在跑的：以前只数「这次要拉起的个数」，3 本在跑 +
    // 3 本 error 会再拉起 3 本，实际并发翻倍（×downloadThreads 后更夸张），
    // 反而更容易被源站限流。
    var running = downloadingTasks.where((t) => !t.isPaused && !t.isError).length;
    var slots = maxConcurrentTasks - running;
    if (slots <= 0) {
      return;
    }
    var retried = 0;
    for (var task in downloadingTasks) {
      if (slots <= 0) {
        break;
      }
      if (task.isError && !task.userPaused) {
        task.resume();
        slots--;
        retried++;
      }
    }
    if (retried > 0) {
      saveCurrentDownloadingTasks(full: true);
      notifyListeners();
      DownloadBackground.instance.refresh();
    }
  }

  /// 暂停所有任务（含排队中的），并记住这是用户的意思。
  void pauseAll() {
    for (var task in downloadingTasks) {
      if (!task.isPaused) {
        task.pause();
      } else {
        task.userPaused = true;
      }
    }
    _notifyTasksChanged();
    saveCurrentDownloadingTasks(full: true);
  }

  /// 继续所有被暂停的任务，仍然受并发上限约束。
  void resumeAll() {
    for (var task in downloadingTasks) {
      task.userPaused = false;
    }
    _notifyTasksChanged();
    saveCurrentDownloadingTasks(full: true);
    // 只清 userPaused 不够：pumpQueue 会明确跳过 isError 的任务，队列里
    // 全是失败任务时「全部开始」看起来点了没反应，得等看门狗 60 秒。
    // retryErroredTasks 内部按剩余并发位补满，不会一口气全拉起来。
    retryErroredTasks();
    pumpQueue();
  }

  bool get allPaused => downloadingTasks.every((e) => e.isPaused);

  Future<Directory> findValidDirectory(
    String id,
    ComicType type,
    String name,
  ) async {
    var comic = find(id, type);
    if (comic != null) {
      return Directory(FilePath.join(path, comic.directory));
    }
    const comicDirectoryMaxLength = 80;
    if (name.length > comicDirectoryMaxLength) {
      name = name.substring(0, comicDirectoryMaxLength);
    }
    var dir = findValidDirectoryName(path, name);
    return Directory(FilePath.join(path, dir)).create().then((value) => value);
  }

  /// 找出「已经下过东西」的同名目录。
  ///
  /// 断点续传靠的是任务里记的 `path`。万一那条记录没落盘（进程正好在
  /// 「算好目录、还没写任务文件」那一瞬被杀），`findValidDirectory` 会
  /// 因为同名目录已存在而新建一个 `标题(1)`——旧目录里下了一半的图全部
  /// 变成孤儿，界面上就是「进度回到 0、从头再来一遍」。
  ///
  /// 只有任务自述「已经下过东西」时才会调到这里，所以命中的目录必然是
  /// 这个任务自己建的（同名不同源属于极端情况，那时拿到的也只是多下的
  /// 章节，会在下面按页重算时被纠正）。
  Directory? findReusableDirectory(
    String name, {
    String? comicId,
    String? sourceKey,
  }) {
    const comicDirectoryMaxLength = 80;
    if (name.length > comicDirectoryMaxLength) {
      name = name.substring(0, comicDirectoryMaxLength);
    }
    for (var i = 0; i < 20; i++) {
      var candidate = i == 0 ? name : "$name($i)";
      var dir = Directory(FilePath.join(path, sanitizeFileName(candidate)));
      try {
        if (!dir.existsSync() || dir.listSync().isEmpty) {
          continue;
        }
      } catch (_) {
        continue;
      }
      if (_directoryBelongsTo(dir, comicId, sourceKey)) {
        return dir;
      }
    }
    return null;
  }

  /// 目录里那份 `details.json` 是不是这本漫画的。
  ///
  /// 没有快照（刚建目录就被杀）时只能按名字认——它是这个任务自己建的。
  /// 有快照但 id/源对不上，说明是另一本同名漫画，不能拿来续传。
  bool _directoryBelongsTo(Directory dir, String? comicId, String? sourceKey) {
    if (comicId == null && sourceKey == null) {
      return true;
    }
    var file = File(FilePath.join(dir.path, 'details.json'));
    if (!file.existsSync()) {
      return true;
    }
    try {
      var json = jsonDecode(file.readAsStringSync());
      if (json is! Map) {
        return true;
      }
      if (comicId != null &&
          json['comicId'] != null &&
          json['comicId'] != comicId) {
        return false;
      }
      if (sourceKey != null &&
          json['sourceKey'] != null &&
          json['sourceKey'] != sourceKey) {
        return false;
      }
      return true;
    } catch (_) {
      return true;
    }
  }

  void completeTask(DownloadTask task, [LocalComic? local]) {
    // 入库时按磁盘核对一遍「已下载章节」。不核对的话，记录会把「地址表里
    // 有、实际一页都没下来」的章节也算成下好了，阅读器信记录去读目录，
    // 直接 PathNotFoundException（取消后重新下载的漫画打不开就是这个）。
    //
    // [local] 允许调用方把已经核好的结果传进来，省掉第二次扫目录。
    add(local ?? task.toLocalComic(verifyChapters: true));
    downloadingTasks.remove(task);
    _notifyTasksChanged();
    saveCurrentDownloadingTasks(full: true);
    pumpQueue();
  }

  void removeTask(DownloadTask task) {
    downloadingTasks.remove(task);
    _notifyTasksChanged();
    saveCurrentDownloadingTasks(full: true);
    pumpQueue();
  }

  /// 放弃一次下载（用户点了「取消」）。
  ///
  /// 「取消」和「暂停」必须是两件事：暂停保留已经下好的页，取消就是把这次
  /// 下载从记录和磁盘上一起抹掉。顺序不能反：
  ///
  /// 1. 先把任务摘掉并**等任务表/进度表落盘**。以前是先摘再异步删目录，
  ///    进程在那一刻被划掉（用户按取消之后顺手清理后台，太常见了）就只剩
  ///    下「记录没了、文件还在」——下次点下载，磁盘扫描把它当成已下过，
  ///    于是只从断点往后下。
  /// 2. 再删这次写进去的页。库里本来就登记为「已下好」的章节一页都不动，
  ///    同一本书一边补新章节一边取消，不该把老内容带走。
  /// 3. 最后按目录里真实剩下的内容重写 `downloadedChapters`。这一步以前
  ///    完全没有，于是取消之后章节表还认为那几章已经下好，章节选择里它们
  ///    是勾上且不可点的灰项，「下载全部」也会跳过——表现就是「只下后面的
  ///    章节」，而且用户没有任何办法把它们选回来。
  Future<void> discardTask(DownloadTask task) async {
    var known = downloadingTasks.remove(task);
    _lastWatchdogRetry.remove(task.progressKey);
    _watchdogAttempts.remove(task.progressKey);
    _notifyTasksChanged();
    if (known) {
      await saveCurrentDownloadingTasks(full: true);
    }
    if (!task.keepFilesOnCancel) {
      var key = task.progressKey;
      var purge = _purgeTaskFiles(task).whenComplete(() {
        _purging.remove(key);
      });
      _purging[key] = purge;
      await purge;
      _notifyTasksChanged();
    }
    pumpQueue();
  }

  /// 「这条记录还在删文件」的标记，键是 [DownloadTask.progressKey]。
  ///
  /// 取消之后立刻又点下载是很自然的操作，而删除目录是异步的。不做标记的话
  /// 新任务可能在删到一半时扫描磁盘，把马上要消失的页当成「已经下过」跳过，
  /// 最后缺一大段——用户看到的就是「重下只补了后面几章」。
  final Map<String, Future<void>> _purging = {};

  /// 删掉这个任务写到磁盘上的东西。[discardTask] 的后半段。
  Future<void> _purgeTaskFiles(DownloadTask task) async {
    var dirPath = task.path;
    if (dirPath == null) {
      return;
    }
    var local = find(task.id, task.comicType);
    // 库里已经登记为「下好」的章节：只删这次写进去的那几页。
    var keep = local?.downloadedChapters.toSet() ?? const <String>{};
    var dir = Directory(dirPath);

    if (task is ImagesDownloadTask) {
      var written = task.pagesWrittenThisRun;
      var chapters = task.selectedChapters ?? task.knownChapters;
      if (chapters == null) {
        // 刚建任务就被取消，连要下哪些章节都还不知道。库里没有这本书时
        // 目录一定是这个任务刚建的空壳，可以整个删；库里有时不敢动。
        if (local == null) {
          await _deleteDirectoryQuietly(dir);
        }
      } else {
        for (var chapter in chapters) {
          var chapterDir = resolveChapterDirectory(
            dirPath,
            chapter,
            local?.chapters?.allChapters[chapter] ??
                task.comic?.chapters?.allChapters[chapter],
          );
          if (keep.contains(chapter)) {
            var pages = written[chapter];
            if (pages != null && pages.isNotEmpty) {
              await _deletePages(chapterDir, pages);
            }
          } else {
            await _deleteDirectoryQuietly(chapterDir);
          }
        }
        // 章节删光了就把空壳目录一起收掉：留着它，下次下载会新建一个
        // 「标题(1)」，空目录永远躺在存储里。
        await _deleteIfEmpty(dir);
      }
    } else {
      // 压缩包下载没有断点续传：解压出来的就是这次的全部产物。
      await _deleteDirectoryQuietly(dir);
    }

    await _reconcileDownloadedChapters(task.id, task.comicType, dirPath, local);
  }

  static Future<void> _deleteDirectoryQuietly(Directory dir) async {
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (e) {
      Log.error("LocalManager", "Failed to delete ${dir.path}: $e");
    }
  }

  /// 目录里除了 `.nomedia` 什么都没有时，把目录本身删掉。
  static Future<void> _deleteIfEmpty(Directory dir) async {
    try {
      if (!await dir.exists()) {
        return;
      }
      await for (var entity in dir.list(followLinks: false)) {
        if (entity is File && entity.name == '.nomedia') {
          continue;
        }
        return;
      }
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// 删掉章节目录里指定页码的图。
  static Future<void> _deletePages(Directory dir, Set<int> pages) async {
    try {
      if (!await dir.exists()) {
        return;
      }
      await for (var entity in dir.list(followLinks: false)) {
        if (entity is! File) {
          continue;
        }
        var index = int.tryParse(entity.name.split('.').first);
        if (index == null || !pages.contains(index)) {
          continue;
        }
        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (e) {
      Log.error("LocalManager", "Failed to delete pages in ${dir.path}: $e");
    }
  }

  /// 按磁盘上的真实内容重写这本书的「已下载章节」。
  ///
  /// 取消下载之后必须做一次：否则章节表还挂着已经不存在的章节，章节选择里
  /// 它们是灰的、「下载全部」也会跳过它们，用户只能下后面的章节。
  /// 目录彻底空了就连库记录一起删掉，这本回到「没下载过」的状态。
  Future<void> _reconcileDownloadedChapters(
    String id,
    ComicType type,
    String dirPath,
    LocalComic? local,
  ) async {
    var dir = Directory(dirPath);
    var hasPages = false;
    try {
      if (await dir.exists()) {
        await for (var entity in dir.list(recursive: true, followLinks: false)) {
          if (entity is File && isPageFileName(entity.name)) {
            hasPages = true;
            break;
          }
        }
      }
    } catch (e) {
      // 扫不动就当「不知道」，别把库记录删掉。下次启动还有机会修。
      Log.error("LocalManager", "Failed to scan ${dir.path}: $e");
      return;
    }

    if (!hasPages) {
      await _deleteDirectoryQuietly(dir);
      if (local != null) {
        remove(id, type);
      }
      return;
    }

    if (local == null) {
      // 任务取消、库本来就没有这本书：剩下的残页下次下载会覆盖，不建记录。
      return;
    }

    var chapters = local.chapters;
    if (chapters == null) {
      return;
    }
    var stillDownloaded = <String>[];
    for (var entry in chapters.allChapters.entries) {
      // 目录是按**章节 id** 建的（下载写目录、阅读找目录都用 id）。这里
      // 以前拿 `entry.value` 也就是标题去拼，两边永远对不上：取消一次下载，
      // 整本书的「已下载章节」就被清空。走 [resolveChapterDirectory] 是为了
      // 兼容源站换过 id、磁盘上还是老目录名的书。
      var chapterDir = resolveChapterDirectory(
        dirPath,
        entry.key,
        entry.value,
      );
      if (await _hasPage(chapterDir)) {
        stillDownloaded.add(entry.key);
      }
    }
    if (stillDownloaded.length == local.downloadedChapters.length &&
        stillDownloaded.every((e) => local.downloadedChapters.contains(e))) {
      return;
    }
    if (stillDownloaded.isEmpty) {
      remove(id, type);
      return;
    }
    _db.execute(
      'UPDATE comics SET downloadedChapters = ? WHERE id = ? AND comic_type = ?;',
      [jsonEncode(stillDownloaded), id, type.value],
    );
    notifyListeners();
  }

  static Future<bool> _hasPage(Directory dir) async {
    try {
      if (!await dir.exists()) {
        return false;
      }
      await for (var entity in dir.list(followLinks: false)) {
        if (entity is File && isPageFileName(entity.name)) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  void moveToFirst(DownloadTask task) {
    if (downloadingTasks.firstOrNull == task) {
      if (task.isPaused && !task.userPaused) {
        task.resume();
      }
      return;
    }
    downloadingTasks.remove(task);
    downloadingTasks.insert(0, task);
    _notifyTasksChanged();
    saveCurrentDownloadingTasks(full: true);
    pumpQueue();
  }

  Future<void> saveCurrentDownloadingTasks({bool full = false}) {
    if (!full) {
      _scheduleProgressFlush();
      return _writeChain;
    }
    _progressTimer?.cancel();
    _progressTimer = null;
    return _enqueueWrite(() async {
      await _writeJson(
        File(FilePath.join(App.dataPath, tasksFileName)),
        downloadingTasks.map((e) => e.toJson()).toList(),
      );
      await _writeProgressFile();
    });
  }

  /// 立刻把进度写下去（跳过合并窗口）。
  ///
  /// 暂停这类「用户按了一下」的动作值得立刻落盘，但仍然只写小体积的进度
  /// 文件：`pauseAll` 会逐个任务暂停，每个都写一遍整本地址表就太贵了。
  Future<void> saveDownloadProgressNow() {
    _progressTimer?.cancel();
    _progressTimer = null;
    return _enqueueWrite(_writeProgressFile);
  }

  /// 进度文件的合并窗口。
  ///
  /// 下载时每落一页都会来一次，一部中长篇一秒能落十几页；同步写盘等于把
  /// 主线程按在地上摩擦。合并成一次，断电最多丢一秒多的进度——而进度本来
  /// 也会在恢复时按磁盘重算，丢那点不影响什么。
  static const _progressFlushDelay = Duration(milliseconds: 1200);

  /// 任务定义（含整本地址表）与进度快照分两个文件存，清理残留时也要认这两个名字。
  static const tasksFileName = 'downloading_tasks.json';

  static const progressFileName = 'downloading_progress.json';

  Timer? _progressTimer;

  Future<void> _writeChain = Future.value();

  void _scheduleProgressFlush() {
    if (_progressTimer != null) {
      return;
    }
    _progressTimer = Timer(_progressFlushDelay, () {
      _progressTimer = null;
      _enqueueWrite(_writeProgressFile);
    });
  }

  Future<void> _writeProgressFile() async {
    var map = <String, dynamic>{};
    for (var task in downloadingTasks) {
      map[task.progressKey] = task.toProgressJson();
    }
    await _writeJson(File(FilePath.join(App.dataPath, progressFileName)), map);
  }

  /// 排队串行写，避免两次写同时操作同一个临时文件。
  Future<void> _enqueueWrite(Future<void> Function() task) {
    var next = _writeChain.then((_) => task());
    _writeChain = next.catchError((_) {});
    return next;
  }

  /// 先写临时文件再 rename。rename 是原子的，进程在写的过程中被杀最多
  /// 留下一个 .tmp，不会出现「主文件只剩半截 JSON」——那样下次启动会把
  /// 整个任务列表当成损坏直接删掉，未下完的漫画全没了。
  Future<void> _writeJson(File file, Object data) async {
    try {
      var tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(data), flush: true);
      await tmp.rename(file.path);
    } catch (e, s) {
      Log.error("LocalManager", "Failed to write ${file.name}: $e", s);
    }
  }

  void restoreDownloadingTasks() {
    var file = File(FilePath.join(App.dataPath, tasksFileName));
    if (file.existsSync()) {
      try {
        var tasks = jsonDecode(file.readAsStringSync());
        if (tasks is List) {
          for (var e in tasks) {
            // 单个任务解析失败（源被删了、某个字段对不上）只跳过它，
            // 不能因为一条坏记录就把整份任务表删掉——那样用户已下的
            // 几十 GB 会瞬间变成「没有任务」。
            try {
              var task = DownloadTask.fromJson(Map<String, dynamic>.from(e));
              if (task != null) {
                downloadingTasks.add(task);
              } else {
                Log.error(
                  "LocalManager",
                  "Skip unknown downloading task: ${e['type']}",
                );
              }
            } catch (e, s) {
              Log.error("LocalManager", "Failed to restore one task: $e", s);
            }
          }
        }
      } catch (e) {
        // 整个文件坏了（写到一半断电之类）：留一份 .bak 方便排查，
        // 不要直接删。
        try {
          file.renameSync('${file.path}.bak');
        } catch (_) {}
        Log.error("LocalManager", "Failed to restore downloading tasks: $e");
      }
    }
    _applySavedProgress();
    // 进度文件里存的是「上次落盘那一刻」的数字。进程被强杀（从最近任务里
    // 划掉、系统清内存）时可能落后几页，甚至整段丢失——用户看到的就成了
    // 「明明下了一半，回来变成 0%」。恢复后先按目录扫一遍，以磁盘为准。
    for (var task in downloadingTasks) {
      unawaited(task.reconcileProgress());
    }
    Log.info(
      "LocalManager",
      "Restored ${downloadingTasks.length} downloading tasks",
    );
    // 上次没下完的接着下。用户之前手动暂停过的（userPaused）保持暂停，
    // 剩下的是「排到一半进程被杀」，属于断点续传该管的部分。
    pumpQueue();
  }

  /// 把进度文件盖回任务定义上。
  ///
  /// 定义文件只在结构变化时写（新任务、图片列表拉回来、暂停、取消），
  /// 所以「下到第几页」这类高频变化都在这里。读不到不影响：磁盘扫描会
  /// 在真正开始下之前把进度重算一遍。
  void _applySavedProgress() {
    var file = File(FilePath.join(App.dataPath, progressFileName));
    if (!file.existsSync()) {
      return;
    }
    try {
      var map = jsonDecode(file.readAsStringSync());
      if (map is! Map) {
        return;
      }
      for (var task in downloadingTasks) {
        var entry = map[task.progressKey];
        if (entry is Map) {
          var json = Map<String, dynamic>.from(entry);
          // 只认这个任务自己写的那份（见 DownloadTask.acceptsProgress）。
          if (!task.acceptsProgress(json)) {
            continue;
          }
          task.applyProgressJson(json);
        }
      }
    } catch (e) {
      Log.error("LocalManager", "Failed to restore download progress: $e");
    }
  }

  void addTask(DownloadTask task) {
    var pendingPurge = _purging[task.progressKey];
    if (pendingPurge != null) {
      // 这本刚取消，旧任务还在删文件。等它删完再建新任务：现在就去扫磁盘
      // 会把那批马上要消失的页当成「已下过」，下完缺一大段。
      unawaited(pendingPurge.whenComplete(() => addTask(task)));
      return;
    }
    var existing = findTask(task.id, task.comicType);
    if (existing != null) {
      // 同一本已经在队列里（暂停中 / 出错等重试 / 上次取消没删干净）。
      // 以前这里直接 `add` 失败就结束：用户点了「下载」，界面弹「已开始」，
      // 实际上什么都没发生。现在把暂停和错误状态清掉，接着下。
      existing.userPaused = false;
      _notifyTasksChanged();
      saveCurrentDownloadingTasks(full: true);
      existing.resume();
      pumpQueue();
      return;
    }
    downloadingTasks.add(task);
    _notifyTasksChanged();
    saveCurrentDownloadingTasks(full: true);
    pumpQueue();
  }

  /// 任务增删/启停之后统一走这里。
  ///
  /// 除了通知界面，还要让前台服务跟上：有任务在跑就把进程提到前台优先级，
  /// 全停了就摘掉通知。逐页的进度变化不走这条（那频率下探前台服务会被
  /// 系统限流），由前台服务自己的秒级 ticker 刷。
  void _notifyTasksChanged() {
    notifyListeners();
    DownloadBackground.instance.refresh();
  }

  /// 前台服务要展示的汇总。
  DownloadSummary downloadSummary() {
    var running = 0;
    var queued = 0;
    var waiting = 0;
    var speed = 0;
    var progress = 0.0;
    String? title;
    for (var task in downloadingTasks) {
      if (task.isError) {
        // 出错待重试的也算「有活」：网络回来还要接着下，前台服务不能摘。
        if (!task.userPaused) {
          waiting++;
        }
        continue;
      }
      if (task.isPaused) {
        if (!task.userPaused) {
          queued++;
        }
        continue;
      }
      running++;
      speed += task.speed;
      title ??= task.title;
      // 百分比按页数算（task.progress），不按字节估算：整本的体积是「已下
      // 页外推」出来的，一页长条图就能让它从 100MB 跳到几个 G。多条任务时
      // 取平均，进度条整体走势仍然单调向上。
      progress += task.progress.clamp(0.0, 1.0);
    }
    return DownloadSummary(
      running: running,
      queued: queued,
      waiting: waiting,
      speed: speed,
      progress: running > 0 ? (progress / running).clamp(0.0, 1.0) : 0,
      title: title,
    );
  }

  /// 这本漫画如果还在下载队列里，先停掉。
  ///
  /// 不停的话两个方向都会出错：下载那边会继续往刚删掉的目录里写文件，
  /// 下完了还会走 `completeTask` → `add()` 把这本书重新插回库——用户看到
  /// 的就是「删了又自己回来了」。
  ///
  /// [keepFiles] 对应删除对话框里「同时删除磁盘文件」没勾的情况：那种时候
  /// 文件得留着，不能被取消顺手删掉。
  void _cancelTaskFor(String id, ComicType type, {bool keepFiles = false}) {
    var task = findTask(id, type);
    if (task == null) {
      return;
    }
    task.keepFilesOnCancel = keepFiles;
    // 这里不 await：cancel 的同步部分已经把任务从队列摘掉、后续写入都停了，
    // 删目录的活儿让它自己异步跑完，UI 不必等。
    unawaited(task.cancel());
  }

  void deleteComic(LocalComic c, [bool removeFileOnDisk = true]) {
    _cancelTaskFor(c.id, c.comicType, keepFiles: !removeFileOnDisk);
    if (removeFileOnDisk) {
      // 用 baseDir 而不是 `join(path, directory)`：手工导入 / 搬过库的记录里
      // `directory` 存的是绝对路径，拼上去会得到一个不存在的路径，于是
      // `deleteIgnoreError` 静默什么都不做，文件全留下。
      Directory(c.baseDir).deleteIgnoreError(recursive: true);
    }
    // Deleting a local comic means that it's no longer available, thus both favorite and history should be deleted.
    if (c.comicType == ComicType.local) {
      if (HistoryManager().find(c.id, c.comicType) != null) {
        HistoryManager().remove(c.id, c.comicType);
      }
      var folders = LocalFavoritesManager().find(c.id, c.comicType);
      for (var f in folders) {
        LocalFavoritesManager().deleteComicWithId(f, c.id, c.comicType);
      }
    }
    remove(c.id, c.comicType);
    notifyListeners();
  }

  void deleteComicChapters(LocalComic c, List<String> chapters) {
    if (chapters.isEmpty) {
      return;
    }
    var newDownloadedChapters = c.downloadedChapters
        .where((e) => !chapters.contains(e))
        .toList();
    if (newDownloadedChapters.isNotEmpty) {
      _db.execute(
        'UPDATE comics SET downloadedChapters = ? WHERE id = ? AND comic_type = ?;',
        [jsonEncode(newDownloadedChapters), c.id, c.comicType.value],
      );
    } else {
      _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
        c.id,
        c.comicType.value,
      ]);
    }
    var shouldRemovedDirs = <Directory>[];
    for (var chapter in chapters) {
      // 和读图、对账用同一套解析：老目录可能是按标题建的，只认 id 会删不掉。
      var dir = resolveChapterDirectory(
        c.baseDir,
        chapter,
        c.chapters?.allChapters[chapter],
      );
      if (dir.existsSync()) {
        shouldRemovedDirs.add(dir);
      }
    }
    if (shouldRemovedDirs.isNotEmpty) {
      _deleteDirectories(shouldRemovedDirs);
    }
    notifyListeners();
  }

  void batchDeleteComics(
    List<LocalComic> comics, [
    bool removeFileOnDisk = true,
    bool removeFavoriteAndHistory = true,
  ]) {
    if (comics.isEmpty) {
      return;
    }

    var shouldRemovedDirs = <Directory>[];
    for (var c in comics) {
      _cancelTaskFor(c.id, c.comicType, keepFiles: !removeFileOnDisk);
    }
    _db.execute('BEGIN TRANSACTION;');
    try {
      for (var c in comics) {
        if (removeFileOnDisk) {
          // 同 deleteComic：绝对路径的记录只能按 baseDir 找。
          var dir = Directory(c.baseDir);
          if (dir.existsSync()) {
            shouldRemovedDirs.add(dir);
          }
        }
        _db.execute('DELETE FROM comics WHERE id = ? AND comic_type = ?;', [
          c.id,
          c.comicType.value,
        ]);
      }
    } catch (e, s) {
      Log.error("LocalManager", "Failed to batch delete comics: $e", s);
      _db.execute('ROLLBACK;');
      return;
    }
    _db.execute('COMMIT;');

    var comicIDs = comics.map((e) => ComicID(e.comicType, e.id)).toList();

    if (removeFavoriteAndHistory) {
      LocalFavoritesManager().batchDeleteComicsInAllFolders(comicIDs);
      HistoryManager().batchDeleteHistories(comicIDs);
    }

    notifyListeners();

    if (removeFileOnDisk) {
      _deleteDirectories(shouldRemovedDirs);
    }
  }

  /// Deletes the directories in a separate isolate to avoid blocking the UI thread.
  static void _deleteDirectories(List<Directory> directories) {
    Isolate.run(() async {
      await SAFTaskWorker().init();
      for (var dir in directories) {
        try {
          if (dir.existsSync()) {
            await dir.delete(recursive: true);
          }
        } catch (e) {
          continue;
        }
      }
    });
  }

  static String getChapterDirectoryName(String name) {
    var builder = StringBuffer();
    for (var i = 0; i < name.length; i++) {
      var char = name[i];
      if (char == '/' ||
          char == '\\' ||
          char == ':' ||
          char == '*' ||
          char == '?' ||
          char == '"' ||
          char == '<' ||
          char == '>' ||
          char == '|') {
        builder.write('_');
      } else {
        builder.write(char);
      }
    }
    return builder.toString();
  }
}

/// 文件名是不是「正文页」。
///
/// 下载写下的图一律以页码命名（`0.jpg`、`12.webp`），封面是 `cover.*`，
/// 隐藏文件和 json 都不算。取消下载后重算「还剩哪些章节」、以及清理残留
/// 目录时都靠这条判断，别在两处各写一遍。
bool isPageFileName(String name) {
  if (name.startsWith('.')) {
    return false;
  }
  if (name.startsWith('cover')) {
    return false;
  }
  var dot = name.lastIndexOf('.');
  var stem = dot <= 0 ? name : name.substring(0, dot);
  if (stem.isEmpty) {
    return false;
  }
  return int.tryParse(stem) != null;
}

/// 把本地已经落盘的页和远端页表拼起来，返回阅读器要的图片列表。
///
/// [local] 的 key 是文件名里的页码，不是「第几个文件」：下载中途失败过一页
/// 时本地会缺 key，缺的那几页由 [remote] 补上，位置不会整体串位。老版本下载
/// 的文件可能从 1 开始编号，按最小页码整体平移一次。
List<String> mergeLocalPages(Map<int, String> local, List<String> remote) {
  if (local.isEmpty) {
    return remote;
  }
  var first = local.keys.first;
  for (var key in local.keys) {
    if (key < first) {
      first = key;
    }
  }
  var offset = first > 0 && !local.containsKey(0) ? first : 0;
  return [
    for (var i = 0; i < remote.length; i++) local[i + offset] ?? remote[i],
  ];
}

enum LocalSortType {
  name("name"),
  titleAZ("title_az"),
  timeAsc("time_asc"),
  timeDesc("time_desc");

  final String value;

  const LocalSortType(this.value);

  static LocalSortType fromString(String value) {
    for (var type in values) {
      if (type.value == value) {
        return type;
      }
    }
    return name;
  }
}

/// 看门狗判定：这条出错的任务该不该在这一轮巡查里被重新拉起来。
///
/// 抽成纯函数是为了能测：真跑 `Timer.periodic` 的用例既慢又不稳，而这里
/// 真正的规则只有「出错 + 不是用户暂停 + 距上次尝试够久」三条。
/// 看门狗重试节奏：前十次一分钟一次（断网一两分钟就能自己接上），之后降到
/// 五分钟一次 —— 源站真挂了的时候，没必要每分钟都开着 wakelock 去试。
int watchdogRetryInterval(int attempts) {
  return attempts < 10 ? LocalManager.watchdogRetryIntervalMs : 5 * 60 * 1000;
}

bool shouldRetryErroredTask({
  required bool isError,
  required bool userPaused,
  required int nowMs,
  required int lastAttemptMs,
  int intervalMs = LocalManager.watchdogRetryIntervalMs,
}) {
  if (!isError || userPaused) {
    return false;
  }
  if (lastAttemptMs <= 0) {
    return true;
  }
  return nowMs - lastAttemptMs >= intervalMs;
}
