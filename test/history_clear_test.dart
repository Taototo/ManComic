import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 「清除历史」必须只清列表，不能把读到哪一话哪一页、哪些话读过一起删掉。
///
/// 这张表同时是进度表和列表，而清列表是日常操作、清进度是不可逆的破坏性
/// 操作，两件事混在一起时用户点一下「清除历史」就把进度丢了。这里锁住：
/// 清列表只改 `cleared`，只有明确选择「连进度一起清」才 `delete`。
String read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  group('清除历史只清列表', () {
    test('clearHistory 默认只标记，不删行', () {
      var src = read('lib/foundation/history.dart');
      var start = src.indexOf('void clearHistory(');
      expect(start, greaterThan(0));
      var body = src.substring(start, src.indexOf('\n  }', start));
      expect(body.contains('withProgress = false'), isTrue);
      var ifPart = body.substring(
        body.indexOf('if (withProgress) {'),
        body.indexOf('} else {'),
      );
      var elsePart = body.substring(body.indexOf('} else {'));
      expect(ifPart.contains('delete from history'), isTrue);
      expect(
        elsePart.contains('update history set cleared = 1'),
        isTrue,
        reason: '默认分支必须是「标记」，删行只能在 withProgress 里',
      );
    });

    test('列表、最近阅读、计数都过滤掉已清除的', () {
      var src = read('lib/foundation/history.dart');
      var visible = RegExp(
        r'const _visible = "coalesce\(cleared, 0\) = 0"',
      );
      expect(visible.hasMatch(src), isTrue);
      for (var name in ['List<History> getAll()', 'List<History> getRecent()', 'int count()']) {
        var start = src.indexOf(name);
        expect(start, greaterThan(0), reason: '找不到 $name');
        var body = src.substring(start, src.indexOf('\n  }', start));
        expect(body.contains('_visible'), isTrue, reason: '$name 没过滤 cleared');
      }
    });

    test('find 不能过滤 cleared，否则进度就跟着列表一起消失', () {
      var src = read('lib/foundation/history.dart');
      var start = src.indexOf('History? find(');
      expect(start, greaterThan(0));
      var body = src.substring(start, src.indexOf('\n  }', start));
      expect(body.contains('_visible'), isFalse);
      expect(body.contains('select * from history'), isTrue);
    });

    test('再次阅读要把 cleared 归零，书才会回到列表', () {
      var src = read('lib/foundation/history.dart');
      expect(src.contains('chapter_group, cleared)'), isTrue);
      expect(src.contains('values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)'), isTrue);
    });

    test('老库要补 cleared 列', () {
      var src = read('lib/foundation/history.dart');
      expect(
        src.contains('alter table history add column cleared int default 0;'),
        isTrue,
      );
      expect(src.contains('element["name"] == "cleared"'), isTrue);
    });
  });

  group('删一条 ≠ 清进度', () {
    test('历史页单条删除用 hide，多选批量用 hideAll', () {
      var src = read('lib/pages/history_page.dart');
      expect(src.contains('HistoryManager().hide(comic.id, _typeOf(comic));'), isTrue);
      expect(src.contains('HistoryManager().hideAll('), isTrue);
      expect(
        src.contains('HistoryManager().remove('),
        isFalse,
        reason: 'remove 是真删，进度会一起没',
      );
    });

    test('「清除阅读进度」走 forget 并二次确认', () {
      var src = read('lib/pages/history_page.dart');
      expect(src.contains('HistoryManager().forget(comic.id, _typeOf(comic));'), isTrue);
      expect(src.contains('showConfirmDialog('), isTrue);
      expect(src.contains('"Clear Progress".tl'), isTrue);
    });

    test('删漫画才真删历史（书都不在了，留进度会跳到半路）', () {
      var src = read('lib/foundation/local.dart');
      expect(src.contains('HistoryManager().remove(c.id, c.comicType);'), isTrue);
      expect(src.contains('HistoryManager().batchDeleteHistories(comicIDs);'), isTrue);
    });

    test('界面把「只清列表」说清楚，并留了清进度的入口', () {
      var src = read('lib/pages/history_page.dart');
      expect(
        src.contains('History only records what you opened.'),
        isTrue,
        reason: '不写清楚，用户下一次还是会以为进度被清了',
      );
      expect(src.contains('"Clear progress too".tl'), isTrue);
      expect(src.contains('_clearWithProgress'), isTrue);
    });
  });
}
