import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/features/cloud_backup/comic_archive_batch.dart';
import 'package:venera/features/cloud_backup/comic_backup.dart';
import 'package:venera/utils/upload_background.dart';

/// 一个排队中的归档任务。
class _ArchiveJob {
  _ArchiveJob({
    required this.batch,
    required this.title,
    required this.upload,
    required this.total,
  });

  final ComicArchiveBatch batch;
  final String title;
  final bool upload;
  final int total;
  final completer = Completer<BackupResult>();

  int done = 0;
  String current = '';

  /// 当前文件内部的进度（0..1），用来把通知栏的百分比做细。
  double fileFraction = 0;
  int fileCompleted = 0;
  int? fileTotal;
}

/// 备份 / 恢复任务的全局队列。
///
/// 上传以前是「对话框跑、关掉就停」，切出去或者手滑关掉就得从头再来。现在
/// 任务归这个单例所有：对话框、页面横幅都只是它的视图，关掉视图不影响传输，
/// 同时用 Android 前台服务把进程提着，切后台、锁屏也能传完。
class ArchiveTaskQueue extends ChangeNotifier {
  ArchiveTaskQueue._();

  static final ArchiveTaskQueue instance = ArchiveTaskQueue._();

  final List<_ArchiveJob> _pending = [];

  _ArchiveJob? _active;

  BackupResult? _lastResult;

  String _lastTitle = '';

  bool _retrying = false;

  /// 批次是否真的在跑。`_active` 在跑完之后还要留着给界面看结果，所以不能
  /// 用它判断忙碌状态。
  bool _running = false;

  /// 当前是否有任务在跑（含重试）。
  bool get isBusy => _running;

  /// 正在跑的任务标题。
  String get activeTitle => _active?.title ?? '';

  /// 正在跑的批次，没有则为 null。
  ComicArchiveBatch? get activeBatch => _active?.batch;

  /// 排队等待的任务数（不含正在跑的）。
  int get pendingCount => _pending.length;

  /// 正在跑的进度：已完成 / 总数 / 当前文件。
  int get done => _active?.done ?? 0;

  int get total => _active?.total ?? 0;

  String get current => _active?.current ?? '';

  /// 整体进度（含当前文件字节进度），0..1。
  double get fraction {
    if (total <= 0) return 0;
    final value = (done + (_active?.fileFraction ?? 0)) / total;
    return value.clamp(0.0, 1.0);
  }

  /// 当前文件已传 / 总字节，没有则为 0 / null。
  int get fileCompleted => _active?.fileCompleted ?? 0;

  int? get fileTotal => _active?.fileTotal;

  /// 最近一次结束的任务结果，供页面展示。
  BackupResult? get lastResult => _lastResult;

  String get lastTitle => _lastTitle;

  /// 是否有可重试的失败项。
  bool get canRetry =>
      !_running &&
      !_retrying &&
      (_active?.batch.hasRetryableFailures ?? false);

  /// 仅测试用：把队列恢复到干净状态。
  @visibleForTesting
  void resetForTest() {
    _pending.clear();
    _active = null;
    _running = false;
    _retrying = false;
    _lastResult = null;
    _lastTitle = '';
  }

  /// 这个批次是否已经在队列里（正在跑或排队）。
  bool owns(ComicArchiveBatch batch) =>
      _active?.batch == batch || _pending.any((job) => job.batch == batch);

  /// 提交一个任务；返回的 Future 在它跑完（或被取消）时完成。
  ///
  /// 多个任务串行执行，界面上看到的是队列，不会因为连点两次就并发上传同一
  /// 个账号把网盘打限流。
  Future<BackupResult> submit(
    ComicArchiveBatch batch, {
    required String title,
    bool upload = true,
  }) {
    final job = _ArchiveJob(
      batch: batch,
      title: title,
      upload: upload,
      total: batch.items.length,
    );
    _pending.add(job);
    _notify();
    unawaited(_pump());
    return job.completer.future;
  }

