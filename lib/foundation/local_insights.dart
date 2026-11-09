import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/storage_usage.dart';

/// 一本本地漫画的占用。
///
/// [signature] 是算这份占用时的「章节指纹」。漫画后来又下了一话，指纹变了，
/// 就得重新量一遍——否则列表上会一直显示旧体积。
class LocalComicSize {
  const LocalComicSize(this.bytes, this.signature, this.measuredAt);

  final int bytes;

  final String signature;

  /// 量出来的时间（毫秒）。就算章节指纹没变，超过一天也重量一次——
  /// 往同一话里补页、替换图片都不会改章节数，指纹看不出来。
  final int measuredAt;
}

/// 网源那边比本地多出来的章节数。
class LocalUpdateInfo {
  const LocalUpdateInfo({required this.newChapters, required this.checkedAt});

  final int newChapters;

  final DateTime checkedAt;

  bool get hasUpdate => newChapters > 0;
}

/// 列表上那行「读到哪了」。
class ReadProgressInfo {
  const ReadProgressInfo({
    this.ep,
    this.page,
    this.chapterTitle,
    this.readChapters = 0,
    this.totalChapters = 0,
  });

  /// 当前章节序号（1 起），没读过为 null。
  final int? ep;

  /// 当前页码（1 起）。
  final int? page;

  /// 当前章节名。源改了章节表时可能取不到，用 `E<n>` 兜底。
  final String? chapterTitle;

  /// 已读完的章节数（读过的章节集合大小）。
  final int readChapters;

  final int totalChapters;

  bool get started => ep != null && (ep! > 1 || (page ?? 0) > 1);

  /// 0..1。没有章节表时用「有没有开始读」粗粒度表示。
  double get fraction {
    if (totalChapters <= 0) {
      return started ? 1 : 0;
    }
    return (readChapters / totalChapters).clamp(0.0, 1.0);
  }
}

/// 一次更新检查的结果。
class LocalUpdateCheckResult {
  const LocalUpdateCheckResult({
    required this.checked,
    required this.updated,
    required this.failed,
    required this.changed,
  });

  /// 真正发出请求的本数
  final int checked;

  /// 有更新的本数
  final int updated;

  /// 请求失败的本数（源挂了 / 离线）
  final int failed;

  /// 检查结果与上次不同、或者上次没查过的本数
  final int changed;
}

/// 比较本地章节表与网源最新章节表，算出「新增了几话」。
///
/// 抽成顶层纯函数是为了能单测——这里最容易出的错是「每次刷新都报有更新」。
///
/// 两条保护：
/// 1. 本地没有章节表（单话下载 / 手工导入）时返回 0。否则整本都会被算成新增。
/// 2. 源换了章节 id 但标题没变时不算新增。有些源每次请求都生成新的 id
///    （时间戳、随机串），只比 id 会让这些漫画永远挂着「有更新」。
int countNewChapters(ComicChapters? local, ComicChapters? current) {
  if (current == null) {
    return 0;
  }
  final localIds = local?.allChapters.keys.toSet() ?? const <String>{};
  if (localIds.isEmpty) {
    return 0;
  }
  final localTitles = local!.allChapters.values.toSet();
  var count = 0;
  for (final entry in current.allChapters.entries) {
    if (localIds.contains(entry.key)) {
      continue;
    }
    if (localTitles.contains(entry.value)) {
      continue;
    }
    count++;
  }
  return count;
}

/// 本地漫画列表的附加信息：占用空间、阅读进度、网源有没有更新。
///
/// 三件事的共同点是「都不便宜」：量目录要遍历文件、查更新要发请求。
/// 所以全部按 [LocalComic] 的 key 缓存，并且把结果落到 `implicitData` 里
/// （不跟着 WebDAV 同步——这些数字是这台设备上的事实）。
class LocalInsights extends ChangeNotifier {
  LocalInsights._() {
    _restore();
  }

  static final LocalInsights _instance = LocalInsights._();

  factory LocalInsights() => _instance;

  static const _sizeStoreKey = 'localComicSizes';

  static const _updateStoreKey = 'localComicUpdateCheck';

