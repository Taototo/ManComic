import 'dart:async';

import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/notification_service.dart';
import 'package:venera/utils/translations.dart';

/// 前台服务要展示的汇总。
class DownloadSummary {
  const DownloadSummary({
    required this.running,
    required this.queued,
    required this.waiting,
    required this.speed,
    required this.progress,
    this.title,
  });

  /// 正在跑的任务数
  final int running;

  /// 排队中（受并发上限约束还没开跑）的任务数
  final int queued;

  /// 出错、正在等自动重试的任务数。
  ///
  /// 这类任务一页也不下，但它**还没做完**：网络回来之后还要接着下。
  final int waiting;

  /// 所有在跑任务的合计速度，bytes/s
  final int speed;

  /// 0..1，总量未知时为 0
  final double progress;

  /// 第一部在跑的漫画名，通知里当标题用
  final String? title;

  /// 还有没做完的活。
  ///
  /// **前台服务的生死只看这个**，不看「此刻有没有字节在流」。
  ///
  /// 以前用的是 `running > 0`：网络抖一下把任务打成 error，running 变 0，
  /// 服务立刻被摘掉，进程从「前台」掉成「缓存」。掉下去之后 Android 12+
  /// 不许再从后台拉起前台服务，重试定时器就算到点也起不来——用户看到的就是
  /// 「切后台一会儿下载就自己停了，而且再也不动」。排队中和等重试的都必须
  /// 算「有活」，服务才活得下来。
  bool get hasWork => running + queued + waiting > 0;
}

/// 漫画下载期间的原生前台服务。
///
/// 两件事：把进程提到前台优先级（回到桌面、锁屏都不会被冻结/回收），以及
/// 在通知栏挂一条合计进度。收字节的还是 Dart 侧那套，断点续传、校验、
/// 重试逻辑全都不受影响。
///
/// 没有它的话，切回桌面一会儿进程就可能被系统冻住，下载停在那儿，用户回来
/// 看到的就是「刚才不是还在下吗」。
class DownloadBackground {
  DownloadBackground._();

  static final DownloadBackground instance = DownloadBackground._();

  static const _channel = MethodChannel("venera/method_channel");

  /// 由 [LocalManager] 注入，避免这里反向依赖下载任务类。
  DownloadSummary Function()? summaryProvider;

  Timer? _ticker;

  /// 「我们希望服务活着」。
  ///
  /// 注意它和「服务已经起来了」不是一回事：拉起失败（冷启动时序、后台启动
  /// 被拒、Android 15 的时长上限）时**不能**把它置回 false，否则就再也没人
  /// 去拉了——原来的实现正是这样，一次失败等于永久放弃。
  bool _active = false;

  /// 通知是否已经能更新（start 之后就绪）
  bool _started = false;

  bool _permissionRequested = false;

  String _lastText = '';

  int _lastPercent = -2;

  int _lastPushMs = 0;

  /// 连续拉起失败的次数，用来做退避。
  int _failCount = 0;

  /// 下一次允许尝试拉起的时刻（毫秒）。
  ///
  /// 拉起失败（冷启动时序不对、后台启动被拒）不能就此放弃：进程一旦被打成
  /// 「缓存进程」，切到后台一两分钟就会被系统冻住 —— 用户看到的就是「下载
  /// 自己停了」。这里按退避间隔一直重试，直到成功为止。
  int _nextStartAttemptMs = 0;

  static const _startRetryIntervalMs = 5000;

  /// 服务活着的时候多久重新声明一次。
  ///
  /// 原生侧靠 wakelock 定时续期活着，这条是兜底：进程被系统回收后重建、
  /// 服务被 ROM 的省电策略掐掉，都能被这条发现并拉回来。
  static const _keepAliveIntervalMs = 4 * 60 * 1000;

  int _lastKeepAliveMs = 0;

  bool get enabled => appdata.settings['backgroundDownload'] != false;

