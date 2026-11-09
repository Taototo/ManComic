import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 这几条都是「回退一次就用户可见」的行为，用源码守卫钉住。
///
/// 背景：1.4.47 之前后台下载会在切出去两分钟后停住、重启后进度回到 0、
/// 预估体积能跳到几个 G。根因分散在 Dart 和后端两处，单测跑不到，于是
/// 按项目现有习惯（见 export_paths_test.dart）做静态断言。
void main() {
  String read(String path) => File(path).readAsStringSync();

  group('后台下载不只靠前台服务', () {
    test('原生服务会被系统重启，并定时续 wakelock', () {
      var service = read(
        'android/app/src/main/kotlin/com/github/wgh136/venera/ComicDownloadService.kt',
      );
      // START_NOT_STICKY：服务被 ROM 掐掉后不会再回来
      expect(service.contains('START_STICKY'), isTrue);
      // 两小时到点自己松手，长篇下到一半就断
      expect(service.contains('renewWakeLock'), isTrue);
      // Android 12+ 会把这个通知压后 10 秒才显示
      expect(service.contains('FOREGROUND_SERVICE_IMMEDIATE'), isTrue);
    });

    test('拉起失败会重试，而不是等下一次任务事件', () {
      var source = read('lib/utils/download_background.dart');
      expect(source.contains('_startRetryIntervalMs'), isTrue);
      // 原生侧 startForeground 失败是内部 catch 的，只看有没有抛异常会误判成功
      expect(source.contains('invokeMethod<bool>'), isTrue);
    });

    test('网络错误停下的任务回前台会自己续上', () {
      var local = read('lib/foundation/local.dart');
      expect(local.contains('retryErroredTasks'), isTrue);
      var init = read('lib/init.dart');
      expect(init.contains('retryErroredTasks'), isTrue);
      // 进后台立刻落盘，否则划掉应用时那 1.2 秒的合并窗口会丢
      expect(init.contains('saveDownloadProgressNow'), isTrue);
    });
  });

  group('重启后的进度以磁盘为准', () {
    test('恢复任务后先扫目录校正', () {
      var local = read('lib/foundation/local.dart');
      expect(local.contains('reconcileProgress'), isTrue);
      var download = read('lib/network/download.dart');
      expect(download.contains('Future<void> reconcileProgress()'), isTrue);
    });

    test('字节数也从磁盘重新算，不只沿用 JSON', () {
      var download = read('lib/network/download.dart');
      expect(download.contains('_diskBytes'), isTrue);
      // 估算必须用最近样本，不能拿累计平均（第一张长图能放大几十倍）
      expect(download.contains('recentPageBytes'), isTrue);
    });
  });

  group('本地详情页的目录跟网络源一致', () {
    test('打开页面就去源上要一次章节表', () {
      var page = read('lib/pages/local_comic_page.dart');
      expect(page.contains('_loadRemoteChapters'), isTrue);
      // 拉到的目录要写回本地库，否则阅读器/导出还是按旧序号走
      expect(page.contains('LocalManager().add('), isTrue);
    });
  });

  group('失效分类可以原路退回', () {
    test('记录来源分类并支持恢复', () {
      var favorites = read('lib/foundation/favorites.dart');
      expect(favorites.contains('restoreValidInvalid'), isTrue);
      expect(favorites.contains('origin TEXT'), isTrue);
      var page = read('lib/pages/favorites/local_favorites_page.dart');
      expect(page.contains('recheckInvalid'), isTrue);
    });
  });
}
