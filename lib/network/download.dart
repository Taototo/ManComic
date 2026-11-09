import 'dart:async';
import 'dart:isolate';

import 'package:flutter/widgets.dart' show ChangeNotifier;
import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_details_cache.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/images.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:zip_flutter/zip_flutter.dart';

import 'file_downloader.dart';

abstract class DownloadTask with ChangeNotifier {
  /// 0-1
  double get progress;

  bool get isError;

  bool get isPaused;

  /// 用户主动按下暂停。
  ///
  /// 必须和「排队等待」区分开：两者 [_isRunning] 都是 false，但排队中的任务
  /// 该被调度器自动拉起来，手动暂停的不行，否则用户按暂停毫无作用。
  bool userPaused = false;

  /// 已写入磁盘的字节数（估算进度用，任务刚建好时为 0）
  int get downloadedBytes;

  /// 预计总字节数。下载过程中只能估算，全部完成后才是准确值；未知时为 0。
  int get totalBytes;

  /// bytes per second
  int get speed;

  void cancel();

  void pause();

  void resume();

  String get title;

  String? get cover;

  String get message;

  /// root path for the comic. If null, the task is not scheduled.
  String? path;

  /// convert current state to json, which can be used to restore the task
  Map<String, dynamic> toJson();

  /// 只含「进度」的小快照，和 [toJson] 分两个文件存。
  ///
  /// [toJson] 里有整本的图片地址表，一部中长篇就是几百 KB；每下一页写一次
  /// 会让主线程反复做 jsonEncode + 落盘，多任务并发时下载页直接卡住。
  /// 进度本身只有几个数字，可以随便写。
  Map<String, dynamic> toProgressJson() => {"userPaused": userPaused};

  /// 把 [toProgressJson] 的结果盖回任务上。
  void applyProgressJson(Map<String, dynamic> json) {
    userPaused = json["userPaused"] ?? userPaused;
  }

  /// 进度文件里的键。用「类型 + id」而不是列表下标，任务重排不会串。
  String get progressKey => "${comicType.value}:$id";

  LocalComic toLocalComic();

  String get id;

  ComicType get comicType;

  static DownloadTask? fromJson(Map<String, dynamic> json) {
    switch (json["type"]) {
      case "ImagesDownloadTask":
        return ImagesDownloadTask.fromJson(json);
      case "ArchiveDownloadTask":
        return ArchiveDownloadTask.fromJson(json);
      default:
        return null;
    }
  }

  @override
  bool operator ==(Object other) {
    return other is DownloadTask &&
        other.id == id &&
        other.comicType == comicType;
  }

  @override
  int get hashCode => Object.hash(id, comicType);
}

class ImagesDownloadTask extends DownloadTask with _TransferSpeedMixin {
  final ComicSource source;

  final String comicId;

  /// comic details. If null, the comic details will be fetched from the source.
  ComicDetails? comic;

  /// chapters to download. If null, all chapters will be downloaded.
  final List<String>? chapters;

  @override
  String get id => comicId;

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  String? comicTitle;

  ImagesDownloadTask({
    required this.source,
    required this.comicId,
    this.comic,
    this.chapters,
    this.comicTitle,
  });

  @override
  void cancel() {
    _isRunning = false;
    _cancelled = true;
    _retryTimer?.cancel();
    _retryTimer = null;
    LocalManager().removeTask(this);
    var local = LocalManager().find(id, comicType);
    if (path != null) {
      if (local == null) {
        Future.sync(() async {
          var tasks = this.tasks.values.toList();
          for (var i = 0; i < tasks.length; i++) {
            if (!tasks[i].isComplete) {
              tasks[i].cancel();
              await tasks[i].wait();
            }
          }
          try {
            await Directory(path!).delete(recursive: true);
          }
          catch(e) {
            Log.error("Download", "Failed to delete directory: $e");
          }
        });
      } else if (chapters != null) {
        for (var c in chapters!) {
          var dir = Directory(FilePath.join(path!, c));
          if (dir.existsSync()) {
            dir.deleteSync(recursive: true);
          }
        }
      }
    }
  }

  @override
  String? get cover => _cover ?? comic?.cover;

  @override
  String get message => _message;

