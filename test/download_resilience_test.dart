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

    test('地址表没落盘也能算出分母', () {
      var download = read('lib/network/download.dart');
      // 每章页数写进进度快照，恢复时不依赖那张几百 KB 的地址表
      expect(download.contains('"chapterPages"'), isTrue);
      expect(download.contains('_chapterPageHint'), isTrue);
    });

    test('空地址表不会被当成已经下完', () {
      var download = read('lib/network/download.dart');
      expect(download.contains('_images!.isEmpty'), isTrue);
    });

    test('目录没就绪 / 扫不到文件时不把进度抹成 0', () {
      var download = read('lib/network/download.dart');
      expect(download.contains('is not ready'), isTrue);
      expect(download.contains('No page found on disk'), isTrue);
    });

    test('目录记录丢了会找回旧目录', () {
      var local = read('lib/foundation/local.dart');
      expect(local.contains('findReusableDirectory'), isTrue);
      var download = read('lib/network/download.dart');
      expect(download.contains('findReusableDirectory'), isTrue);
      // 任务表坏了只备份，不再整份删除
      expect(local.contains('.bak'), isTrue);
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

  group('收藏页「本地」分类', () {
    test('收藏里的「本地漫画」指向本地库页面，不再自己投影一份', () {
      var page = read('lib/pages/favorites/local_favorites_page.dart');
      expect(page.contains('localLibraryItems'), isFalse);
      // 以前靠「把收藏挪进 __downloaded__」实现，既动分类又漏掉没收藏的下载
      var favorites = read('lib/foundation/favorites.dart');
      expect(favorites.contains('moveDownloadedToLocalFolder'), isFalse);
      // 入口在侧栏，直接打开那一页
      var sideBar = read('lib/pages/favorites/side_bar.dart');
      expect(sideBar.contains('() => const LocalComicsPage()'), isTrue);
    });

    test('「失效」分类连同判定一起移除了', () {
      var favorites = read('lib/foundation/favorites.dart');
      // 1.4.55 删掉：老库里的表也要清掉，否则会冒充普通分类出现在侧栏
      expect(favorites.contains('_legacyInvalidFolderName'), isTrue);
      expect(favorites.contains('invalidCount'), isFalse);
      expect(favorites.contains('restoreValidInvalid'), isFalse);
      var page = read('lib/pages/favorites/local_favorites_page.dart');
      expect(page.contains('recheckInvalid'), isFalse);
      expect(page.contains('Clean up invalid'), isFalse);
    });
  });

  group('下载不再显示预估体积', () {
    test('下载页只报剩余百分比', () {
      var page = read('lib/pages/downloading_page.dart');
      expect(page.contains('_remainingText'), isTrue);
      // 「≈ 2.1 GB」这类外推值会让用户以为下载算错了
      expect(page.contains('≈'), isFalse);
      expect(page.contains('_sizeText'), isFalse);
      expect(page.contains('totalBytes'), isFalse);
    });

    test('通知栏进度也按页数算，不用字节估算', () {
      var local = read('lib/foundation/local.dart');
      expect(local.contains('progress += task.progress'), isTrue);
    });
  });

  group('本地目录和网络源同一套样式', () {
    test('章节表是网格，并且能切正序/倒序', () {
      var page = read('lib/pages/local_comic_page.dart');
      expect(page.contains('_ChapterSection'), isTrue);
      expect(page.contains('SliverGridDelegateWithFixedHeight'), isTrue);
      // 倒序按钮：和网络源详情页一样的图标
      expect(page.contains('vertical_align_bottom_outlined'), isTrue);
      // 初值读同一个设置项，两边切换口径一致
      expect(page.contains('reverseChapterOrder'), isTrue);
    });
  });
}
