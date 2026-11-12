import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 这批修复的共同点：都不是「崩一下」就完事，而是会静默改掉用户数据
/// （章节记成已下载、收藏被顺手删、进度串书）。测试环境加载不了 sqlite /
/// rhttp，所以按项目既有做法做源码守卫，锁住那几个关键不变量。
/// Windows 上 git 按 autocrlf 把源码换成 CRLF，而断言里写的是 `\n`。
/// 统一成 LF，免得同一份代码在另一台机器上莫名其妙失败。
String read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  group('下载完成判定', () {
    test('缺页的章节不算已下载（跳章不会把半章写进库）', () {
      var src = read('lib/network/download.dart');
      // 判据从「目录里有任意一页」改成「页数够地址表」
      expect(src.contains('var expected = _images?[id]?.length;'), isTrue);
      expect(src.contains('if (pages.length >= expected)'), isTrue);
      // 旧判据必须消失，否则失败章的前 N-1 页会把它顶成「已下载」
      expect(
        src.contains(
          'dir.listSync().any((e) => e is File && isPageFileName(e.name))',
        ),
        isFalse,
      );
    });

    test('一章都没下成时不入库，留在列表里等重试', () {
      var src = read('lib/network/download.dart');
      expect(src.contains('if (local.downloadedChapters.isEmpty)'), isTrue);
      expect(src.contains('_setError('), isTrue);
      // 缺章要有能看见的提示，而不是任务一摘就没了
      expect(src.contains('chapters were not fully downloaded'), isTrue);
    });

    test('completeTask 复用已核好的结果，不再扫第二遍目录', () {
      var src = read('lib/foundation/local.dart');
      expect(
        src.contains('void completeTask(DownloadTask task, [LocalComic? local])'),
        isTrue,
      );
      expect(src.contains('add(local ?? task.toLocalComic(verifyChapters: true))'),
          isTrue);
    });
  });

  group('历史表与缓存', () {
    test('主键是 (id, type)，老库会重建一次', () {
      var src = read('lib/foundation/history.dart');
      expect(src.contains('primary key (id, type)'), isTrue);
      expect(src.contains('_migratePrimaryKey()'), isTrue);
      expect(
        src.contains('alter table history rename to history_legacy;'),
        isTrue,
      );
      // 旧主键必须不再出现
      expect(src.contains('id text primary key,'), isFalse);
    });

    test('缓存键带 type，本地书与网络书同 id 不会串进度', () {
      var src = read('lib/foundation/history.dart');
      expect(src.contains('_cacheKey(String id, int type)'), isTrue);
      expect(
        src.contains(
          '_cachedHistoryIds![_cacheKey(newItem.id, newItem.type.value)]',
        ),
        isTrue,
      );
      expect(src.contains('var key = _cacheKey(id, type.value);'), isTrue);
      expect(src.contains('if (cachedHistories.containsKey(key))'), isTrue);
      // 只按 id 命中的旧写法不能回来
      expect(src.contains('if (cachedHistories.containsKey(id))'), isFalse);
    });

    test('写库失败不会把 _haveAsyncTask 永久卡在 true', () {
      var src = read('lib/foundation/history.dart');
      expect(src.contains('_haveAsyncTask = true;\n    try {'), isTrue);
      expect(src.contains('} finally {'), isTrue);
    });
  });

  group('收藏与本地库', () {
    test('合并已下载章节时去重（源站加一话不该让列表翻倍）', () {
      var src = read('lib/foundation/local.dart');
      expect(
        src.contains('var downloaded = <String>{...comic.downloadedChapters};'),
        isTrue,
      );
      expect(src.contains('jsonEncode(downloaded.toList())'), isTrue);
    });

    test('全选 / 反选只作用于筛选后可见的条目', () {
      var src = read('lib/pages/favorites/local_favorites_page.dart');
      expect(
        src.contains(
          'var visible = searchMode ? searchResults : filterComics(comics);',
        ),
        isTrue,
      );
      expect(src.contains('selectedComics = comics.asMap()'), isFalse);
    });

    test('「已读」筛选直接用条目自己的 type', () {
      var src = read('lib/pages/favorites/local_favorites_page.dart');
      expect(src.contains('HistoryManager().find(comic.id, comic.type)'),
          isTrue);
      // 从 sourceKey 反推查不到 local / 已卸载源
      expect(src.contains('ComicType(comic.sourceKey.hashCode)'), isFalse);
    });

    test('本地书删除：删文件与删收藏/历史能分开选，且真的传下去', () {
      // 本地列表现在只有独立页一套，危险操作在那里做勾选。
      var src = read('lib/pages/local_comics_page.dart');
      expect(src.contains('Remove local favorite and history'), isTrue);
      expect(src.contains('Also remove files on disk'), isTrue);
      // 两个开关必须进到 batchDeleteComics 的参数里，否则勾了不生效
      expect(
        'removeComicFile'.allMatches(src).length,
        greaterThanOrEqualTo(3),
      );
      expect(
        'removeFavoriteAndHistory'.allMatches(src).length,
        greaterThanOrEqualTo(4),
      );
    });

    test('单本「标为已读」也会刷新 hash 表（否则「全部」角标不减）', () {
      var src = read('lib/foundation/favorites.dart');
      var start = src.indexOf('void moveToRead(');
      var end = src.indexOf('void batchMoveToRead(');
      expect(start, greaterThan(0));
      expect(end, greaterThan(start));
      expect(src.substring(start, end).contains('refreshHashedIds();'), isTrue);
    });

    test('侧栏数量跟着本地库走，且只在数量变化时重建', () {
      var src = read('lib/pages/favorites/side_bar.dart');
      expect(src.contains('LocalManager().addListener(_onLocalLibraryChanged)'),
          isTrue);
      expect(src.contains('LocalManager().removeListener(_onLocalLibraryChanged)'),
          isTrue);
      expect(src.contains('if (count == _lastLocalCount || !mounted)'), isTrue);
    });

    test('「本地漫画」只有一套界面：收藏里点它去本地库页面', () {
      var sideBar = read('lib/pages/favorites/side_bar.dart');
      expect(sideBar.contains('() => const LocalComicsPage()'), isTrue);
      // 收藏页不该再自己投影一份本地库列表
      var page = read('lib/pages/favorites/local_favorites_page.dart');
      expect(page.contains('localLibraryItems'), isFalse);
      expect(page.contains('isDownloadedFolder'), isFalse);
      // 上次停在这个分类的老用户回落到「全部」，不能显示空面板
      var fav = read('lib/pages/favorites/favorites_page.dart');
      expect(fav.contains('return (_localAllFolderLabel, false);'), isTrue);
    });
  });

  group('阅读器边界', () {
    test('空章节不会算出 maxPage = 0（否则 clamp(1, 0) 抛异常）', () {
      var src = read('lib/pages/reader/reader.dart');
      expect(
        src.contains('if (images == null || images!.isEmpty) return 1;'),
        isTrue,
      );
      var images = read('lib/pages/reader/images.dart');
      // 源站返回空列表时当错误处理，而不是把 images 设成空表
      expect(images.contains('No images found in this chapter'), isTrue);
    });

    test('章节下标有上界，非分组时清掉 group', () {
      var src = read('lib/pages/reader/reader.dart');
      expect(
        src.contains('if (chapterCount > 0 && chapter > chapterCount)'),
        isTrue,
      );
      expect(src.contains('history!.group = null;'), isTrue);
    });

    test('评论页没有 PhotoViewController 时不强断言', () {
      var src = read('lib/pages/reader/images.dart');
      expect(src.contains('photoViewControllers[reader.page]!'), isFalse);
    });

    test('退出阅读器恢复方向锁', () {
      var src = read('lib/pages/reader/scaffold.dart');
      var disposeStart = src.indexOf('  void dispose() {');
      expect(disposeStart, greaterThan(0));
      var disposeBody = src.substring(
        disposeStart,
        src.indexOf('super.dispose();', disposeStart),
      );
      expect(
        disposeBody.contains(
          'SystemChrome.setPreferredOrientations(DeviceOrientation.values);',
        ),
        isTrue,
      );
    });

    test('工具栏开关读「按这本书」的状态栏设置', () {
      var src = read('lib/pages/reader/scaffold.dart');
      var start = src.indexOf('void openOrClose()');
      expect(start, greaterThan(0));
      var body = src.substring(start, src.indexOf('\n  }', start));
      expect(body.contains('getReaderSetting('), isTrue);
      expect(body.contains("appdata.settings['showSystemStatusBar']"), isFalse);
    });
  });

  group('本地文件打不开', () {
    // 现象：手机上明明有图（缓存目录里躺着 jpg），点进去却转圈然后报
    // 「Request timed out」。根因是阅读器拿「数据库记录」而不是「磁盘」
    // 决定读本地还是读网络，记录一旦和文件对不上就整章走网络。

    test('记录说没下载，也要先看盘', () {
      var src = read('lib/pages/reader/images.dart');
      expect(
        src.contains('await manager.hasLocalPages(reader.cid, reader.type, ep)'),
        isTrue,
        reason: '磁盘才是事实，记录只是索引',
      );
      // 旧判据只看「整本在不在下载中」，整本下完后就再也不看盘了
      expect(
        src.contains('LocalManager().isDownloading(reader.cid, reader.type)'),
        isFalse,
      );
    });

    test('查本地文件用章节 id，不用行号', () {
      var src = read('lib/pages/reader/images.dart');
      // 阅读器的目录和本地库那份未必一样，行号会指到别的一话，
      // 还会顺手把那一话的记录当脏数据摘掉
      expect(src.contains('Object get _localEp'), isTrue);
      expect(
        src.contains('reader.widget.chapters?.ids.elementAtOrNull(reader.chapter - 1)'),
        isTrue,
      );
      expect(
        src.contains('await manager.getImages(reader.cid, reader.type, ep)'),
        isTrue,
      );
      expect(
        src.contains('manager.getPageMap(reader.cid, reader.type, ep)'),
        isTrue,
      );
      // 记录判定也得有按 id 的版本
      expect(
        read('lib/foundation/local.dart').contains(
          'bool isChapterRecorded(String id, ComicType type, Object ep)',
        ),
        isTrue,
      );
    });

    test('本地页先显示，缺的页在后台补', () {
      var src = read('lib/pages/reader/images.dart');
      var body = src.substring(
        src.indexOf('void load() async'),
        src.indexOf('/// 直接从源站要这一章的图'),
      );
      expect(body.contains('unawaited('), isTrue);
      // 「先 await 网络补页再 setState」会让断网时本地文件也打不开，
      // 源站抽风时还要先转十几秒圈才看到第一页
      expect(body.contains('images = await _fillPendingPages(images)'), isFalse);
    });

    test('本地漫画没有源站时不会空断言崩掉', () {
      var src = read('lib/pages/reader/images.dart');
      expect(src.contains('if (source?.loadComicPages == null)'), isTrue);
      expect(src.contains('reader.type.comicSource!.loadComicPages!'), isFalse);
    });
  });

  group('并发与统计', () {
    test('补位前先扣掉正在跑的任务，不突破并发上限', () {
      var src = read('lib/foundation/local.dart');
      expect(
        src.contains(
          'var running = downloadingTasks.where((t) => !t.isPaused && !t.isError).length;',
        ),
        isTrue,
      );
      expect(src.contains('var slots = maxConcurrentTasks - running;'), isTrue);
    });

    test('阅读统计的 day 与 start 同一天', () {
      var src = read('lib/foundation/reading_stats.dart');
      expect(src.contains('_dayKey(start),'), isTrue);
      expect(src.contains('_dayKey(end),'), isFalse);
    });

    test('删除作品有 comicId 时不再按标题兜一遍', () {
      var src = read('lib/foundation/reading_stats.dart');
      var start = src.indexOf('static void removeComic(');
      var body = src.substring(start, src.indexOf('\n  }', start));
      expect(body.contains('} else {'), isTrue);
      expect(
        body.contains('where source = ? and title = ?'),
        isTrue,
        reason: '没有 comicId 的老数据仍需按标题删',
      );
    });
  });

  group('同一页面里同一功能的重复入口', () {
    test('本地详情页：手机端横向那排不再重复收藏与继续阅读', () {
      var src = read('lib/pages/local_comic_page.dart');
      var start = src.indexOf('scrollDirection: Axis.horizontal');
      var bar = src.substring(start, src.indexOf('.fixHeight(48)', start));
      // Continue / Start / Favorite 三个图标在移动端都要让位给下面那排
      // 大按钮，否则一屏里两颗 Favorite、两颗 Continue。
      expect('!isMobile'.allMatches(bar).length, 3);
      expect(bar.contains("text: 'Share'.tl"), isTrue, reason: '分享没有替代品，保持无条件');
    });

    test('下载页：错误任务只给 Retry，不再同时给 Start', () {
      var src = read('lib/pages/downloading_page.dart');
      var start = src.indexOf('if (task.isError)');
      var block = src.substring(
        start,
        src.indexOf('Icons.vertical_align_top', start),
      );
      // isPaused = !isRunning，错误任务必然也算 paused。两个独立的 if 会
      // 让菜单同时出现 Retry 和 Start，其实都是 resume()。
      expect(block.contains('else if (!task.isPaused)'), isTrue);
    });

    test('本地漫画页：单本菜单不再重复「View Detail」', () {
      var src = read('lib/pages/local_comics_page.dart');
      var start = src.indexOf('menu: [');
      var single = src.substring(
        start,
        src.indexOf('...exportActions([comic])', start),
      );
      expect(single.contains('"View Detail".tl'), isFalse, reason: '点整行已经进详情');

      var multiStart = src.indexOf('Widget buildMultiSelectMenu()');
      var multi = src.substring(multiStart, multiStart + 1400);
      expect(
        multi.contains('"View Detail".tl'),
        isTrue,
        reason: '多选态点行是切换勾选，必须保留这条路径',
      );
    });

    test('收藏页：单本移动不再借道多选', () {
      var src = read('lib/pages/favorites/local_favorites_page.dart');
      var start = src.indexOf('builtInMenuActions: kComicMenuActionsFavorite');
      var menu = src.substring(start, src.indexOf('if (!isAllFolder)', start));
      // 只剩「Select」那一项会开多选；移动不该再把整页切进多选态。
      expect('multiSelectMode = true'.allMatches(menu).length, 1);
      expect('targets: [c as FavoriteItem]'.allMatches(menu).length, 2);
    });

    test('收藏页：favoriteOption 支持显式指定目标书', () {
      var src = read('lib/pages/favorites/local_favorites_page.dart');
      expect(
        src.contains('void favoriteOption(String option, {List<FavoriteItem>? targets})'),
        isTrue,
      );
      expect(src.contains('targets ??'), isTrue);
      // 单本路径没进过多选，不该顺手把多选态关掉
      expect(src.contains('if (targets == null) {'), isTrue);
    });
  });
}
