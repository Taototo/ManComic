import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

/// 退出提示改成「再按一次」之后，判断逻辑决定了第二次侧滑要不要真的退出。
/// 这里把它从组件的 State 里拆出来单测：太宽松会在提示消失后仍然一滑就退，
/// 太严格则永远退不出去。
void main() {
  const window = Duration(seconds: 2);
  final t0 = DateTime(2026, 11, 5, 12, 0, 0);

  test('第一次返回只提示，不退出', () {
    expect(isSecondExitAttempt(null, t0, window), isFalse);
  });

  test('提示还在显示时的第二次返回才退出', () {
    expect(
      isSecondExitAttempt(t0, t0.add(const Duration(milliseconds: 600)), window),
      isTrue,
    );
    // 正好卡在窗口边缘也算
    expect(isSecondExitAttempt(t0, t0.add(window), window), isTrue);
  });

  test('提示消失之后再返回，重新算第一次', () {
    expect(
      isSecondExitAttempt(
        t0,
        t0.add(const Duration(milliseconds: 2100)),
        window,
      ),
      isFalse,
    );
  });

  test('系统时间被回拨时不会误退出', () {
    expect(
      isSecondExitAttempt(t0, t0.subtract(const Duration(minutes: 5)), window),
      isFalse,
    );
  });
}
