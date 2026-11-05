import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/startup_gate.dart';

/// 启动闸门的行为：启动页退场前挂起、退场后放行、重复打开不抛异常。
///
/// 启动检查更新靠它决定「什么时候可以弹窗」，如果闸门提前打开，更新提示
/// 会糊在启动页上；如果永远不开，更新检查就此卡死。两种都不行，所以把
/// 这两条固定成测试。
void main() {
  test('闸门在启动页退场前挂起，退场后放行', () async {
    var passed = false;
    var waiter = startupReady.then((_) => passed = true);

    await Future.delayed(const Duration(milliseconds: 20));
    expect(isStartupReady, isFalse);
    expect(passed, isFalse);

    completeStartup();
    await waiter;

    expect(isStartupReady, isTrue);
    expect(passed, isTrue);
  });

  test('重复打开闸门不会抛异常', () async {
    completeStartup();
    completeStartup();
    await startupReady;
    expect(isStartupReady, isTrue);
  });
}
