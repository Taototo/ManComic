import 'package:flutter/foundation.dart';

/// 单个归档条目的状态。
enum ArchiveItemState { pending, working, success, skipped, failed, cancelled }

/// 一个待归档的目标（一部漫画或一个备份文件）及其运行结果。
class ArchiveItem {
  ArchiveItem({required this.title, required this.fileName});

  /// 界面上显示的标题。
  final String title;

  /// 远端文件名。
  final String fileName;

  ArchiveItemState _state = ArchiveItemState.pending;
  Object? _error;
  StackTrace? _stack;
  bool _retryAllowed = true;

  ArchiveItemState get state => _state;
  Object? get error => _error;
  StackTrace? get stack => _stack;

  /// 失败后是否允许重试。
  bool get canRetry => _state == ArchiveItemState.failed && _retryAllowed;
}

/// 归档传输失败。
///
/// [retryAllowed] 为 false 时批次不会把该条目标记为可重试，
/// 用于「目标已变化」「导入已落盘」这类重试会造成重复副作用的场景。
class ArchiveTransferFailure implements Exception {
  const ArchiveTransferFailure(this.message, {this.retryAllowed = true});

  final String message;
  final bool retryAllowed;

  @override
  String toString() => message;
}

/// 处理单个条目的动作。
///
/// [index] 为条目下标，[retry] 表示这是重试，[isCancelled] 用于查询取消状态。
typedef ArchiveItemAction =
    Future<ArchiveItemState> Function(
      int index,
      bool retry,
      bool Function() isCancelled,
    );

/// 内存中的归档批次；重试会保留原始目标与已完成的行。
class ComicArchiveBatch extends ChangeNotifier {
  ComicArchiveBatch({
    required Iterable<ArchiveItem> items,
    required ArchiveItemAction action,
    required this.errorText,
    bool Function(Object error)? retryAllowed,
  }) : items = List.unmodifiable(items),
       _action = action,
       _retryAllowed = retryAllowed ?? ((_) => true);

  /// 全部条目（不可修改）。
  final List<ArchiveItem> items;
  final ArchiveItemAction _action;
  final bool Function(Object error) _retryAllowed;

  /// 把错误对象转成展示给用户的文本。
  final String Function(Object error) errorText;

  /// 当前文件的字节级进度回调（标题、已传、总字节）。
  ///
  /// 由任务队列在接管批次时挂上，用来更新通知栏；不挂就不汇报。
  void Function(String title, int completed, int? total)? onFileProgress;

  bool _running = false;
  bool _cancelRequested = false;
  bool _disposed = false;

  bool get running => _running;
  bool get cancelRequested => _cancelRequested;

  /// 统计处于指定状态的条目数。
  int count(ArchiveItemState state) =>
      items.where((item) => item.state == state).length;

  /// 是否存在可重试的失败条目。
  bool get hasRetryableFailures => items.any((item) => item.canRetry);

  /// 是否还有未处理（含被取消）的条目。
  bool get hasPending => items.any(
    (item) =>
        item.state == ArchiveItemState.pending ||
        item.state == ArchiveItemState.cancelled,
  );

  /// 请求取消；只对正在运行的批次生效。
  void cancel() {
    if (!_running || _cancelRequested) return;
    _cancelRequested = true;
    _notify();
  }

  /// 顺序处理条目。
  ///
  /// [retryFailed] 只处理可重试的失败项，[onlyIndex] 只处理指定下标，
  /// [onProgress] 汇报进度，[isCancelled] 供外部追加取消条件。
  Future<void> run({
    bool retryFailed = false,
    int? onlyIndex,
    void Function(int current, int total, String title)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (_disposed || _running) return;
    final targets = [
      for (var i = 0; i < items.length; i++)
        if ((onlyIndex == null || onlyIndex == i) &&
            (retryFailed
                ? items[i].canRetry
                : items[i].state == ArchiveItemState.pending ||
                      items[i].state == ArchiveItemState.cancelled))
          i,
    ];
    if (targets.isEmpty) return;
    _running = true;
    _cancelRequested = false;
    _notify();
    bool cancelled() => _cancelRequested || isCancelled?.call() == true;
    try {
      for (var position = 0; position < targets.length; position++) {
        if (cancelled()) break;
        final index = targets[position];
        final item = items[index];
        final retry = item.state == ArchiveItemState.failed;
        item._state = ArchiveItemState.working;
        item._error = null;
        item._stack = null;
        _notify();
        try {
          onProgress?.call(position + 1, targets.length, item.title);
          item._state = await _action(index, retry, cancelled);
        } catch (error, stack) {
          item._state = ArchiveItemState.failed;
          item._error = error;
          item._stack = stack;
          item._retryAllowed =
              _retryAllowed(error) &&
              (error is! ArchiveTransferFailure || error.retryAllowed);
        }
        _notify();
      }
    } finally {
      _cancelRequested = cancelled();
      _running = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelRequested = true;
    super.dispose();
  }
}