  @override
  void pause() {
    if (isPaused) {
      return;
    }
    userPaused = true;
    _isRunning = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    _message = "Paused";
    _currentSpeed = 0;
    var shouldMove = <int>[];
    for (var entry in tasks.entries) {
      if (!entry.value.isComplete) {
        entry.value.cancel();
        shouldMove.add(entry.key);
      }
    }
    for (var i in shouldMove) {
      tasks.remove(i);
    }
    stopRecorder();
    notifyListeners();
    // 单个任务的暂停以前不落盘：pause() 只改了内存，进程一被杀就变回
    // 「排队中」，重启后自己又跑起来。用户按的暂停得记得住。
    LocalManager().saveDownloadProgressNow();
  }

  @override
  double get progress => _totalCount == 0 ? 0 : _downloadedCount / _totalCount;

  @override
  int get downloadedBytes => _downloadedBytes;

  @override
  int get totalBytes => estimateTotalBytes(
        downloadedBytes: _downloadedBytes,
        downloadedCount: _downloadedCount,
        totalCount: _totalCount,
      );

  void _addDownloadedBytes(int bytes) {
    if (bytes <= 0) {
      return;
    }
    _downloadedBytes += bytes;
  }

  bool _isRunning = false;

  bool _isError = false;

  String _message = "Fetching comic info...";

  String? _cover;

  /// All images to download, key is chapter name
  Map<String, List<String>>? _images;

  /// Downloaded image count
  int _downloadedCount = 0;

  /// Total image count
  int _totalCount = 0;

  /// Bytes written to disk so far
  int _downloadedBytes = 0;

  /// Current downloading image index
  int _index = 0;

  /// Current downloading chapter, index of [_images]
  int _chapter = 0;

  /// 任务已被取消。取消之后不要再被自动重试拉起来。
  bool _cancelled = false;

  /// 本次运行里已经自动重试过几次（每次手动 resume 清零）
  int _autoRetry = 0;

  Timer? _retryTimer;

  var tasks = <int, _ImageDownloadWrapper>{};

  /// 每章已经在磁盘上的页码。恢复下载时扫一次，之后随下载进度递增。
  ///
  /// 断点续传的旧做法是「信 JSON 里的 `_index`」：进程在「写完文件、还没
  /// 记账」之间被杀，那一页就白下；在「记完账、文件没落盘」之间被杀，
  /// 那一页就永远缺一张。改成以磁盘为准，两种都能自愈。
  final _diskPages = <String, Set<int>>{};

  int get _maxConcurrentTasks {
    var value = appdata.settings["downloadThreads"];
    var threads = value is num ? value.toInt() : 5;
    return threads.clamp(1, 16);
  }

  /// 最多同时向源站要几章图地址表。
  ///
  /// 原来是一章一章串行问，一百章的书要等一百次往返才开始下第一张图，
  /// 用户看到的就是「点了下载半天没动静」。地址表之间互不依赖，并发问
  /// 没有顺序问题；3 是折中，太高容易被源站限流。
  static const _imageListConcurrency = 3;

  String _chapterDirPath(String chapterName) {
    if (comic?.chapters == null) {
      return path!;
    }
    return FilePath.join(
      path!,
      LocalManager.getChapterDirectoryName(chapterName),
    );
  }