  /// 任务增删/启停时调用。还有没做完的任务就确保服务活着，全做完了才摘通知。
  void refresh() {
    if (!App.isAndroid) {
      return;
    }
    final summary = summaryProvider?.call();
    // 只要还有「在跑的 / 排队的 / 等重试的」，服务就得在。不能看 running：
    // 网络抖一下 running 就归零，服务一停进程立刻降级，之后再也拉不起来。
    if (!enabled || summary == null || !summary.hasWork) {
      _stop();
      return;
    }
    if (!_active) {
      _active = true;
      _started = false;
      _failCount = 0;
      _nextStartAttemptMs = 0;
      _lastText = '';
      _lastPercent = -2;
      unawaited(_begin());
    } else if (!_started && _failCount > 0) {
      // 之前拉不起来（后台启动被拒 / Android 15 的时长上限）。refresh 多半
      // 来自「回到前台」这类事件，而回前台正是允许启动前台服务的时候，别
      // 让退避把这次机会拖过去。
      _nextStartAttemptMs = 0;
    }
    // 服务活着的时候靠这个 ticker 刷速度和百分比：逐页的进度变化不走
    // 前台服务（频率太高，会被系统按「通知刷太勤」限流）。
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _push());
  }

  Future<void> _begin() async {
    if (!_active) {
      return;
    }
    _nextStartAttemptMs =
        DateTime.now().millisecondsSinceEpoch + _startRetryIntervalMs;
    final summary = summaryProvider?.call();
    if (summary == null || !summary.hasWork) {
      _stop();
      return;
    }
    _lastText = _describe(summary);
    _lastPercent = _percent(summary);
    _lastPushMs = DateTime.now().millisecondsSinceEpoch;
    // **先起服务，再要权限。**
    //
    // 原来第一件事是 `await` 通知权限，窗口期里用户按一下 Home，应用就进了
    // 后台；Android 12+ 不许后台启动前台服务，`startForegroundService` 直接
    // 被拒 —— 下载照跑，但进程是缓存优先级，一两分钟后被冻住。用户看到的
    // 就是「点了下载然后切出去，过了一会儿发现停了」。
    // 权限只影响「通知看不看得到」，不影响服务本身，放到后面没问题。
    var ok = await _invoke("startDownloadService", {
      "title": _title(summary),
      "text": _lastText,
      "progress": _lastPercent,
    });
    if (!ok) {
      // 冷启动时序不对（进程还没被系统当成前台）时会被拒。**保留 _active**，
      // 只是把下一次尝试往后推：一次失败就放弃，等于把用户的后台下载交给
      // 系统去冻。
      _failCount++;
      // 5s → 10 → 20 → 40 → 80 → 160 → 300 封顶。一直是 80 秒的话，
      // 系统真不让我们起服务时会白白醒过来一次一次地试。
      var backoff = _startRetryIntervalMs * (1 << (_failCount - 1).clamp(0, 6));
      if (backoff > 300000) {
        backoff = 300000;
      }
      _nextStartAttemptMs = DateTime.now().millisecondsSinceEpoch + backoff;
      if (_failCount == 1 || _failCount % 6 == 0) {
        Log.warning(
          "Download",
          "Background service not started (attempt $_failCount), "
              "will retry in ${backoff ~/ 1000}s",
        );
      }
      return;
    }
    if (_failCount > 0) {
      Log.info(
        "Download",
        "Background service started after $_failCount tries",
      );
    }
    _failCount = 0;
    _started = true;
    _lastKeepAliveMs = DateTime.now().millisecondsSinceEpoch;
    unawaited(_ensureNotificationPermission());
  }

  /// 通知权限没给的话服务照样能跑，只是用户看不到进度，所以顺手问一次。
  /// 拒绝也继续下载，不让权限挡住下载。
  Future<void> _ensureNotificationPermission() async {
    if (_permissionRequested) {
      return;
    }
    _permissionRequested = true;
    try {
      if (!await NotificationService.hasPermission()) {
        if (!NotificationService.isForeground) {
          // 后台时弹权限框系统不认，等下次在前台再问
          _permissionRequested = false;
        } else {
          await NotificationService.requestPermission();
        }
      }
    } catch (_) {
      _permissionRequested = false;
    }
  }

  void _push() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!_active) {
      return;
    }
    if (!_started) {
      // 没拉起来就按退避间隔一直试，别等下一次任务事件——很可能再也不会有。
      if (now >= _nextStartAttemptMs) {
        unawaited(_begin());
      }
      return;
    }
    final summary = summaryProvider?.call();
    if (summary == null || !summary.hasWork) {
      _stop();
      return;
    }
    // 隔几分钟重新声明一次，顺便让原生侧把 wakelock 续上。
    if (now - _lastKeepAliveMs >= _keepAliveIntervalMs) {
      _lastKeepAliveMs = now;
      unawaited(_begin());
      return;
    }
    if (now - _lastPushMs < 900) {
      return;
    }
    var text = _describe(summary);
    var percent = _percent(summary);
    if (text == _lastText && percent == _lastPercent) {
      return;
    }
    _lastText = text;
    _lastPercent = percent;
    _lastPushMs = now;
    unawaited(
      _invoke("updateDownloadService", {
        "title": _title(summary),
        "text": text,
        "progress": percent,
      }).then<void>((_) {}),
    );
  }

  void _stop() {
    _ticker?.cancel();
    _ticker = null;
    if (!_active) {
      return;
    }
    _active = false;
    _started = false;
    _failCount = 0;
    _lastText = '';
    _lastPercent = -2;
    unawaited(_invoke("stopDownloadService", const {}).then<void>((_) {}));
  }

  String _title(DownloadSummary summary) {
    return summary.title?.isNotEmpty == true
        ? summary.title!
        : "Downloading".tl;
  }

  String _describe(DownloadSummary summary) {
    // 一条都没在跑、全在等重试：得让用户看到「不是卡死，是在等网络」，
    // 否则通知栏挂着 0 B/s，跟「下载停了」看起来一模一样。
    if (summary.running == 0 && summary.waiting > 0) {
      return "Waiting for network".tl;
    }
    // 速度必须排在最前面。
    //
    // 通知栏收起来只给一行，原来写成「3 个下载中 · 2 个排队 · 1.2 MB/s」，
    // 窄屏或者系统字体调大之后尾巴直接被省略号吃掉——用户看到的就是「只有
    // 状态没有速度」。放到开头，即使后面被截断，速度也还在。
    return [
      if (summary.speed > 0) "${_speedText(summary.speed)}/s",
      if (summary.running > 0)
        "@n downloading".tlParams({"n": summary.running}),
      if (summary.queued > 0) "@n queued".tlParams({"n": summary.queued}),
      if (summary.waiting > 0) "@n retrying".tlParams({"n": summary.waiting}),
    ].join(" · ");
  }

  /// 通知栏里的速度用短格式：`12.3 MB/s` 而不是 `12.34 MB/s`，
  /// 单行放得下更多字，也不至于每秒跳一下宽度。
  String _speedText(int bytesPerSecond) {
    if (bytesPerSecond < 1024) {
      return "$bytesPerSecond B";
    }
    if (bytesPerSecond < 1024 * 1024) {
      return "${(bytesPerSecond / 1024).toStringAsFixed(0)} KB";
    }
    return "${(bytesPerSecond / 1024 / 1024).toStringAsFixed(1)} MB";
  }

  int _percent(DownloadSummary summary) {
    if (summary.progress <= 0) {
      return -1;
    }
    return (summary.progress * 100).floor().clamp(0, 100);
  }

  /// 是否已经在系统的「不优化」白名单里。
  Future<bool> get ignoringBatteryOptimizations async {
    if (!App.isAndroid) {
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>(
            "isIgnoringBatteryOptimizations",
          ) ??
          false;
    } catch (_) {
      return true;
    }
  }

  /// 拉起系统的「电池优化」申请页。
  Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!App.isAndroid) {
      return true;
    }
    try {
      return await _channel.invokeMethod<bool>(
            "requestIgnoreBatteryOptimizations",
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _invoke(String method, Map<String, Object?> args) async {
    try {
      // 原生侧会明确回答「服务到底拉起来没有」，不能只看有没有抛异常：
      // startForeground 被系统拒绝时是内部 catch 掉的。
      var result = await _channel.invokeMethod<bool>(method, args);
      return result ?? false;
    } catch (e, s) {
      // 桌面端 / widget 测试里没有这条通道，失败不影响下载本身
      Log.error("Download", "Background service $method failed: $e", s);
      return false;
    }
  }
}