  /// 更新检查的保鲜期。进页面自动查一轮，6 小时内不重复查同一本。
  static const _updateTtl = Duration(hours: 6);

  /// 自动检查每轮最多查几本。
  ///
  /// 收藏里躺着三百本的时候，一次全查等于对源发起三百个请求，既慢又像在
  /// 爬人家站。超出的部分留到下次进页面（查到的那部分会被 TTL 记住）。
  static const _autoCheckLimit = 30;

  /// 同时进行的请求/遍历数。源大多不禁并发，但也没必要把人打满。
  static const _maxWorkers = 2;

  /// 体积缓存的保质期。过期就重量一次，代价只是遍历一遍目录。
  static const _sizeTtl = Duration(days: 1);

  final Map<String, LocalComicSize> _sizes = {};

  final Map<String, LocalUpdateInfo> _updates = {};

  /// 排队等量的本数（key -> comic），以及正在量的 key。
  ///
  /// 两个集合合起来就是「别重复排队」的判断依据：量一本要遍历整个目录，
  /// 列表每次重建都会问一次，没有这个去重会瞬间排进几十个同样的任务。
  final Map<String, LocalComic> _sizePending = {};

  final Set<String> _sizeInFlight = {};

  int _sizeWorkers = 0;

  /// 本次会话里查失败的本数，别再自动重试。
  ///
  /// 只放内存：下次启动再试，用户手动点「检查更新」也会重试。
  final Set<String> _updateFailed = {};

  Timer? _saveTimer;

  bool _checking = false;

  /// 上次自动检查的时间。页面会因为下载进度之类的通知反复 rebuild，
  /// `autoCheck` 也跟着被反复调用，这里兜一层节流，别每次都扫一遍列表。
  DateTime? _lastAutoCheckAt;

  /// 是否正在检查更新（顶栏按钮转圈用）。
  bool get checking => _checking;

  static String keyOf(LocalComic comic) =>
      "${comic.comicType.value}:${comic.id}";

  void _restore() {
    try {
      final sizes = appdata.implicitData[_sizeStoreKey];
      if (sizes is Map) {
        for (final entry in sizes.entries) {
          final value = entry.value;
          if (value is Map && value["b"] is int) {
            _sizes[entry.key as String] = LocalComicSize(
              value["b"] as int,
              (value["s"] ?? "") as String,
              (value["a"] as int?) ?? 0,
            );
          }
        }
      }
      final updates = appdata.implicitData[_updateStoreKey];
      if (updates is Map) {
        for (final entry in updates.entries) {
          final value = entry.value;
          if (value is Map && value["n"] is int && value["t"] is int) {
            _updates[entry.key as String] = LocalUpdateInfo(
              newChapters: value["n"] as int,
              checkedAt: DateTime.fromMillisecondsSinceEpoch(value["t"] as int),
            );
          }
        }
      }
    } catch (e, s) {
      Log.error("LocalInsights", "Failed to restore cache: $e", s);
    }
  }