  Directory _ensureChapterDir(String chapterName) {
    var dir = Directory(_chapterDirPath(chapterName));
    if (comic?.chapters != null && !dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  /// 扫一章目录，拿到「哪些页码已经是一张完整的图」。
  ///
  /// 只认「文件名是数字 + 大小非 0」：写文件时已经校验过图片完整性，
  /// 所以 0 字节就代表上次写到一半被打断，当作没下过重新下。
  Future<Set<int>> _scanChapterPages(String chapterName) async {
    var pages = <int>{};
    try {
      var dir = Directory(_chapterDirPath(chapterName));
      if (!await dir.exists()) {
        return pages;
      }
      await for (var entity in dir.list(followLinks: false)) {
        if (entity is! File) {
          continue;
        }
        var name = entity.name;
        if (name.startsWith('cover.') ||
            name.startsWith('.') ||
            name.endsWith('.json')) {
          continue;
        }
        var index = int.tryParse(name.split('.').first);
        if (index == null) {
          continue;
        }
        if (await entity.length() > 0) {
          pages.add(index);
        }
      }
    } catch (e) {
      Log.error("Download", "Failed to scan chapter $chapterName: $e");
    }
    return pages;
  }

  Future<Set<int>> _pagesOnDisk(String chapterName) async {
    return _diskPages[chapterName] ??= await _scanChapterPages(chapterName);
  }

  /// 用磁盘上的实际文件重建进度，并把游标挪到第一个缺页。
  ///
  /// 恢复时的「快」就来自这里：不用从上次记账的位置重新下一遍，也不用
  /// 清空目录重来。整本扫一遍目录，缺哪页补哪页。
  Future<void> _reconcileWithDisk() async {
    if (_images == null || path == null) {
      return;
    }
    // 每次恢复都重扫：暂停/取消发生在写盘中途时，`_diskPages` 可能和
    // 真实目录对不上，缓存不清就会一直沿用旧结论（该下的页被当成已下）。
    _diskPages.clear();
    var pageCounts = <int>[];
    var existing = <List<int>>[];
    for (var entry in _images!.entries) {
      pageCounts.add(entry.value.length);
      existing.add((await _pagesOnDisk(entry.key)).toList());
    }
    var point = computeResumePoint(
      pageCounts: pageCounts,
      existingPages: existing,
    );
    _totalCount = point.total;
    _downloadedCount = point.downloaded;
    // 全部都在磁盘上了（上次下完但没来得及入库）：游标推到末尾，让下面
    // 的循环立刻结束并入库。
    _chapter = point.chapter;
    _index = point.index;
    _message = "$_downloadedCount/$_totalCount";
    notifyListeners();
  }

  void _scheduleTasks() {
    var chapterName = _images!.keys.elementAt(_chapter);
    var images = _images![chapterName]!;
    var downloaded = _diskPages[chapterName] ?? const <int>{};
    var downloading = 0;
    for (var i = _index; i < images.length; i++) {
      // 磁盘上已经有这一页就别再下：恢复时靠这条跳过已完成的页，
      // 中途失败的洞也不会拖着重下整章。
      if (downloaded.contains(i)) {
        continue;
      }
      if (tasks[i] != null) {
        if (!tasks[i]!.isComplete) {
          downloading++;
        }
        if (tasks[i]!.error == null) {
          continue;
        }
      }
      if (downloading >= _maxConcurrentTasks) {
        return;
      }
      var task = _ImageDownloadWrapper(
        this,
        chapterName,
        images[i],
        _ensureChapterDir(chapterName),
        i,
      );
      tasks[i] = task;
      task.wait().then((task) {
        if (task.isComplete) {
          _scheduleTasks();
        }
      });
      downloading++;
    }
  }

  @override
  void resume({bool automatic = false}) async {
    if (_isRunning || _cancelled) return;
    if (!automatic) {
      // 手动点的「重试」把自动重试额度也清掉：这次失败是新的开始
      _autoRetry = 0;
    }
    _isError = false;
    userPaused = false;
    _message = "Resuming...";
    _isRunning = true;
    notifyListeners();
    runRecorder();
    LocalManager().saveCurrentDownloadingTasks();

    if (comic == null) {
      _message = "Fetching comic info...";
      notifyListeners();
      var res = await _runWithRetry(() async {
        var r = await source.loadComicInfo!(comicId);
        if (r.error) {
          throw r.errorMessage!;
        } else {
          return r.data;
        }
      });
      if (!_isRunning) {
        return;
      }
      if (res.error) {
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        comic = res.data;
      }
    }

    if (path == null) {
      try {
        var dir = await LocalManager().findValidDirectory(
          comicId,
          comicType,
          comic!.title,
        );
        if (!(await dir.exists())) {
          await dir.create();
        }
        path = dir.path;
      } catch (e, s) {
        Log.error("Download", e.toString(), s);
        _setError("Error: $e");
        return;
      }
    }

    // 详情页也一起存下去。已下载的漫画在列表里点封面打开的是在线源详情页，
    // 断网时那页只会显示错误页——章节明明都在本地。这里在目录刚建好时就把
    // ComicDetails 写进 <漫画目录>/details.json，取消下载时目录被删，快照
    // 跟着消失，不需要额外的清理逻辑。
    ComicDetailsCache.save(comic!, comicType, directory: path);

    await LocalManager().saveCurrentDownloadingTasks(full: true);

    // 上次中断可能把半张封面留在了磁盘上：记录里写着「封面已下载」，文件
    // 却解不出来。这里先验一遍，不通过就当没下过——否则 `_cover != null`
    // 会让封面下载被整个跳过，用户看到的永远是「封面加载失败」，重下也
    // 修不回来（这正是「下载断开后封面消失、下完还是错」的根因）。
    if (_cover != null && !await _coverFileIsUsable(_cover!)) {
      _cover = null;
      await LocalManager().saveCurrentDownloadingTasks(full: true);
    }

    if (_cover == null) {
      _message = "Downloading cover...";
      notifyListeners();
      var res = await _runWithRetry(() async {
        Uint8List? data;
        await for (var progress
            in ImageDownloader.loadThumbnail(comic!.cover, source.key)) {
          if (progress.imageBytes != null) {
            data = progress.imageBytes;
          }
        }
        if (data == null || data.isEmpty) {
          throw "Failed to download cover";
        }
        // 半张图不能落地：宁可重试，也不要留下一个永远打不开的封面文件。
        if (!isCompleteImageBytes(data)) {
          throw "Incomplete cover image";
        }
        var fileType = detectFileType(data);
        if (fileType.ext.isEmpty) {
          // 认不出格式说明拿到的多半不是图片（错误页 HTML 之类），
          // 存成没有扩展名的 cover 还会被当成正文页遍历到。
          throw "Failed to detect cover file type";
        }
        var file = File(FilePath.join(path!, "cover${fileType.ext}"));
        file.writeAsBytesSync(data);
        _deleteStaleCovers(file.name);
        return "file://${file.path}";
      });
      if (res.error) {
        Log.error("Download", res.errorMessage!);
        _setError("Error: ${res.errorMessage}");
        return;
      } else {
        _cover = res.data;
        notifyListeners();
      }
      await LocalManager().saveCurrentDownloadingTasks(full: true);
    }

    if (_images == null) {
      if (comic!.chapters == null) {
        _message = "Fetching image list...";
        notifyListeners();
        var res = await _runWithRetry(() async {
          var r = await source.loadComicPages!(comicId, null);
          if (r.error) {
            throw r.errorMessage!;
          } else {
            return r.data;
          }
        });
        if (!_isRunning) {
          return;
        }
        if (res.error) {
          Log.error("Download", res.errorMessage!);
          _setError("Error: ${res.errorMessage}");
          return;
        } else {
          _images = {'': res.data};
          _totalCount = _images!['']!.length;
        }
      } else {
        _images = {};
        _totalCount = 0;
        var pending = <String>[];
        for (var i in comic!.chapters!.allChapters.keys) {
          if (chapters != null && !chapters!.contains(i)) {
            continue;
          }
          pending.add(i);
        }
        var totalCpCount = pending.length;
        var done = 0;
        // 一次问 3 章，谁先回来先记账。原来是串行问，一百章的书要等一百次
        // 往返才见到第一张图，用户以为卡死了；地址表之间没有依赖，并发问
        // 不会打乱章节顺序（结果按 key 存 Map）。
        while (pending.isNotEmpty) {
          if (!_isRunning) {
            return;
          }
          var batch = pending.take(_imageListConcurrency).toList();
          _message =
              "Fetching image list ($done/$totalCpCount)...";
          notifyListeners();
          var results = await Future.wait(batch.map((chapter) async {
            var res = await _runWithRetry(() async {
              var r = await source.loadComicPages!(comicId, chapter);
              if (r.error) {
                throw r.errorMessage!;
              } else {
                return r.data;
              }
            });
            return MapEntry(chapter, res);
          }));
          for (var entry in results) {
            if (entry.value.error) {
              Log.error("Download", entry.value.errorMessage!);
              _setError("Error: ${entry.value.errorMessage}");
              return;
            }
            _images![entry.key] = entry.value.data;
            _totalCount += entry.value.data.length;
            pending.remove(entry.key);
            done++;
          }
        }
      }
      _message = "$_downloadedCount/$_totalCount";
      notifyListeners();
      await LocalManager().saveCurrentDownloadingTasks(full: true);
    }

    // 以磁盘为准重建进度：进程被杀时「写完没记账」「记完账没落盘」两种
    // 半成品都在这里被抹平，缺哪页补哪页。
    await _reconcileWithDisk();
    if (!_isRunning) {
      return;
    }

    while (_chapter < _images!.length) {
      var chapterName = _images!.keys.elementAt(_chapter);
      var images = _images![chapterName]!;
      var onDisk = _diskPages[chapterName] ?? const <int>{};
      tasks.clear();
      while (_index < images.length) {
        if (onDisk.contains(_index)) {
          _index++;
          continue;
        }
        _scheduleTasks();
        var task = tasks[_index];
        if (task == null) {
          // 理论上每个待下的页码都会建 wrapper；拿不到说明这一页既不在
          // 磁盘也不在队列里，跳过比崩掉强。
          _index++;
          continue;
        }
        await task.wait();
        if (isPaused) {
          return;
        }
        if (task.error != null) {
          Log.error("Download", task.error.toString());
          _setError("Error: ${task.error}", autoRetry: true);
          return;
        }
        (_diskPages[chapterName] ??= <int>{}).add(_index);
        _index++;
        _downloadedCount++;
        _message = "$_downloadedCount/$_totalCount";
        // 逐页只写小体积的进度快照，并且在一秒多内合并成一次落盘。
        // 原来每页都把整本的图片地址表 encode 一次，多任务并发时主线程
        // 全耗在这上面，下载页就卡了。
        LocalManager().saveCurrentDownloadingTasks();
      }
      _index = 0;
      _chapter++;
    }

    LocalManager().completeTask(this);
    stopRecorder();
  }

  @override
  void onNextSecond(Timer t) {
    notifyListeners();
    super.onNextSecond(t);
  }

  void _setError(String message, {bool autoRetry = false}) {
    _isRunning = false;
    _isError = true;
    _message = message;
    notifyListeners();
    stopRecorder();
    if (!autoRetry || _autoRetry >= 2 || userPaused || _cancelled) {
      return;
    }
    // 网络抖一下不该让整个任务停在那儿等用户来点。隔几秒自己再试，
    // 恢复时会按磁盘重算进度，已经下好的页不会重下。
    _autoRetry++;
    var delay = Duration(seconds: _autoRetry == 1 ? 5 : 15);
    _message = "$message, retrying in ${delay.inSeconds}s";
    notifyListeners();
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      if (userPaused || _cancelled || _isRunning) {
        return;
      }
      resume(automatic: true);
    });
  }

