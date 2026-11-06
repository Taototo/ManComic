import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/update_check_policy.dart';

/// 自动检查的规则。
///
/// 这里守的是两个真实踩过的坑：
/// 1. 用户 00:38 查过更新（当时没有新版），01:00 发版，01:05 重启却没提示
///    ——当时窗口是 30 分钟，`now - lastSuccess = 27 分钟` 被当成「刚查过」。
/// 2. 缩到 5 分钟后同一个坑还在：提示过一次、点了取消、马上重启，5 分钟内
///    依旧什么都不弹。所以现在**冷启动完全不节流**，只有切回前台才看窗口。
void main() {
  final now = DateTime(2026, 11, 6, 1, 5);
  int ago(Duration d) => now.subtract(d).millisecondsSinceEpoch;

  UpdateCheckSkip check({
    bool enabled = true,
    bool fromResume = false,
    bool versionChanged = false,
    Duration? successAgo,
    Duration? failureAgo,
  }) {
    return updateCheckSkipReason(
      enabled: enabled,
      fromResume: fromResume,
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
    expect(
      check(enabled: false, fromResume: true, successAgo: Duration.zero),
      UpdateCheckSkip.disabled,
    );
  });

  test('冷启动不节流：一分钟前查过照样查', () {
    // 用户提示过一次、取消、立刻重启的那个场景
    expect(check(successAgo: const Duration(minutes: 1)), UpdateCheckSkip.none);
    expect(check(successAgo: const Duration(seconds: 5)), UpdateCheckSkip.none);
  });

  test('冷启动不因刚才失败过而退避', () {
    expect(check(failureAgo: const Duration(minutes: 1)), UpdateCheckSkip.none);
  });

  test('冷启动：27 分钟前查过当然要查', () {
    expect(check(successAgo: const Duration(minutes: 27)), UpdateCheckSkip.none);
  });

  test('切回前台：5 分钟窗口内不重复请求', () {
    expect(
      check(fromResume: true, successAgo: const Duration(minutes: 1)),
      UpdateCheckSkip.tooSoon,
    );
    expect(
      check(
        fromResume: true,
        successAgo: const Duration(minutes: 4, seconds: 59),
      ),
      UpdateCheckSkip.tooSoon,
    );
  });

  test('切回前台：刚好过 5 分钟就查', () {
    expect(
      check(fromResume: true, successAgo: const Duration(minutes: 5)),
      UpdateCheckSkip.none,
    );
  });

  test('刚装完新版必查，不被上次的节流挡住', () {
    expect(
      check(
        fromResume: true,
        versionChanged: true,
        successAgo: const Duration(seconds: 10),
      ),
      UpdateCheckSkip.none,
    );
  });

  test('切回前台：失败后按自己的间隔退避', () {
    expect(
      check(fromResume: true, failureAgo: const Duration(minutes: 2)),
      UpdateCheckSkip.afterFailure,
    );
    expect(
      check(fromResume: true, failureAgo: const Duration(minutes: 6)),
      UpdateCheckSkip.none,
    );
  });

  test('失败退避不占用成功额度：三小时前成功、一分钟前失败，仍要等', () {
    expect(
      check(
        fromResume: true,
        successAgo: const Duration(hours: 3),
        failureAgo: const Duration(minutes: 1),
      ),
      UpdateCheckSkip.afterFailure,
    );
  });

  test('从没查过时直接查', () {
    expect(check(), UpdateCheckSkip.none);
    expect(check(fromResume: true), UpdateCheckSkip.none);
  });

  group('自动弹窗的重复提示', () {
    bool prompt({
      String version = "1.4.20",
      String? promptedVersion,
      Duration? promptedAgo,
    }) {
      return shouldPromptUpdateAgain(
        version: version,
        promptedVersion: promptedVersion,
        promptedAt: promptedAgo == null ? null : now.subtract(promptedAgo),
        now: now,
      );
    }

    test('没弹过就弹', () {
      expect(prompt(), isTrue);
    });

    test('同一版本刚弹过不弹——短时间内切前台别反复骚扰', () {
      expect(
        prompt(promptedVersion: "1.4.20", promptedAgo: const Duration(minutes: 1)),
        isFalse,
      );
      expect(
        prompt(
          promptedVersion: "1.4.20",
          promptedAgo: const Duration(minutes: 9, seconds: 59),
        ),
        isFalse,
      );
    });

    test('同一版本过了 10 分钟再打开 App 要重新提示', () {
      // 「取消」只是「现在不想装」，不是「以后都别问」
      expect(
        prompt(
          promptedVersion: "1.4.20",
          promptedAgo: const Duration(minutes: 10),
        ),
        isTrue,
      );
    });

    test('换成另一个版本立刻提示', () {
      expect(
        prompt(
          version: "1.4.21",
          promptedVersion: "1.4.20",
          promptedAgo: const Duration(minutes: 1),
        ),
        isTrue,
      );
    });

    test('记了版本却没记时间，按没弹过处理', () {
      expect(prompt(promptedVersion: "1.4.20"), isTrue);
    });
  });
}
