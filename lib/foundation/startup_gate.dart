import 'dart:async';

/// 启动闸门。
///
/// 启动页退场时打开。需要「启动后马上开始做事、但要等 UI 就绪才能弹窗」的
/// 逻辑（启动检查更新就是典型）用它来同步，而不是靠 `Future.delayed(2s)` 猜
/// 一个固定时长——猜短了弹窗糊在启动页上，猜长了用户就得干等。
final Completer<void> _startupGate = Completer<void>();

/// 启动页是否已经退场。
bool get isStartupReady => _startupGate.isCompleted;

/// 启动页退场后完成。启动页还没结束就调用的协程会挂在这里。
Future<void> get startupReady => _startupGate.future;

/// 启动页退场时调用，只生效一次。
void completeStartup() {
  if (!_startupGate.isCompleted) {
    _startupGate.complete();
  }
}