  /// 记录里的封面还能不能用。
  ///
  /// 只认「文件在 + 是一张完整的图」。中断时写了一半的文件、0 字节文件
  /// 都会在这里被否掉，交给下面重新下载。
  Future<bool> _coverFileIsUsable(String url) async {
    try {
      if (!url.startsWith("file://")) {
        return false;
      }
      var file = File(url.substring(7));
      if (!file.existsSync()) {
        return false;
      }
      var bytes = await file.readAsBytes();
      return isCompleteImageBytes(bytes);
    } catch (_) {
      return false;
    }
  }

  /// 换扩展名重下封面时，把旧的 `cover.*` 清掉。
  ///
  /// 不清也不影响显示（本地记录里存的是新文件名），但目录里会堆出
  /// cover.jpg / cover.webp 两份互不相同的东西，导出和排查都很迷惑。
  void _deleteStaleCovers(String keepName) {
    try {
      for (var entity in Directory(path!).listSync()) {
        if (entity is File &&
            entity.name.startsWith('cover') &&
            entity.name != keepName) {
          entity.deleteIgnoreError();
        }
      }
    } catch (e) {
      Log.error("Download", "Failed to clean stale covers: $e");
    }
  }

  @override
  int get speed => currentSpeed;

  @override
  String get title => comic?.title ?? comicTitle ?? "Loading...";

