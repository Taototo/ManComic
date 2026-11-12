import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_gaps.dart';
import 'package:venera/foundation/local.dart' show pageIndexOfFileName;

/// 体检这套东西最容易错在两个方向：把「不知道」当成「不缺」（缺页永远补不
/// 回来），或者把已经完整的也列进来（用户被拉去重下一整本）。这里锁住分类
/// 规则，另外用源码守卫看住「体检不改记录」和「补下载按指定章节下」。
/// Windows 上 git 按 autocrlf 把源码换成 CRLF，而断言里写的是 `\n`。
String read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  group('缺失章节分类', () {
    test('一页都没有（或者目录不在）算缺失', () {
      var gaps = ComicGapScanner.classifyGaps(
        ids: const ['a', 'b', 'c'],
        titles: const ['1', '2', '3'],
        localPages: const {'b': 4},
        expectedPages: const {},
      );
      expect(gaps.map((e) => e.id), ['a', 'c']);
      expect(
        gaps.every((e) => e.kind == ChapterGapKind.missing),
        isTrue,
        reason: '目录不在 / 0 页都是没下过',
      );
    });

    test('本地比源站少才算不完整，并给出差几页', () {
      var gaps = ComicGapScanner.classifyGaps(
        ids: const ['a', 'b'],
        titles: const ['1', '2'],
        localPages: const {'a': 5, 'b': 9},
        expectedPages: const {0: 10},
      );
      expect(gaps.length, 1);
      expect(gaps.single.id, 'a');
      expect(gaps.single.kind, ChapterGapKind.incomplete);
      expect(gaps.single.localPages, 5);
      expect(gaps.single.expectedPages, 10);
      expect(gaps.single.missingPages, 5);
    });

    test('页数够或超过源站都不进清单', () {
      expect(
        ComicGapScanner.classifyGaps(
          ids: const ['a'],
          titles: const ['1'],
          localPages: const {'a': 7},
          expectedPages: const {0: 7},
        ),
        isEmpty,
      );
      expect(
        ComicGapScanner.classifyGaps(
          ids: const ['a'],
          titles: const ['1'],
          localPages: const {'a': 8},
          expectedPages: const {0: 7},
        ),
        isEmpty,
        reason: '多出来的页（源站删过页）不该让人再下一遍',
      );
    });

    test('没核对上的章节不能当成不缺', () {
      var gaps = ComicGapScanner.classifyGaps(
        ids: const ['a'],
        titles: const ['1'],
        localPages: const {'a': 5},
        expectedPages: const {},
      );
      // 不进 gaps（不知道缺不缺，不能凭空说缺），但调用方必须把「没核对」
      // 的数量报给用户 —— 见下一组对 unverified 的守卫。
      expect(gaps, isEmpty);
    });

    test('保持目录顺序', () {
      var gaps = ComicGapScanner.classifyGaps(
        ids: const ['a', 'b', 'c'],
        titles: const ['1', '2', '3'],
        localPages: const {'a': 2, 'c': 1},
        expectedPages: const {0: 9},
      );
      expect(gaps.map((e) => e.id), ['a', 'b']);
    });

    test('页码断了也算缺，不必问源站', () {
      var gaps = ComicGapScanner.classifyGaps(
        ids: const ['a', 'b'],
        titles: const ['1', '2'],
        localPages: const {'a': 28, 'b': 30},
        expectedPages: const {},
        slots: const {'a': 30},
      );
      expect(gaps.single.id, 'a');
      expect(gaps.single.kind, ChapterGapKind.incomplete);
      expect(gaps.single.holes, isTrue);
      expect(
        gaps.single.expectedPages,
        0,
        reason: '没问源站就不知道总数，不能瞎编一个',
      );
    });

    test('页码从 1 起不算断号', () {
      expect(
        ComicGapScanner.hasPageHole(pages: 30, slots: 31, first: 1),
        isFalse,
        reason: '老版本/手工导入按 1 起编号，不能把整本判成缺页',
      );
      expect(ComicGapScanner.hasPageHole(pages: 29, slots: 30, first: 0), isTrue);
      expect(
        ComicGapScanner.hasPageHole(pages: 30, slots: 30, first: 0),
        isFalse,
      );
    });
  });

  group('扫描要快', () {
    test('记录里已确认过的章节不再问源站', () {
      var src = read('lib/foundation/comic_gaps.dart');
      expect(
        src.contains('verifyRecorded || !loaded.contains(ids[i])'),
        isTrue,
        reason: '一话一个请求，八百话的书就是八百个请求——只查有疑问的',
      );
    });

    test('一页没有、页码断了的章节也都不问源站', () {
      var src = read('lib/foundation/comic_gaps.dart');
      expect(src.contains('(counts[ids[i]] ?? 0) > 0'), isTrue);
      expect(src.contains('!holes.containsKey(ids[i])'), isTrue);
    });

    test('进度分两遍报，各自的分母', () {
      var src = read('lib/foundation/comic_gaps.dart');
      expect(
        src.contains('onProgress?.call(i + 1, ids.length, false)'),
        isTrue,
      );
      expect(
        src.contains('onProgress?.call(checked, suspects.length, true)'),
        isTrue,
        reason: '分母写成 ids.length 时进度条永远停在半路，看着像卡死',
      );
    });

    test('源站连续问不到就中止', () {
      var src = read('lib/foundation/comic_gaps.dart');
      expect(src.contains('maxConsecutiveFailures'), isTrue);
      expect(src.contains('aborted = true'), isTrue);
      expect(
        read('lib/pages/missing_chapters_page.dart')
            .contains('LinearProgressIndicator'),
        isTrue,
      );
    });
  });

  group('页码解析', () {
    test('下载按 0 起编号，封面和 json 不算页', () {
      expect(pageIndexOfFileName('0.jpg'), 0);
      expect(pageIndexOfFileName('12.webp'), 12);
      expect(pageIndexOfFileName('cover.webp'), isNull);
      expect(pageIndexOfFileName('details.json'), isNull);
      expect(pageIndexOfFileName('.nomedia'), isNull);
      expect(pageIndexOfFileName('page1.jpg'), isNull);
    });

    test('正文页判定只有一份实现', () {
      var src = read('lib/foundation/local.dart');
      expect(
        src.contains(
          'bool isPageFileName(String name) => pageIndexOfFileName(name) != null;',
        ),
        isTrue,
      );
    });
  });

  group('体检不该有副作用', () {
    test('数页只读盘，不摘「已下载」记录', () {
      var src = read('lib/foundation/local.dart');
      var start = src.indexOf('Future<int> countChapterPages');
      expect(start, greaterThan(0));
      var body = src.substring(
        start,
        src.indexOf('  /// 把「记录里有、磁盘上没有」', start),
      );
      expect(
        body.contains('_forgetMissingChapter'),
        isFalse,
        reason: '扫一遍全书会连带把记录改掉、界面一直重建',
      );
      expect(body.contains('_listPageFiles'), isTrue);
    });

    test('核对失败要计数，不能当成不缺', () {
      var src = read('lib/foundation/comic_gaps.dart');
      expect(src.contains('unverified++'), isTrue);
      // 结果面板必须把「没核对上」的章数说出来，否则用户会以为整本都齐了
      expect(
        read('lib/pages/missing_chapters_page.dart')
            .contains('report.unverified > 0'),
        isTrue,
      );
    });
  });

  group('补下载', () {
    test('按指定章节下载，不再被详情目录过滤掉', () {
      var src = read('lib/network/download.dart');
      expect(
        src.contains('pending.addAll(chapters!.where((e) => e.isNotEmpty));'),
        isTrue,
      );
      expect(
        src.contains('if (chapters != null && !chapters!.contains(i))'),
        isFalse,
        reason: '补的那一话可能正是快照里没有的新章',
      );
    });

    test('沿用已有封面，避免删旧文件后记录指向空', () {
      var src = read('lib/network/download.dart');
      expect(src.contains('Failed to reuse existing cover'), isTrue);
      expect(src.contains('existing.cover.isNotEmpty'), isTrue);
    });

    test('重新入库不改「加入时间」', () {
      var src = read('lib/foundation/local.dart');
      expect(
        src.contains('(old?.createdAt ?? comic.createdAt)'),
        isTrue,
        reason: '补下载后书不该跳到「最近加入」第一位',
      );
    });

    test('本地详情页有入口，导入的漫画不显示', () {
      var src = read('lib/pages/local_comic_page.dart');
      expect(src.contains('"Check missing chapters".tl'), isTrue);
      expect(src.contains('MissingChaptersPage.show(context, comic)'), isTrue);
      expect(
        src.contains('widget.comicType.comicSource?.loadComicPages != null'),
        isTrue,
        reason: '手工导入的书没有源站可以比页数',
      );
    });

    test('队列里已经有这本时不能假装开始下载', () {
      var src = read('lib/pages/missing_chapters_page.dart');
      expect(
        src.contains('LocalManager().findTask(widget.comic.id, widget.comic.comicType)'),
        isTrue,
      );
      expect(src.contains('Already in the download queue'), isTrue);
    });
  });
}
