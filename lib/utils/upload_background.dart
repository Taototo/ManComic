import 'dart:async';

import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';

/// 一次上传的整体进度。
class UploadProgress {
  const UploadProgress({
    this.done = 0,
    this.total = 0,
    this.current = '',
    this.title = '',
    this.fileFraction = 0,
  });

  /// 已完成（成功 + 跳过 + 失败）的文件数。
  final int done;

  /// 总文件数。
  final int total;

  /// 正在处理的文件名。
  final String current;

  /// 通知栏标题，通常是「正在上传到网盘」。
  final String title;

  /// 当前文件内部的进度（0..1）。
  final double fileFraction;

  /// 0..1；总数未知时按 0 处理（通知用不确定进度条）。
  ///
  /// 把当前文件的字节进度算进去：一部几百 MB 的 CBZ 只有「0/1」的话，
  /// 通知栏会一直停在 0%，看起来像卡死了。
  double get fraction {
    if (total <= 0) return 0;
    final value = (done + fileFraction.clamp(0.0, 1.0)) / total;
    return value.clamp(0.0, 1.0);
  }

  UploadProgress copyWith({
    int? done,
    int? total,
    String? current,
    String? title,
    double? fileFraction,
  }) {
    return UploadProgress(
      done: done ?? this.done,
      total: total ?? this.total,
      current: current ?? this.current,
      title: title ?? this.title,
      fileFraction: fileFraction ?? this.fileFraction,
    );
  }
}

/// 上传期间的原生前台服务。
///
/// 只负责「别被系统掐掉」和「通知栏上有进度」；分片上传、秒传、重试仍全部
/// 在 Dart 侧。和 [DownloadBackground] 是同一套保活策略，但通道方法与原生
/// Service 都是独立的，下载和上传同时跑时不会互相顶掉通知。
class UploadBackground {
  UploadBackground._();

  static final UploadBackground instance = UploadBackground._();

  static const _channel = MethodChannel('venera/method_channel');

  UploadProgress _progress = const UploadProgress();

  Timer? _ticker;

  /// 我们希望服务活着；和「服务已经起来了」不是一回事。
  bool _active = false;

  bool _started = false;

  int _failCount = 0;

  int _nextStartAttemptMs = 0;

  int _lastPushMs = 0;

  int _lastKeepAliveMs = 0;

  String _lastText = '';

  int _lastPercent = -2;

  bool _wakeLockHeld = true;

  static const _retryIntervalMs = 5000;

  static const _keepAliveIntervalMs = 4 * 60 * 1000;

  /// 汇报进度。第一次调用会把前台服务拉起来。
  void update(UploadProgress progress) {
    if (!App.isAndroid) return;
    _progress = progress;
    if (!_active) {
      _active = true;
      _started = false;
      _failCount = 0;
      _nextStartAttemptMs = 0;
      _lastText = '';
      _lastPercent = -2;
      unawaited(_begin());
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _push());
  }

  /// 任务结束：先摘进度通知，再停服务。
  void stop() {
    _ticker?.cancel();
    _ticker = null;
    if (!_active) return;
    _active = false;
    _started = false;
    _failCount = 0;
    _lastText = '';
    _lastPercent = -2;
    unawaited(_invoke('stopUploadService', const {}).then<void>((_) {}));
  }

  /// 后台跑完后留一条可点掉的通知，用户回来能知道结果。
  void notifyDone({required String title, required String text}) {
    if (!App.isAndroid) return;
    stop();
    unawaited(
      _invoke('notifyUploadDone', {
        'title': title,
        'text': text,
      }).then<void>((_) {}),
    );
  }

  Future<void> _begin() async {
    if (!_active) return;
    _nextStartAttemptMs =
        DateTime.now().millisecondsSinceEpoch + _retryIntervalMs;
    _lastText = _describe(_progress);
    _lastPercent = _percent(_progress);
    _lastPushMs = DateTime.now().millisecondsSinceEpoch;
    final ok = await _invoke('startUploadService', {
      'title': _title(_progress),
      'text': _lastText,
      'progress': _lastPercent,
    });
    if (!ok) {
      _failCount++;
      var backoff = _retryIntervalMs * (1 << (_failCount - 1).clamp(0, 6));
      if (backoff > 300000) backoff = 300000;
      _nextStartAttemptMs = DateTime.now().millisecondsSinceEpoch + backoff;
      return;
    }
    _failCount = 0;
    _started = true;
    _wakeLockHeld = true;
    _lastKeepAliveMs = DateTime.now().millisecondsSinceEpoch;
  }

  void _push() {
    if (!_active) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!_started) {
      if (now >= _nextStartAttemptMs) unawaited(_begin());
      return;
    }
    // 有文件在传才持锁；整批都在等网络重试时放掉，免得白耗电。
    _syncWakeLock(_progress.total > 0 && _progress.done < _progress.total);
    if (now - _lastKeepAliveMs >= _keepAliveIntervalMs) {
      _lastKeepAliveMs = now;
      unawaited(_begin());
      return;
    }
    if (now - _lastPushMs < 900) return;
    final text = _describe(_progress);
    final percent = _percent(_progress);
    if (text == _lastText && percent == _lastPercent) return;
    _lastText = text;
    _lastPercent = percent;
    _lastPushMs = now;
    unawaited(
      _invoke('updateUploadService', {
        'title': _title(_progress),
        'text': text,
        'progress': percent,
      }).then<void>((_) {}),
    );
  }

  void _syncWakeLock(bool hold) {
    if (hold == _wakeLockHeld) return;
    _wakeLockHeld = hold;
    unawaited(_invoke('setUploadWakeLock', {'hold': hold}).then<void>((_) {}));
  }

  String _title(UploadProgress progress) =>
      progress.title.isEmpty ? '正在上传到网盘' : progress.title;

  String _describe(UploadProgress progress) {
    final parts = <String>[
      if (progress.total > 0) '${progress.done}/${progress.total}',
      if (progress.current.isNotEmpty) progress.current,
    ];
    return parts.join(' · ');
  }

  int _percent(UploadProgress progress) {
    if (progress.total <= 0) return -1;
    return (progress.fraction * 100).floor().clamp(0, 100);
  }

  Future<bool> _invoke(String method, Map<String, Object?> args) async {
    try {
      final result = await _channel.invokeMethod<bool>(method, args);
      return result ?? false;
    } catch (e, s) {
      // 桌面端/测试环境没有这条通道，失败不影响上传本身。
      Log.warning('Upload', 'Background service $method failed: $e\n$s');
      return false;
    }
  }
}