  @override
  Map<String, dynamic> toProgressJson() => {
        "cover": _cover,
        "chapter": _chapter,
        "index": _index,
        "downloadedCount": _downloadedCount,
        "downloadedBytes": _downloadedBytes,
        "totalCount": _totalCount,
        "userPaused": userPaused,
      };

  @override
  void applyProgressJson(Map<String, dynamic> json) {
    _cover = json["cover"] ?? _cover;
    _chapter = json["chapter"] ?? _chapter;
    _index = json["index"] ?? _index;
    _downloadedCount = json["downloadedCount"] ?? _downloadedCount;
    _downloadedBytes = json["downloadedBytes"] ?? _downloadedBytes;
    _totalCount = json["totalCount"] ?? _totalCount;
    userPaused = json["userPaused"] ?? userPaused;
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ImagesDownloadTask",
      "source": source.key,
      "comicId": comicId,
      "comic": comic?.toJson(),
      "chapters": chapters,
      "path": path,
      "cover": _cover,
      "images": _images,
      "downloadedCount": _downloadedCount,
      "downloadedBytes": _downloadedBytes,
      "totalCount": _totalCount,
      "index": _index,
      "chapter": _chapter,
      "userPaused": userPaused,
    };
  }

  static ImagesDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ImagesDownloadTask") {
      return null;
    }

    Map<String, List<String>>? images;
    if (json["images"] != null) {
      images = {};
      for (var entry in json["images"].entries) {
        images[entry.key] = List<String>.from(entry.value);
      }
    }

    return ImagesDownloadTask(
      source: ComicSource.find(json["source"])!,
      comicId: json["comicId"],
      comic:
          json["comic"] == null ? null : ComicDetails.fromJson(json["comic"]),
      chapters: ListOrNull.from(json["chapters"]),
    )
      ..path = json["path"]
      .._cover = json["cover"]
      .._images = images
      .._downloadedCount = json["downloadedCount"] ?? 0
      .._downloadedBytes = json["downloadedBytes"] ?? 0
      .._totalCount = json["totalCount"] ?? 0
      .._index = json["index"] ?? 0
      .._chapter = json["chapter"] ?? 0
      ..userPaused = json["userPaused"] ?? false;
  }

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic!.id,
      title: title,
      subtitle: comic!.subTitle ?? '',
      tags: comic!.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: comic!.chapters,
      cover: File(_cover!.split("file://").last).name,
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: chapters ?? comic?.chapters?.ids.toList() ?? [],
      createdAt: DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) {
    if (other is ImagesDownloadTask) {
      return other.comicId == comicId && other.source.key == source.key;
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(comicId, source.key);
}

/// 估算整本体积。
///
/// 漫画源不提供整本大小，逐页拉图时也拿不到后面几页的 Content-Length，
/// 所以只能用已完成的页求平均再乘总页数。误差随进度收窄，全部下完时
/// 正好退化成真实总量——不会出现「下完了还显示 ≈」的情况。
int estimateTotalBytes({
  required int downloadedBytes,
  required int downloadedCount,
  required int totalCount,
}) {
  // 图片列表还没拉回来，不知道要下多少页，此时任何数字都是编的
  if (totalCount <= 0) {
    return 0;
  }
  if (downloadedCount >= totalCount) {
    return downloadedBytes;
  }
  // 一页都没完成，没有样本可外推
  if (downloadedCount <= 0) {
    return 0;
  }
  return (downloadedBytes / downloadedCount * totalCount).round();
}

/// 恢复下载时的落点。
class ResumePoint {
  const ResumePoint({
    required this.chapter,
    required this.index,
    required this.downloaded,
    required this.total,
  });

  /// 从第几章开始（0 起）
  final int chapter;

  /// 该章第几页（0 起）
  final int index;

  /// 磁盘上已经有几页
  final int downloaded;

  /// 一共几页
  final int total;
}

/// 根据「每章有几页」和「每章磁盘上已有的页码」，算出应该从哪一页接着下。
///
/// 关键点是**以磁盘为准**而不是以 JSON 里记的游标为准：进程在「写完文件、
/// 还没记账」之间被杀，那页会白下；在「记完账、文件没落盘」之间被杀，那页
/// 会永远缺一张。按磁盘算，两种都能自愈，而且中间有洞也能补。
ResumePoint computeResumePoint({
  required List<int> pageCounts,
  required List<List<int>> existingPages,
}) {
  var total = 0;
  var downloaded = 0;
  var chapter = 0;
  var index = 0;
  var found = false;
  for (var c = 0; c < pageCounts.length; c++) {
    var count = pageCounts[c];
    total += count;
    var existing = c < existingPages.length
        ? existingPages[c].toSet()
        : const <int>{};
    for (var i = 0; i < count; i++) {
      if (existing.contains(i)) {
        downloaded++;
      } else if (!found) {
        found = true;
        chapter = c;
        index = i;
      }
    }
  }
  if (!found) {
    // 全部都在磁盘上：游标推到末尾，让调用方的循环立刻收工
    chapter = pageCounts.length;
    index = 0;
  }
  return ResumePoint(
    chapter: chapter,
    index: index,
    downloaded: downloaded,
    total: total,
  );
}

Future<Res<T>> _runWithRetry<T>(Future<T> Function() task,
    {int retry = 3}) async {  for (var i = 0; i < retry; i++) {
    try {
      return Res(await task());
    } catch (e) {
      if (i == retry - 1) {
        return Res.error(e.toString());
      }
      await Future.delayed(Duration(seconds: i + 1));
    }
  }
  throw UnimplementedError();
}

class _ImageDownloadWrapper {
  final ImagesDownloadTask task;

  final String chapter;

  final int index;

  final String image;

  final Directory saveTo;

  _ImageDownloadWrapper(
    this.task,
    this.chapter,
    this.image,
    this.saveTo,
    this.index,
  ) {
    start();
  }

  bool isComplete = false;

  String? error;

  bool isCancelled = false;

  void cancel() {
    isCancelled = true;
  }

  var completers = <Completer<_ImageDownloadWrapper>>[];

  var retry = 3;

  void start() async {
    int lastBytes = 0;
    try {
      await for (var p in ImageDownloader.loadComicImageUnwrapped(
        image,
        task.source.key,
        task.comicId,
        chapter,
        // 下载任务自己要把图写进漫画目录，再让图片缓存抄一份纯属浪费：
        // 一次下载变两次写盘，还要多一条缓存库记录。多任务并发时这部分
        // IO 是下载页卡顿的主要来源之一。
        useCache: false,
      )) {
        if (isCancelled) {
          return;
        }
        task.onData(p.currentBytes - lastBytes);
        lastBytes = p.currentBytes;
        if (p.imageBytes != null) {
          // 半张图不落地：断线时流可能干净地结束，字节数不够就是截断，
          // 丢给 catch 走重试，别让一张坏图占住这个页码。
          if (!isCompleteImageBytes(p.imageBytes!)) {
            throw "Incomplete image data for page $index";
          }
          var fileType = detectFileType(p.imageBytes!);
          var file = saveTo.joinFile("$index${fileType.ext}");
          await file.writeAsBytes(p.imageBytes!);
          // 只有真正落到磁盘上才计入体积：中途取消/失败的那张下次会重下，
          // 提前记账会让「已下载」越走越快、总面积越算越小。
          task._addDownloadedBytes(p.imageBytes!.length);
          isComplete = true;
          for (var c in completers) {
            c.complete(this);
          }
          completers.clear();
          // 收完就撤。以前这里继续把流读完：缓存命中时流会先吐一份缓存
          // 再走一遍网络，等于同一张图下两遍。
          return;
        }
      }
    } catch (e, s) {
      if (isCancelled) {
        return;
      }
      Log.error("Download", e.toString(), s);
      retry--;
      if (retry > 0) {
        // 别立刻重来：多任务并发时瞬时重试会把请求量翻几倍，源站那边
        // 正好又限一次速，越重试越慢。退一步再问。
        await Future.delayed(Duration(milliseconds: 400 * (4 - retry)));
        if (isCancelled) {
          return;
        }
        start();
        return;
      }
      error = e.toString();
      for (var c in completers) {
        if (!c.isCompleted) {
          c.complete(this);
        }
      }
    }
  }

  Future<_ImageDownloadWrapper> wait() {
    if (isComplete) {
      return Future.value(this);
    }
    var c = Completer<_ImageDownloadWrapper>();
    completers.add(c);
    return c.future;
  }
}

abstract mixin class _TransferSpeedMixin {
  int _bytesSinceLastSecond = 0;

  int _currentSpeed = 0;

  int get currentSpeed => _currentSpeed;

  Timer? timer;

  void onData(int length) {
    if (timer == null) return;
    if (length < 0) {
      return;
    }
    _bytesSinceLastSecond += length;
  }

  void onNextSecond(Timer t) {
    _currentSpeed = _bytesSinceLastSecond;
    _bytesSinceLastSecond = 0;
  }

  void runRecorder() {
    if (timer != null) {
      timer!.cancel();
    }
    _bytesSinceLastSecond = 0;
    timer = Timer.periodic(const Duration(seconds: 1), onNextSecond);
  }

  void stopRecorder() {
    timer?.cancel();
    timer = null;
    _currentSpeed = 0;
    _bytesSinceLastSecond = 0;
  }
}

class ArchiveDownloadTask extends DownloadTask {
  final String archiveUrl;

  final ComicDetails comic;

  late ComicSource source;

  /// Download comic by archive url
  ///
  /// Currently only support zip file and comics without chapters
  ArchiveDownloadTask(this.archiveUrl, this.comic) {
    source = ComicSource.find(comic.sourceKey)!;
  }

  FileDownloader? _downloader;

  String _message = "Fetching comic info...";

  bool _isRunning = false;

  bool _isError = false;

  void _setError(String message) {
    _isRunning = false;
    _isError = true;
    _message = message;
    notifyListeners();
    Log.error("Download", message);
  }

  @override
  void cancel() async {
    _isRunning = false;
    await _downloader?.stop();
    if (path != null) {
      Directory(path!).deleteIgnoreError(recursive: true);
    }
    path = null;
    LocalManager().removeTask(this);
  }

  @override
  ComicType get comicType => ComicType(source.key.hashCode);

  @override
  String? get cover => comic.cover;

  @override
  String get id => comic.id;

  @override
  bool get isError => _isError;

  @override
  bool get isPaused => !_isRunning;

  @override
  String get message => _message;

  int _currentBytes = 0;

  int _expectedBytes = 0;

  int _speed = 0;

  @override
  void pause() {
    _isRunning = false;
    userPaused = true;
    _message = "Paused";
    _downloader?.stop();
    notifyListeners();
    LocalManager().saveDownloadProgressNow();
  }

  @override
  double get progress =>
      _expectedBytes == 0 ? 0 : _currentBytes / _expectedBytes;

  @override
  int get downloadedBytes => _currentBytes;

  @override
  int get totalBytes => _expectedBytes;

  @override
  void resume() async {
    if (_isRunning) {
      return;
    }
    _isError = false;
    userPaused = false;
    _isRunning = true;
    notifyListeners();
    _message = "Downloading...";

    if (path == null) {
      var dir = await LocalManager().findValidDirectory(
        comic.id,
        comicType,
        comic.title,
      );
      if (!(await dir.exists())) {
        try {
          await dir.create();
        } catch (e) {
          _setError("Error: $e");
          return;
        }
      }
      path = dir.path;
    }

    // 同 ImagesDownloadTask：详情快照跟着漫画目录走，离线时详情页才有东西可画。
    ComicDetailsCache.save(comic, comicType, directory: path);

    var archiveFile =
        File(FilePath.join(App.dataPath, "archive_downloading.zip"));

    Log.info("Download", "Downloading $archiveUrl");

    _downloader = FileDownloader(archiveUrl, archiveFile.path);

    bool isDownloaded = false;

    try {
      await for (var status in _downloader!.start()) {
        _currentBytes = status.downloadedBytes;
        _expectedBytes = status.totalBytes;
        _message =
            "${bytesToReadableString(_currentBytes)}/${bytesToReadableString(_expectedBytes)}";
        _speed = status.bytesPerSecond;
        isDownloaded = status.isFinished;
        notifyListeners();
      }
    } catch (e) {
      _setError("Error: $e");
      return;
    }

    if (!_isRunning) {
      return;
    }

    if (!isDownloaded) {
      _setError("Error: Download failed");
      return;
    }

    try {
      await _extractArchive(archiveFile.path, path!);
    } catch (e) {
      _setError("Failed to extract archive: $e");
      return;
    }

    await archiveFile.deleteIgnoreError();

    LocalManager().completeTask(this);
  }

  static Future<void> _extractArchive(String archive, String outDir) async {
    var out = Directory(outDir);
    if (out is AndroidDirectory) {
      // Saf directory can't be accessed by native code.
      var cacheDir = FilePath.join(App.cachePath, "archive_downloading");
      Directory(cacheDir).forceCreateSync();
      await Isolate.run(() {
        ZipFile.openAndExtract(archive, cacheDir);
      });
      await copyDirectoryIsolate(Directory(cacheDir), Directory(outDir));
      await Directory(cacheDir).deleteIgnoreError(recursive: true);
    } else {
      await Isolate.run(() {
        ZipFile.openAndExtract(archive, outDir);
      });
    }
  }

  @override
  int get speed => _speed;

  @override
  String get title => comic.title;

  @override
  Map<String, dynamic> toJson() {
    return {
      "type": "ArchiveDownloadTask",
      "archiveUrl": archiveUrl,
      "comic": comic.toJson(),
      "path": path,
      "userPaused": userPaused,
    };
  }

  static ArchiveDownloadTask? fromJson(Map<String, dynamic> json) {
    if (json["type"] != "ArchiveDownloadTask") {
      return null;
    }
    return ArchiveDownloadTask(
      json["archiveUrl"],
      ComicDetails.fromJson(json["comic"]),
    )
      ..path = json["path"]
      ..userPaused = json["userPaused"] ?? false;
  }

  String _findCover() {
    var files = Directory(path!).listSync();
    for (var f in files) {
      if (f.name.startsWith('cover')) {
        return f.name;
      }
    }
    files.sort((a, b) {
      return a.name.compareTo(b.name);
    });
    return files.first.name;
  }

  @override
  LocalComic toLocalComic() {
    return LocalComic(
      id: comic.id,
      title: title,
      subtitle: comic.subTitle ?? '',
      tags: comic.tags.entries.expand((e) {
        return e.value.map((v) => "${e.key}:$v");
      }).toList(),
      directory: Directory(path!).name,
      chapters: null,
      cover: _findCover(),
      comicType: ComicType(source.key.hashCode),
      downloadedChapters: [],
      createdAt: DateTime.now(),
    );
  }
}
