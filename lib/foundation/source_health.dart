import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/translations.dart';

enum SourceHealthStatus {
  /// 还没测过
  waiting,

  /// 正在测
  testing,

  /// 拿到结果，而且是有效结果
  ok,

  /// 接口通了，但一条都没返回
  empty,

  /// 报错或超时
  error,

  /// 这个源没有搜索接口，测不了
  unsupported,
}

/// 单个源的探测结果。
///
/// 体检原本是一个独立页面，现在并进了漫画源页：列表行显示状态点与分数、
/// 点一行重测、顶栏一颗按钮全测。探测逻辑收在这里一份——页面各写一遍，
/// 早晚会出现「同一个源在两处结论不一样」。
class SourceHealth {
  SourceHealth(this.source) {
    if (source.searchPageData == null) {
      status = SourceHealthStatus.unsupported;
    }
  }

  final ComicSource source;

  SourceHealthStatus status = SourceHealthStatus.waiting;

  /// 毫秒
  int? latency;

  /// 探测关键词返回的条数
  int? count;

  String? message;

  /// 最后一次测完的时间
  DateTime? checkedAt;

  bool get tested => checkedAt != null;

  /// 0-100 的健康分，没测过或不支持时是 null（界面上显示占位符而不是 0，
  /// 「没测」和「测出 0 分」是两件事，混成 0 会被当成源挂了）。
  int? get score {
    switch (status) {
      case SourceHealthStatus.ok:
        // 延迟分档扣分：500ms 内满分，再往上逐档扣，扣到 60 为止。
        // 不再往下扣是因为「慢但能用」的源对用户依然有价值，把它压到红色没有意义。
        final l = latency ?? 0;
        var s = 100;
        if (l > 500) s -= 8;
        if (l > 1200) s -= 12;
        if (l > 2500) s -= 10;
        if (l > 5000) s -= 10;
        // 只返回一两条，多半是关键词没命中而不是源真的坏了，轻扣一点。
        final c = count ?? 0;
        if (c < 3) s -= 8;
        return s.clamp(60, 100);
      case SourceHealthStatus.empty:
        return 55;
      case SourceHealthStatus.error:
        return 10;
      case SourceHealthStatus.waiting:
      case SourceHealthStatus.testing:
      case SourceHealthStatus.unsupported:
        return null;
    }
  }

  /// 0-1，给进度环用
  double get ratio => (score ?? 0) / 100;

  String get statusText {
    switch (status) {
      case SourceHealthStatus.ok:
        return "@a results".tlParams({"a": count ?? 0});
      case SourceHealthStatus.empty:
        return "No results".tl;
      case SourceHealthStatus.error:
        return "Failed".tl;
      case SourceHealthStatus.testing:
        return "Testing".tl;
      case SourceHealthStatus.waiting:
        return "Waiting".tl;
      case SourceHealthStatus.unsupported:
        return "Search not supported".tl;
    }
  }

  /// 分数对应的文字评价，用于详情面板
  String? get gradeText {
    final s = score;
    if (s == null) return null;
    if (s >= 90) return "Excellent".tl;
    if (s >= 75) return "Good".tl;
    if (s >= 60) return "Fair".tl;
    return "Poor".tl;
  }
}

/// 全源体检。单例，结果常驻内存，列表与详情面板读的都是这一份。
class SourceHealthService extends ChangeNotifier {
  SourceHealthService._() {
    final saved = appdata.implicitData[_failedKeysKey];
    if (saved is List) {
      _failedKeys.addAll(saved.whereType<String>());
    }
  }

  static final SourceHealthService instance = SourceHealthService._();

  /// 上次测出「失败」的源 key，跟着 implicitData 落盘。
  ///
  /// 体检结果本身只在内存里，重启就没了。但「收藏 → 一键清理失效」要靠它
  /// 判断哪些源挂了——只放内存的话，重启后第一次清理会把那些源当成正常，
  /// 一条也挪不动。源重新测通就从这个集合里删掉。
  static const _failedKeysKey = 'sourceHealthFailedKeys';

  final _failedKeys = <String>{};

  /// 这个源上次体检是不是失败的。
  bool hasFailed(String key) => _failedKeys.contains(key);

  void _recordFailed(SourceHealth item) {
    final key = item.source.key;
    final changed = item.status == SourceHealthStatus.error
        ? _failedKeys.add(key)
        : _failedKeys.remove(key);
    if (changed) {
      appdata.implicitData[_failedKeysKey] = _failedKeys.toList();
      unawaited(appdata.writeImplicitData());
      if (_running) {
        _failedSinceBatch = true;
      } else {
        unawaited(_notifyFailuresChanged());
      }
    }
  }

  Future<void> _notifyFailuresChanged() async {
    final handler = onFailuresChanged;
    if (handler == null) {
      return;
    }
    try {
      await handler();
    } catch (e, s) {
      // 收藏清理失败不能连累检测结果的展示
      Log.error("SourceHealth", "failure handler failed: $e\n$s");
    }
  }

