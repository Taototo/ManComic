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

    test('从「本地」删除：下载书只清文件，导入书连库记录一起删', () {
      var src = read('lib/pages/favorites/local_favorites_page.dart');
      expect(src.contains('batchDeleteComics(downloaded, true, false)'), isTrue);
      expect(src.contains('batchDeleteComics(imported)'), isTrue);
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

    test('「本地」列表走轻量查询，不解析整本章节 JSON', () {
      var src = read('lib/foundation/local.dart');
      expect(src.contains('LocalComic.fromSummaryRow(Row row)'), isTrue);
      expect(src.contains('List<LocalComic> getComicSummaries('), isTrue);
      // 摘要对象没有章节表：它只服务列表展示，阅读/详情必须另走 find
      expect(src.contains('chapters = null,'), isTrue);
      expect(src.contains('downloadedChapters = const [],'), isTrue);
      // 只 select 展示列，不能回退成 SELECT *
      var start = src.indexOf('List<LocalComic> getComicSummaries(');
      var end = src.indexOf('LocalComic? find(', start);
      expect(end, greaterThan(start));
      var body = src.substring(start, end);
      expect(body.contains('SELECT *'), isFalse);
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
}