  /// 取消正在跑的任务，并丢弃排队中的。
  void cancelAll() {
    final active = _active;
    active?.batch.cancel();
    // 只置取消标记要等当前文件传完才生效；正在传的几百 MB 会一直挂着。
    // 顺手把网盘侧的请求也断掉，取消要立刻见效。
    unawaited(ComicBackupManager.cancelActiveTasks());
    for (final job in _pending) {
      if (!job.completer.isCompleted) {
        job.completer.complete(
          const BackupResult(success: 0, skipped: 0, failed: 0),
        );
      }
    }
    _pending.clear();
    _notify();
  }

  /// 重试当前批次里失败的条目。
  Future<void> retryActive() async {
    final job = _active;
    if (job == null || _running || _retrying) return;
    if (!job.batch.hasRetryableFailures) return;
    _retrying = true;
    _running = true;
    _notify();
    _attachFileProgress(job);
    _syncBackground(job);
    try {
      await job.batch.run(
        retryFailed: true,
        onProgress: (current, total, title) {
          job.current = title;
          job.done = current - 1;
          job.fileFraction = 0;
          job.fileCompleted = 0;
          job.fileTotal = null;
          _syncBackground(job);
          _notify();
        },
      );
      _lastResult = BackupResult.fromBatch(job.batch);
    } finally {
      _retrying = false;
      _running = false;
      _finishBackground(job);
      _notify();
    }
  }

  Future<void> _pump() async {
    if (_running || _pending.isEmpty) return;
    final job = _pending.removeAt(0);
    _active = job;
    _running = true;
    _notify();
    _attachFileProgress(job);
    _syncBackground(job);
    try {
      await job.batch.run(
        onProgress: (current, total, title) {
          job.current = title;
          job.done = current - 1;
          job.fileFraction = 0;
          job.fileCompleted = 0;
          job.fileTotal = null;
          _syncBackground(job);
          _notify();
        },
      );
      job.done = job.total;
      job.current = '';
      final result = BackupResult.fromBatch(job.batch);
      _lastResult = result;
      _lastTitle = job.title;
      if (!job.completer.isCompleted) job.completer.complete(result);
    } catch (error) {
      // run() 内部已经按条目记了错误；这里只兜住批次级异常，别让队列卡死。
      final result = BackupResult.fromBatch(job.batch);
      _lastResult = result;
      _lastTitle = job.title;
      if (!job.completer.isCompleted) job.completer.complete(result);
    } finally {
      _running = false;
      _finishBackground(job);
      _notify();
      unawaited(_pump());
    }
  }

  /// 让批次把当前文件的字节进度汇总到通知栏。
  void _attachFileProgress(_ArchiveJob job) {
    job.batch.onFileProgress = (title, completed, total) {
      if (!job.upload) return;
      job.current = title;
      job.fileCompleted = completed;
      job.fileTotal = total;
      job.fileFraction = total == null || total <= 0
          ? 0
          : (completed / total).clamp(0.0, 1.0);
      _syncBackground(job);
      _notify();
    };
  }

  void _syncBackground(_ArchiveJob job) {
    if (!job.upload) return;
    UploadBackground.instance.update(
      UploadProgress(
        done: job.done,
        total: job.total,
        current: job.current,
        title: job.title,
        fileFraction: job.fileFraction,
      ),
    );
  }

  void _finishBackground(_ArchiveJob job) {
    if (!job.upload) return;
    final result = BackupResult.fromBatch(job.batch);
    UploadBackground.instance.notifyDone(
      title: '${job.title}完成',
      text: '成功 ${result.success} · 跳过 ${result.skipped} · 失败 ${result.failed}',
    );
  }

  void _notify() {
    // 批次进度事件很密（每个条目一次），这里合并到下一帧，避免对话框、
    // 横幅和通知三处各刷一遍。
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      notifyListeners();
    });
  }

  bool _notifyScheduled = false;
}

/// 供页面显示的简短进度文本。
String archiveQueueSummary() {
  final queue = ArchiveTaskQueue.instance;
  if (!queue.isBusy) return '';
  final total = queue.total;
  if (total <= 0) return '准备中…';
  return '${queue.done} / $total';
}
