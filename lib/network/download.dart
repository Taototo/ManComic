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

  /// 用磁盘上的真实内容校正进度。
  ///
  /// 恢复出来的数字只是「上次落盘那一刻」的，进程被强杀时可能落后几页，
  /// 甚至整段丢失（进度文件还没轮到写）。重启后先按目录扫一遍，界面上就
  /// 不会出现「明明下了一半却显示 0%」。默认什么都不做。
  Future<void> reconcileProgress() async {}

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
        recentPageBytes: _pageSizes,
      );

  void _addDownloadedBytes(int bytes) {
    if (bytes <= 0) {
      return;
    }
    _downloadedBytes += bytes;
    // 留一份最近的每页大小当样本。第一页正好是长条大图时，用「累计字节
    // ÷ 已完成页数」外推会直接跳到几个 G——样本窗口里取中位数才稳。
    _pageSizes.add(bytes);
    if (_pageSizes.length > _pageSizeWindow) {
      _pageSizes.removeAt(0);
    }
  }

  /// 最近几页的大小（字节），用于估算总体积。
  final List<int> _pageSizes = [];

  static const _pageSizeWindow = 32;

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
  ///
  /// 顺手把每页大小记进 [_diskBytes]：恢复时直接信磁盘上的实际字节数，
  /// 比 JSON 里那个「上一次落盘时」的数字准，也不用从 0 开始重新累计。
  Future<Set<int>> _scanChapterPages(String chapterName) async {
    var pages = <int>{};
    var sizes = <int, int>{};
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
        var length = await entity.length();
        if (length > 0) {
          pages.add(index);
          sizes[index] = length;
        }
      }
    } catch (e) {
      Log.error("Download", "Failed to scan chapter $chapterName: $e");
    }
    _diskBytes[chapterName] = sizes;
    return pages;
  }

  /// 磁盘上每页的大小，key 是章节名，value 是「页码 → 字节数」。
  final _diskBytes = <String, Map<int, int>>{};

  /// 进度文件里带回来的「每章几页」。
  ///
  /// 只为了在拿不到地址表时也能算出分母，让恢复后的进度不是 0。
  Map<String, int>? _chapterPageHint;

  Future<Set<int>> _pagesOnDisk(String chapterName) async {
    return _diskPages[chapterName] ??= await _scanChapterPages(chapterName);
  }

  /// 恢复时算进度用的「每章几页」。
  ///
  /// 优先用真地址表；没有就用进度文件里记的那几行数字。地址表有几百 KB，
  /// 而进度文件只有几 KB——进程在「地址表刚拉完、还没写盘」的窗口里被杀，
  /// 任务文件里 `images` 就是空的，这时候只有进度文件还知道分母是多少。
  Map<String, int>? _pageCountsForReconcile() {
    if (_images != null && _images!.isNotEmpty) {
      return _images!.map((key, value) => MapEntry(key, value.length));
    }
    var hint = _chapterPageHint;
    if (hint != null && hint.isNotEmpty) {
      return hint;
    }
    return null;
  }

  Future<void>? _reconcileChain;

  /// 用磁盘上的实际文件重建进度，并把游标挪到第一个缺页。
  ///
  /// 恢复时有两处会触发（启动后扫一次、resume 开头再扫一次）。两次并发地
  /// clear + 重扫会把 [_diskPages] 搅成半新半旧，所以串行化：后来的直接
  /// 复用正在跑的那一次。
  Future<void> _reconcileWithDisk() {
    return _reconcileChain ??= _doReconcile()
        .catchError(
          (Object e, StackTrace s) =>
              Log.error("Download", "Failed to reconcile with disk: $e", s),
        )
        .whenComplete(() {
          _reconcileChain = null;
        });
  }

  Future<void> _doReconcile() async {
    if (path == null) {
      return;
    }
    var counts = _pageCountsForReconcile();
    if (counts == null || counts.isEmpty) {
      // 连「每章几页」都不知道，扫出来的页数没有分母，算不出百分比。
      // 这里什么都不动，等拿到地址表之后那次重算。
      return;
    }
    // 目录还不存在（外部存储刚重挂、权限没就绪）时不要下结论：这时扫出来
    // 必然是 0 页，写进 UI 就成了「进度归零」。保持原样，下次再来。
    if (!await Directory(path!).exists()) {
      Log.warning(
        "Download",
        "Skip reconcile for $title, ${path!} is not ready",
      );
      return;
    }
    // 每次恢复都重扫：暂停/取消发生在写盘中途时，`_diskPages` 可能和
    // 真实目录对不上，缓存不清就会一直沿用旧结论（该下的页被当成已下）。
    _diskPages.clear();
    _diskBytes.clear();
    var pageCounts = <int>[];
    var existing = <List<int>>[];
    for (var entry in counts.entries) {
      pageCounts.add(entry.value);
      existing.add((await _pagesOnDisk(entry.key)).toList());
    }
    var point = computeResumePoint(
      pageCounts: pageCounts,
      existingPages: existing,
    );
    if (point.total == 0) {
      return;
    }
    // 记录里明明下过几百页，磁盘上一页都没扫到：要么目录被清过，要么页码
    // 命名对不上。先把旧数字留着（日志里留个线索），总好过把进度抹成 0
    // ——那正是用户最不能接受的那种「回到起点」。
    if (point.downloaded == 0 && _downloadedCount > 0) {
      Log.warning(
        "Download",
        "No page found on disk for $title, keep $_downloadedCount/$_totalCount",
      );
      return;
    }
    _totalCount = point.total;
    _downloadedCount = point.downloaded;
    // 字节数也以磁盘为准。以前只有「页数」按磁盘重算、字节数沿用 JSON，
    // 于是恢复后可能出现「页数几十、体积 0」，估算又从这个错样本外推，
    // 一会儿几个 G 一会儿几百 K。磁盘上有什么就算什么，最省事也最准。
    var diskBytes = 0;
    var samples = <int>[];
    for (var entry in counts.entries) {
      var sizes = _diskBytes[entry.key];
      if (sizes == null) {
        continue;
      }
      var limit = entry.value;
      var ordered = sizes.keys.where((i) => i < limit).toList()..sort();
      for (var page in ordered) {
        diskBytes += sizes[page]!;
        samples.add(sizes[page]!);
      }
    }
    _downloadedBytes = diskBytes;
    if (samples.isNotEmpty) {
      _pageSizes
        ..clear()
        ..addAll(samples.length > _pageSizeWindow
            ? samples.sublist(samples.length - _pageSizeWindow)
            : samples);
    }
    // 全部都在磁盘上了（上次下完但没来得及入库）：游标推到末尾，让下面
    // 的循环立刻结束并入库。用「每章几页」估出来的顺序不一定就是地址表
    // 的顺序，所以只在真地址表在手时才挪游标。
    if (_images != null && _images!.isNotEmpty) {
      _chapter = point.chapter;
      _index = point.index;
    }
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
    // 任务动了就要确认前台服务还在。自动重试是定时器拉起来的，不经过
    // pumpQueue，不在这里补一刀的话「服务已停 + 任务又开始跑」会一直成立，
    // 进程始终是缓存优先级，系统一冻就又是「下载自己停了」。
    LocalManager().refreshBackgroundService();

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
        // 这些阶段以前都不自动重试：网络抖一下任务就停在「拉详情失败」，
        // 后台没人点重试，于是一直躺到用户回来。现在和逐页下载一视同仁。
        _setError("Error: ${res.errorMessage}", autoRetry: true);
        return;
      } else {
        comic = res.data;
      }
    }

    if (path == null) {
      try {
        // 任务自述「下过东西」但没有目录：先找回旧目录，别新建一个
        // `标题(1)` 把已经下了一半的图扔在那儿。
        Directory? reused;
        var hadProgress = _downloadedCount > 0 ||
            (_chapterPageHint?.isNotEmpty ?? false);
        if (hadProgress) {
          reused = LocalManager().findReusableDirectory(
            comic!.title,
            comicId: comicId,
            sourceKey: source.key,
          );
          if (reused != null) {
            Log.warning(
              "Download",
              "Reusing existing directory ${reused.path} for $comicId",
            );
          }
        }
        var dir = reused ??
            await LocalManager().findValidDirectory(
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

    // 先按磁盘把进度找回来，再往下走。
    //
    // 这一步不需要网络，所以哪怕接下来拉章节表/封面失败（断网、源站挂了），
    // 用户看到的也是「已经下了多少页」，而不是 0。以前这里先 full 落一次盘，
    // 那时 `_downloadedCount` 还是 JSON 里的旧值甚至 0，一旦进程在这附近被
    // 杀，看起来就是「进度回到起点」。
    await _reconcileWithDisk();
    await LocalManager().saveCurrentDownloadingTasks(full: true);

    if (!_isRunning) {
      return;
    }

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
        _setError("Error: ${res.errorMessage}", autoRetry: true);
        return;
      } else {
        _cover = res.data;
        notifyListeners();
      }
      await LocalManager().saveCurrentDownloadingTasks(full: true);
    }

    // 空的地址表等于没有：以前只在 `== null` 时重拉，于是恢复出来的
    // `{}` 会让下面的循环一页都不下、直接判定「下完了」，任务原地消失。
    if (_images == null || _images!.isEmpty) {
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
          _setError("Error: ${res.errorMessage}", autoRetry: true);
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
              // 地址表只拉到一半：整份作废，下一轮重来。留着半份的话，
              // 重试时会因为「已经有地址表」跳过拉取，把没问到的章节当成
              // 不存在，下完还判完成——缺章，而且一句提示都没有。
              _images = null;
              _setError("Error: ${entry.value.errorMessage}", autoRetry: true);
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
    // 任务自己停了，前台服务该摘就摘（全部停了的话）。
    LocalManager().refreshBackgroundService();
    if (!autoRetry || _autoRetry >= _maxAutoRetries || userPaused || _cancelled) {
      return;
    }
    // 网络抖一下不该让整个任务停在那儿等用户来点。隔几秒自己再试，
    // 恢复时会按磁盘重算进度，已经下好的页不会重下。
    //
    // 次数给足：手机锁屏、VPN 掉线、地铁进隧道都可能断上一两分钟，两三次
    // 重试根本熬不过去，用户回来看到的就是「下载停了」。退避到 2 分钟，
    // 前面几次仍然很快，真正长时间断网才会放弃。
    _autoRetry++;
    const delays = [5, 10, 20, 40, 80, 160];
    var seconds = delays[(_autoRetry - 1).clamp(0, delays.length - 1)];
    var delay = Duration(seconds: seconds);
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

  static const _maxAutoRetries = 6;

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
        // 每章页数 + 目录：几 KB，但足够在地址表缺失时把进度算回来。
        "chapterPages": _images?.map((k, v) => MapEntry(k, v.length)),
        "path": path,
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
    var pages = json["chapterPages"];
    if (pages is Map && pages.isNotEmpty) {
      _chapterPageHint = pages.map((k, v) => MapEntry("$k", (v as num).toInt()));
    }
    // 目录以前没存，老版本的进度文件里没有；任务文件里的 path 才是准的，
    // 只有在任务文件丢了 path 时才用它兜底。
    path ??= json["path"];
  }

  @override
  Future<void> reconcileProgress() async {
    // 正在跑的任务自己有游标，别从外面改它。
    if (_isRunning) {
      return;
    }
    await _reconcileWithDisk();
    await LocalManager().saveDownloadProgressNow();
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
      "chapterPages": _images?.map((k, v) => MapEntry(k, v.length)),
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
      .._chapterPageHint = (json["chapterPages"] as Map?)?.map(
        (k, v) => MapEntry("$k", (v as num).toInt()),
      )
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
/// 所以只能拿已下好的页外推。**不能用「累计字节 ÷ 已完成页数」**：长条漫
/// 的第一页动辄两三 MB，按它外推一千页就是几个 G，等真实页（几十 KB）陆续
/// 到位再一路缩回去——用户看到的就是「预估一会儿几个 G、一会儿一百多 M」。
///
/// 有 [recentPageBytes]（最近若干页的大小）时取中位数外推：中位数对单张
/// 大图/小图都不敏感，样本不足 5 页干脆不给数字（返回 0），宁可不显示。
int estimateTotalBytes({
  required int downloadedBytes,
  required int downloadedCount,
  required int totalCount,
  List<int>? recentPageBytes,
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
  if (recentPageBytes != null) {
    var samples = recentPageBytes.where((e) => e > 0).toList();
    if (samples.length < _minSamplesForEstimate) {
      return 0;
    }
    var perPage = _median(samples);
    var remaining = totalCount - downloadedCount;
    return downloadedBytes + (perPage * remaining).round();
  }
  return (downloadedBytes / downloadedCount * totalCount).round();
}

/// 少于这么多页时不做外推：样本太小，一张大图就能带偏整本。
const _minSamplesForEstimate = 5;

int _median(List<int> values) {
  var sorted = List<int>.from(values)..sort();
  var mid = sorted.length ~/ 2;
  if (sorted.length.isOdd) {
    return sorted[mid];
  }
  return ((sorted[mid - 1] + sorted[mid]) / 2).round();
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

  /// 多久收不到下一个字节就算这一页「假死」。
  ///
  /// 切后台、锁屏时 socket 有时既不断也不报错，就是再也不来数据。主循环
  /// `await task.wait()` 会一直等下去：通知栏还挂着，速度 0，进度不动，
  /// 看起来就是「下载停了」，而且永远不会自己恢复。流上挂一个超时，超时
  /// 直接抛给下面的 catch 走重试，比干等强。
  static const _stallTimeout = Duration(seconds: 90);

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
      ).timeout(_stallTimeout)) {
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