  /// 用尽量短的常见字探测，多数源都能返回结果
  static const probeKeyword = "a";

  static const timeout = Duration(seconds: 8);

  /// 同时在跑的探测数。再高会同时打一堆请求，容易被源站当爬虫。
  static const concurrency = 4;

  final _cache = <String, SourceHealth>{};

  bool _running = false;

  /// 这一批检测里有没有源的「失败」状态动过。
  ///
  /// 不能每测一个源就收一次收藏（一轮下来八个源扫八遍库），攒到批次结束
  /// 再一起处理；单独点某一行重测时 `_running` 是 false，立刻处理。
  bool _failedSinceBatch = false;

  /// 失败源集合变化后的回调。
  ///
  /// 收藏那边靠它把「源已经挂了」的漫画挪进「失效」分类——用户在源页面
  /// 看到一片红，收藏里却还是满的，还得自己去找「一键清理失效」，这条
  /// 联动就是为了省掉那一步。
  ///
  /// 做成回调而不是直接 import favorites：`favorites.dart` 已经引用了本
  /// 文件（`_isInvalidItem` 要看 `hasFailed`），反向依赖会绕成环。注册在
  /// `init.dart`，那里两边的初始化顺序是确定的。
  Future<void> Function()? onFailuresChanged;

  bool get running => _running;

  DateTime? lastRunAt;

  /// 取某个源的结果，没有就建一个（不触发探测）
  SourceHealth of(ComicSource source) {
    final cached = _cache[source.key];
    // 源被 reload 后是新对象，旧结果里的引用已经失效，重建。
    if (cached != null && identical(cached.source, source)) {
      return cached;
    }
    final item = SourceHealth(source);
    _cache[source.key] = item;
    return item;
  }

  List<SourceHealth> ofAll(Iterable<ComicSource> sources) =>
      sources.map(of).toList();

  bool get hasAnyResult => _cache.values.any((e) => e.tested);

  /// 源被删除/重装后清掉它的结果
  void forget(String key) {
    _failedKeys.remove(key);
    if (_cache.remove(key) != null) {
      notifyListeners();
    }
  }

  /// 测一批源。[force] 为 false 时跳过已经测过的，用于进页面时补测新增的源。
  Future<void> testAll(
    Iterable<ComicSource> sources, {
    bool force = false,
  }) async {
    if (_running) {
      return;
    }
    final list = ofAll(sources);
    final pending = force
        ? list.where((e) => e.status != SourceHealthStatus.unsupported).toList()
        : list
            .where(
              (e) => !e.tested && e.status != SourceHealthStatus.unsupported,
            )
            .toList();
    if (pending.isEmpty) {
      // 即使没事可做也刷新一下时间，界面上「上次检测」才能对上
      if (force) {
        lastRunAt = DateTime.now();
        notifyListeners();
      }
      return;
    }
    _running = true;
    notifyListeners();
    var index = 0;
    Future<void> worker() async {
      while (index < pending.length) {
        await testOne(pending[index++]);
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
    _running = false;
    lastRunAt = DateTime.now();
    notifyListeners();
    // 一轮测完才动收藏：中途每测挂一个就扫一遍库，八个源就是八次全表扫描。
    if (_failedSinceBatch) {
      _failedSinceBatch = false;
      unawaited(_notifyFailuresChanged());
    }
  }

  Future<void> testOne(SourceHealth item) async {
    final data = item.source.searchPageData;
    if (data == null) {
      return;
    }
    item
      ..status = SourceHealthStatus.testing
      ..latency = null
      ..count = null
      ..message = null;
    notifyListeners();
    final options =
        (data.searchOptions ?? []).map((e) => e.defaultValue).toList();
    final watch = Stopwatch()..start();
    try {
      Future<dynamic> task;
      if (data.loadPage != null) {
        task = data.loadPage!(probeKeyword, 1, options);
      } else if (data.loadNext != null) {
        task = data.loadNext!(probeKeyword, null, options);
      } else {
        item
          ..status = SourceHealthStatus.unsupported
          ..checkedAt = DateTime.now();
        _recordFailed(item);
        notifyListeners();
        return;
      }
      final res = await task.timeout(timeout);
      watch.stop();
      item.latency = watch.elapsedMilliseconds;
      if (res.error == true) {
        item
          ..status = SourceHealthStatus.error
          ..message = res.errorMessage ?? "Unknown error".tl;
      } else {
        final count = (res.data as List?)?.length ?? 0;
        item
          ..count = count
          ..status =
              count > 0 ? SourceHealthStatus.ok : SourceHealthStatus.empty;
      }
    } catch (e) {
      watch.stop();
      Log.info("SourceHealth", "${item.source.key} failed: $e");
      item
        ..latency = watch.elapsedMilliseconds
        ..status = SourceHealthStatus.error
        ..message = e is TimeoutException
            ? "Timeout".tl
            : e.toString().split("\n").first;
    }
    item.checkedAt = DateTime.now();
    _recordFailed(item);
    notifyListeners();
  }
}
