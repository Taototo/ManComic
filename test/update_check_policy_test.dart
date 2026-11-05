import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/update_check_policy.dart';

/// 自动检查的节流规则。
///
/// 这里守的是一个真实踩过的坑：用户 00:38 查过更新（当时没有新版），
/// 01:00 发了新版本，01:05 重启 App 却没看到提示——因为当时窗口是 30 分钟，
/// `now - lastSuccess = 27 分钟` 被当成「刚查过」跳过了。所以 27 分钟这个
/// 用例必须查。
void main() {
  final now = DateTime(2026, 11, 6, 1, 5);
  int ago(Duration d) => now.subtract(d).millisecondsSinceEpoch;

  UpdateCheckSkip check({
    bool enabled = true,
    bool versionChanged = false,
    Duration? successAgo,
    Duration? failureAgo,
  }) {
    return updateCheckSkipReason(
      enabled: enabled,
      versionChanged: versionChanged,
      now: now,
      lastSuccessMs: successAgo == null ? 0 : ago(successAgo),
      lastFailureMs: failureAgo == null ? 0 : ago(failureAgo),
    );
  }

  test('开关关掉就不查', () {
    expect(check(enabled: false), UpdateCheckSkip.disabled);
    // 开关关掉优先级最高，其他条件不参与判断
    expect(
      check(enabled: false, versionChanged: true, failureAgo: Duration.zero),
      UpdateCheckSkip.disabled,
    );
  });

  test('27 分钟前查过照样要查——这就是漏掉更新的那次', () {
    expect(
      check(successAgo: const Duration(minutes: 27)),
      UpdateCheckSkip.none,
    );
  });

  test('5 分钟窗口内不重复请求', () {
    expect(
      check(successAgo: const Duration(minutes: 1)),
      UpdateCheckSkip.tooSoon,
    );
    expect(
      check(successAgo: const Duration(minutes: 4, seconds: 59)),
      UpdateCheckSkip.tooSoon,
    );
  });

  test('刚好过 5 分钟就查', () {
    expect(check(successAgo: const Duration(minutes: 5)), UpdateCheckSkip.none);
  });

  test('刚装完新版必查，不被上次的节流挡住', () {
    expect(
      check(versionChanged: true, successAgo: const Duration(seconds: 10)),
      UpdateCheckSkip.none,
    );
  });

  test('失败后按自己的间隔退避', () {
    expect(
      check(failureAgo: const Duration(minutes: 2)),
      UpdateCheckSkip.afterFailure,
    );
    expect(
      check(failureAgo: const Duration(minutes: 6)),
      UpdateCheckSkip.none,
    );
  });

  test('失败退避不占用成功额度：三小时前成功、一分钟前失败，仍要等', () {
    expect(
      check(
        successAgo: const Duration(hours: 3),
        failureAgo: const Duration(minutes: 1),
      ),
      UpdateCheckSkip.afterFailure,
    );
  });

  test('从没查过时直接查', () {
    expect(check(), UpdateCheckSkip.none);
  });
}