  /// 攒一下再写盘：量完一本就写一次 implicitData，几百本会把主线程写满。
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () {
      _saveTimer = null;
      _save();
    });
  }

  void _save() {
    try {
      appdata.implicitData[_sizeStoreKey] = {
        for (final entry in _sizes.entries)
          entry.key: {
            "b": entry.value.bytes,
            "s": entry.value.signature,
            "a": entry.value.measuredAt,
          },
      };
      appdata.implicitData[_updateStoreKey] = {
        for (final entry in _updates.entries)
          entry.key: {
            "n": entry.value.newChapters,
            "t": entry.value.checkedAt.millisecondsSinceEpoch,
          },
      };
      unawaited(appdata.writeImplicitData());
    } catch (e, s) {
      Log.error("LocalInsights", "Failed to persist cache: $e", s);
    }
  }

  // ---------------------------------------------------------------- 占用空间

  /// 已经量好的占用，没量过返回 null（UI 先显示占位）。
  int? sizeOf(LocalComic comic) => _sizes[keyOf(comic)]?.bytes;

  /// 章节指纹：章节数和「上次下载过的章节集合大小」。任何一个变了就重算。
  ///
  /// 不用目录 mtime：Android 上从 SAF 导入的漫画，父目录 mtime 不一定随
  /// 子目录内容变化更新，靠不住。
  String _signatureOf(LocalComic comic) {
    return "${comic.downloadedChapters.length}/${comic.chapters?.length ?? 0}";
  }

  /// 请求一本的占用。已经有新鲜缓存就直接返回，不排队。
  ///
  /// 列表里每行都会调它，所以这里必须便宜：命中缓存时只有一次字符串比较。
  void requestSize(LocalComic comic) {
    final key = keyOf(comic);
    final cached = _sizes[key];
    if (cached != null &&
        cached.signature == _signatureOf(comic) &&
        DateTime.now().millisecondsSinceEpoch - cached.measuredAt <
            _sizeTtl.inMilliseconds) {
      return;
    }
    if (_sizePending.containsKey(key) || _sizeInFlight.contains(key)) {
      return;
    }
    _sizePending[key] = comic;
    _pumpSizeQueue();
  }

  void _pumpSizeQueue() {
    while (_sizeWorkers < _maxWorkers && _sizePending.isNotEmpty) {
      final entry = _sizePending.entries.first;
      _sizePending.remove(entry.key);
      _sizeWorkers++;
      _sizeInFlight.add(entry.key);
      unawaited(
        _runMeasure(entry.value).whenComplete(() {
          _sizeWorkers--;
          _sizeInFlight.remove(entry.key);
          notifyListeners();
          _pumpSizeQueue();
        }),
      );
    }
  }

  Future<void> _runMeasure(LocalComic comic) async {
    final key = keyOf(comic);
    try {
      final bytes = await directorySize(Directory(comic.baseDir));
      _sizes[key] = LocalComicSize(
        bytes,
        _signatureOf(comic),
        DateTime.now().millisecondsSinceEpoch,
      );
      _scheduleSave();
    } catch (e, s) {
      Log.error("LocalInsights", "Failed to measure ${comic.id}: $e", s);
    }
  }

  // ---------------------------------------------------------------- 阅读进度

  ReadProgressInfo progressOf(LocalComic comic) {
    final history = HistoryManager().find(comic.id, comic.comicType);
    final chapters = comic.chapters;
    return ReadProgressInfo(
      ep: history?.ep,
      page: history?.page,
      chapterTitle: history == null
          ? null
          : chapterTitleOf(chapters, history.ep, history.group),
      readChapters: history?.readEpisode.length ?? 0,
      totalChapters: chapters?.length ?? 0,
    );
  }

  /// 章节名。分组章节里 `ep` 是组内序号，必须配合 `group` 才能取对。
  static String? chapterTitleOf(
    ComicChapters? chapters,
    int ep,
    int? group,
  ) {
    if (chapters == null || ep <= 0) {
      return null;
    }
    try {
      if (chapters.isGrouped) {
        final g = (group ?? 1).clamp(1, chapters.groupCount);
        final keys = chapters.getGroupByIndex(g - 1).keys.toList();
        if (keys.isEmpty) {
          return null;
        }
        return chapters.getGroupByIndex(g - 1)[keys[(ep - 1).clamp(0, keys.length - 1)]];
      }
      final titles = chapters.titles.toList();
      if (titles.isEmpty) {
        return null;
      }
      return titles[(ep - 1).clamp(0, titles.length - 1)];
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------- 更新检查

  LocalUpdateInfo? updateOf(LocalComic comic) => _updates[keyOf(comic)];

  /// 这本有没有条件查更新：手工导入的（没有网源）一律跳过。
  bool isCheckable(LocalComic comic) {
    if (comic.comicType == ComicType.local) {
      return false;
    }
    return comic.comicType.comicSource?.loadComicInfo != null;
  }

  /// 进页面时后台查一轮。不阻塞 UI，失败静默。
  void autoCheck(List<LocalComic> comics) {
    if (_checking) {
      return;
    }
    final now = DateTime.now();
    if (_lastAutoCheckAt != null &&
        now.difference(_lastAutoCheckAt!) < const Duration(seconds: 30)) {
      return;
    }
    _lastAutoCheckAt = now;
    final targets = <LocalComic>[];
    for (final comic in comics) {
      if (!isCheckable(comic)) {
        continue;
      }
      final key = keyOf(comic);
      if (_updateFailed.contains(key)) {
        continue;
      }
      final cached = _updates[key];
      if (cached != null && now.difference(cached.checkedAt) < _updateTtl) {
        continue;
      }
      targets.add(comic);
      if (targets.length >= _autoCheckLimit) {
        break;
      }
    }
    if (targets.isEmpty) {
      return;
    }
    unawaited(checkAll(targets));
  }

  /// 检查一批漫画。`force` 为 true 时忽略 TTL（手动刷新用）。
  Future<LocalUpdateCheckResult> checkAll(
    List<LocalComic> comics, {
    bool force = false,
    void Function(int done, int total)? onProgress,
  }) async {
    final now = DateTime.now();
    final targets = <LocalComic>[];
    for (final comic in comics) {
      if (!isCheckable(comic)) {
        continue;
      }
      final key = keyOf(comic);
      if (!force) {
        final cached = _updates[key];
        if (cached != null && now.difference(cached.checkedAt) < _updateTtl) {
          continue;
        }
      }
      targets.add(comic);
    }
    if (targets.isEmpty) {
      return const LocalUpdateCheckResult(
        checked: 0,
        updated: 0,
        failed: 0,
        changed: 0,
      );
    }
    _checking = true;
    notifyListeners();

    var done = 0;
    var updated = 0;
    var failed = 0;
    var changed = 0;
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= targets.length) {
          return;
        }
        final comic = targets[index];
        final key = keyOf(comic);
        try {
          final source = comic.comicType.comicSource;
          final loader = source?.loadComicInfo;
          if (loader == null) {
            throw StateError("No comic source");
          }
          final res = await loader(comic.id);
          if (res.error) {
            throw Exception(res.errorMessage);
          }
          final localChapters = comic.chapters;
          final newCount = countNewChapters(localChapters, res.data.chapters);
          final previous = _updates[key];
          _updates[key] = LocalUpdateInfo(
            newChapters: newCount,
            checkedAt: DateTime.now(),
          );
          _updateFailed.remove(key);
          if (previous?.newChapters != newCount) {
            changed++;
          }
          if (newCount > 0) {
            updated++;
          }
        } catch (e, s) {
          // 离线 / 源挂了都算失败：保留上次结果，下次再试。
          _updateFailed.add(key);
          failed++;
          Log.error("LocalInsights", "Failed to check ${comic.id}: $e", s);
        }
        done++;
        onProgress?.call(done, targets.length);
      }
    }

    try {
      final workers = math.min(_maxWorkers, targets.length);
      await Future.wait(List.generate(workers, (_) => worker()));
    } finally {
      _checking = false;
      _save();
      notifyListeners();
    }
    return LocalUpdateCheckResult(
      checked: targets.length,
      updated: updated,
      failed: failed,
      changed: changed,
    );
  }

  /// 清掉某本的结果。下载新章节后调用，别让旧角标挂着。
  void forgetUpdates(LocalComic comic) {
    if (_updates.remove(keyOf(comic)) != null) {
      _scheduleSave();
      notifyListeners();
    }
  }

  /// 导入/删除漫画后顺手清掉体积缓存，避免下次仍读到旧数字。
  void forgetSize(LocalComic comic) {
    if (_sizes.remove(keyOf(comic)) != null) {
      _scheduleSave();
    }
  }

  /// 单个文件/目录的占用文案，量不出来时返回 null。
  String? sizeTextOf(LocalComic comic) {
    final bytes = sizeOf(comic);
    if (bytes == null) {
      return null;
    }
    return formatLocalSize(bytes);
  }
}

/// 体积文案。这里单独实现一份而不复用 `bytesToReadableString`，
/// 是为了让列表行紧凑一些（`12.3 MB` 而不是 `12.34 MB`）。
String formatLocalSize(int bytes) {
  if (bytes < 1024) {
    return "$bytes B";
  }
  if (bytes < 1024 * 1024) {
    return "${(bytes / 1024).toStringAsFixed(0)} KB";
  }
  if (bytes < 1024 * 1024 * 1024) {
    return "${(bytes / 1024 / 1024).toStringAsFixed(1)} MB";
  }
  return "${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB";
}
