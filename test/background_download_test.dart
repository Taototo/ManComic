import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/download_background.dart';

/// 1.4.51：切到桌面挂后台一段时间后下载还是会停，而且停了不会自己恢复。
///
/// 根因有三条，都不在「前台服务有没有起来」上，而在「起来了以后还留不留」：
///  1. 前台服务的生死看的是 `running > 0`，网络抖一下任务变 error，服务立刻
///     被摘掉，进程降级成缓存进程——Android 12+ 之后不许再从后台拉起来，
///     于是永久停摆。
///  2. 拉起服务失败一次就把「想要服务」的意图也清了，之后没人再试。
///  3. 后台没人巡查：任务被网络错误停下后，退避阶梯走完就躺到用户回来。
void main() {
  String read(String path) => File(path).readAsStringSync();

  group('前台服务按「还有活」保活', () {
    test('只有等重试的任务也算有活', () {
      var summary = const DownloadSummary(
        running: 0,
        queued: 0,
        waiting: 2,
        speed: 0,
        progress: 0,
      );
      // 这条要是 false，refresh() 会直接把服务停掉，然后再也拉不起来
      expect(summary.hasWork, isTrue);
    });

    test('排队中也算有活', () {
      expect(
        const DownloadSummary(
          running: 0,
          queued: 3,
          waiting: 0,
          speed: 0,
          progress: 0,
        ).hasWork,
        isTrue,
      );
    });

    test('真的没活了才算没活', () {
      expect(
        const DownloadSummary(
          running: 0,
          queued: 0,
          waiting: 0,
          speed: 0,
          progress: 0,
        ).hasWork,
        isFalse,
      );
    });

    test('服务生命周期不再看 running', () {
      var source = read('lib/utils/download_background.dart');
      expect(source.contains('hasWork'), isTrue);
      // 这三处以前都是 `summary.running <= 0`，任何一处回退都会让服务
      // 在「网络抖一下」时被摘掉
      expect(source.contains('summary.running <= 0'), isFalse);
    });

    test('拉起失败保留意图并按退避重试', () {
      var source = read('lib/utils/download_background.dart');
      expect(source.contains('_failCount++'), isTrue);
      expect(source.contains('_nextStartAttemptMs'), isTrue);
      // 旧实现失败后把 _active 置回 false，ticker 直接短路，等于永久放弃
      expect(
        RegExp(r'if \(!ok\) \{[\s\S]{0,400}?_active = false;').hasMatch(source),
        isFalse,
      );
    });

    test('先起服务再要通知权限', () {
      // 反过来的话，权限对话框那个 await 里用户一按 Home 就进了后台，
      // Android 12+ 直接拒绝后台启动前台服务——进程退回缓存优先级。
      var source = read('lib/utils/download_background.dart');
      var begin = source.substring(source.indexOf('Future<void> _begin()'));
      var startIndex = begin.indexOf('startDownloadService');
      var permissionIndex = begin.indexOf('_ensureNotificationPermission');
      expect(startIndex, greaterThan(0));
      expect(permissionIndex, greaterThan(startIndex));
    });
  });

  group('看门狗策略', () {
    test('出错且不是用户暂停，到点就重试', () {
      expect(
        shouldRetryErroredTask(
          isError: true,
          userPaused: false,
          nowMs: 100000,
          lastAttemptMs: 0,
        ),
        isTrue,
      );
      expect(
        shouldRetryErroredTask(
          isError: true,
          userPaused: false,
          nowMs: 100000,
          lastAttemptMs: 100000 - LocalManager.watchdogRetryIntervalMs,
        ),
        isTrue,
      );
    });

    test('刚试过不重复试', () {
      expect(
        shouldRetryErroredTask(
          isError: true,
          userPaused: false,
          nowMs: 100000,
          lastAttemptMs: 100000 - 1000,
        ),
        isFalse,
      );
    });

    test('试得越久节奏越慢，别一直每分钟叫醒一次', () {
      expect(watchdogRetryInterval(0), LocalManager.watchdogRetryIntervalMs);
      expect(watchdogRetryInterval(9), LocalManager.watchdogRetryIntervalMs);
      expect(watchdogRetryInterval(10), 5 * 60 * 1000);
      expect(watchdogRetryInterval(999), 5 * 60 * 1000);
    });

    test('用户按了暂停的不碰，没出错的不碰', () {
      expect(
        shouldRetryErroredTask(
          isError: true,
          userPaused: true,
          nowMs: 100000,
          lastAttemptMs: 0,
        ),
        isFalse,
      );
      expect(
        shouldRetryErroredTask(
          isError: false,
          userPaused: false,
          nowMs: 100000,
          lastAttemptMs: 0,
        ),
        isFalse,
      );
    });
  });

  group('源码守卫', () {
    test('看门狗接在任务事件与队列泵上，空闲时自己退出', () {
      var local = read('lib/foundation/local.dart');
      expect(local.contains('_ensureWatchdog'), isTrue);
      expect(local.contains('_watchdogTick'), isTrue);
      expect(local.contains('Watchdog: retry'), isTrue);
      // 出错的任务归看门狗管，不能只靠「回前台」那一次
      expect(local.contains('refreshBackgroundService'), isTrue);
    });

    test('出错待重试的任务会进 summary', () {
      var local = read('lib/foundation/local.dart');
      expect(local.contains('waiting++'), isTrue);
      expect(local.contains('waiting: waiting'), isTrue);
    });

    test('详情/封面/地址表失败也自动重试', () {
      var download = read('lib/network/download.dart');
      // 逐页失败以外的四条路径
      expect(
        RegExp(r'autoRetry: true').allMatches(download).length >= 5,
        isTrue,
      );
      // 地址表只拉到一半必须整份作废，否则重试时会被当成「已经有了」
      expect(download.contains('_images = null;'), isTrue);
    });

    test('单页流有假死超时，自动重试会重新声明服务', () {
      var download = read('lib/network/download.dart');
      expect(download.contains('_stallTimeout'), isTrue);
      expect(download.contains('.timeout(_stallTimeout)'), isTrue);
      expect(download.contains('refreshBackgroundService'), isTrue);
    });

    test('Android 15 的 dataSync 时长上限有兜底', () {
      var service = read(
        'android/app/src/main/kotlin/com/github/wgh136/venera/ComicDownloadService.kt',
      );
      // 不 override onTimeout 的话系统会抛异常把进程带走
      expect(service.contains('override fun onTimeout'), isTrue);
    });
  });
}
