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
    required this.speed,
    required this.progress,
    this.title,
  });

  /// 正在跑的任务数
  final int running;

  /// 排队中（受并发上限约束还没开跑）的任务数
  final int queued;

  /// 所有在跑任务的合计速度，bytes/s
  final int speed;

  /// 0..1，总量未知时为 0
  final double progress;

  /// 第一部在跑的漫画名，通知里当标题用
  final String? title;
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

  /// 服务是否已经拉起
  bool _active = false;

  /// 通知是否已经能更新（start 之后就绪）
  bool _started = false;

  bool _permissionRequested = false;

  String _lastText = '';

  int _lastPercent = -2;

  int _lastPushMs = 0;

  /// 上一次尝试拉起服务的时刻（毫秒）。
  ///
  /// 拉起失败（冷启动时序不对、后台启动被拒）不能就此放弃：进程一旦被打成
  /// 「缓存进程」，切到后台一两分钟就会被系统冻住 —— 用户看到的就是「下载
  /// 自己停了」。这里按 5 秒的间隔重试，直到成功为止。
  int _lastStartAttemptMs = 0;

  static const _startRetryIntervalMs = 5000;

  /// 服务活着的时候多久重新声明一次。
  ///
  /// 原生侧靠 wakelock 定时续期活着，这条是兜底：进程被系统回收后重建、
  /// 服务被 ROM 的省电策略掐掉，都能被这条发现并拉回来。
  static const _keepAliveIntervalMs = 4 * 60 * 1000;

  int _lastKeepAliveMs = 0;

  bool get enabled => appdata.settings['backgroundDownload'] != false;

  /// 任务增删/启停时调用。有任务在跑就确保服务活着，全停了就摘掉通知。
  void refresh() {
    if (!App.isAndroid) {
      return;
    }
    final summary = summaryProvider?.call();
    if (!enabled || summary == null || summary.running <= 0) {
      _stop();
      return;
    }
    if (!_active) {
      _active = true;
      _started = false;
      _lastText = '';
      _lastPercent = -2;
      unawaited(_begin());
    }
    // 服务活着的时候靠这个 ticker 刷速度和百分比：逐页的进度变化不走
    // 前台服务（频率太高，会被系统按「通知刷太勤」限流）。
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _push());
  }

  Future<void> _begin() async {
    _lastStartAttemptMs = DateTime.now().millisecondsSinceEpoch;
    // 通知权限没给的话服务照样能跑，只是用户看不到进度，所以顺手问一次。
    // 拒绝也继续下载，不让权限挡住下载。
    try {
      if (!_permissionRequested) {
        _permissionRequested = true;
        if (!await NotificationService.hasPermission()) {
          if (!NotificationService.isForeground) {
            // 后台时弹权限框系统不认，等下次在前台再问
            _permissionRequested = false;
          } else {
            await NotificationService.requestPermission();
          }
        }
      }
    } catch (_) {}
    if (!_active) {
      return;
    }
    final summary = summaryProvider?.call();
    if (summary == null || summary.running <= 0) {
      _stop();
      return;
    }
    _lastText = _describe(summary);
    _lastPercent = _percent(summary);
    _lastPushMs = DateTime.now().millisecondsSinceEpoch;
    var ok = await _invoke("startDownloadService", {
      "title": _title(summary),
      "text": _lastText,
      "progress": _lastPercent,
    });
    if (!ok) {
      // 冷启动时序不对（进程还没被系统当成前台）时会被拒。别把状态留在
      // 「已启动」上，ticker 会隔几秒再试一次。
      _active = false;
      _started = false;
      return;
    }
    _started = true;
    _lastKeepAliveMs = DateTime.now().millisecondsSinceEpoch;
  }

  void _push() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!_active) {
      return;
    }
    if (!_started) {
      // 没拉起来就按间隔重试，别等下一次任务事件——很可能再也不会有。
      if (now - _lastStartAttemptMs >= _startRetryIntervalMs) {
        unawaited(_begin());
      }
      return;
    }
    final summary = summaryProvider?.call();
    if (summary == null || summary.running <= 0) {
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
    unawaited(_invoke("updateDownloadService", {
      "title": _title(summary),
      "text": text,
      "progress": percent,
    }).then<void>((_) {}));
  }

  void _stop() {
    _ticker?.cancel();
    _ticker = null;
    if (!_active) {
      return;
    }
    _active = false;
    _started = false;
    _lastText = '';
    _lastPercent = -2;
    unawaited(_invoke("stopDownloadService", const {}).then<void>((_) {}));
  }

  String _title(DownloadSummary summary) {
    return summary.title?.isNotEmpty == true ? summary.title! : "Downloading".tl;
  }

  String _describe(DownloadSummary summary) {
    // 速度必须排在最前面。
    //
    // 通知栏收起来只给一行，原来写成「3 个下载中 · 2 个排队 · 1.2 MB/s」，
    // 窄屏或者系统字体调大之后尾巴直接被省略号吃掉——用户看到的就是「只有
    // 状态没有速度」。放到开头，即使后面被截断，速度也还在。
    return [
      if (summary.speed > 0) "${_speedText(summary.speed)}/s",
      if (summary.running > 0) "@n downloading".tlParams({"n": summary.running}),
      if (summary.queued > 0) "@n queued".tlParams({"n": summary.queued}),
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
