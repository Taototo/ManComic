import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/local_insights.dart';

/// 更新角标最容易出的两种错：
///
/// - 本地没有章节表时，整本被算成「新增」；
/// - 源换了章节 id（时间戳/随机串），每次刷新都报有更新。
///
/// 这两个函数就是拿来守这两条的。
void main() {
  group('countNewChapters', () {
    test('网源没给章节表时不算更新', () {
      final local = ComicChapters({"a": "第1话"});
      expect(countNewChapters(local, null), 0);
    });

    test('本地没有章节表时不算更新', () {
      // 单话下载、手工导入的漫画都属于这种：没有基准，比较没有意义。
      final current = ComicChapters({"a": "第1话", "b": "第2话"});
      expect(countNewChapters(null, current), 0);
      expect(countNewChapters(ComicChapters({}), current), 0);
    });

    test('多出来的章节按条数算', () {
      final local = ComicChapters({"a": "第1话", "b": "第2话"});
      final current = ComicChapters({
        "a": "第1话",
        "b": "第2话",
        "c": "第3话",
        "d": "第4话",
      });
      expect(countNewChapters(local, current), 2);
    });

    test('章节完全一致时不算更新', () {
      final local = ComicChapters({"a": "第1话", "b": "第2话"});
      final current = ComicChapters({"a": "第1话", "b": "第2话"});
      expect(countNewChapters(local, current), 0);
    });

    test('源换了章节 id 但标题没变时不算更新', () {
      final local = ComicChapters({"1680000000": "第1话", "1680000001": "第2话"});
      final current = ComicChapters({
        "1689999999": "第1话",
        "1689999998": "第2话",
      });
      expect(countNewChapters(local, current), 0);
    });

    test('id 换了同时真有一话新的，只算那一话', () {
      final local = ComicChapters({"1680000000": "第1话"});
      final current = ComicChapters({
        "1689999999": "第1话",
        "1689999998": "第2话",
      });
      expect(countNewChapters(local, current), 1);
    });

    test('分组章节也能比对', () {
      final local = ComicChapters.grouped({
        "第一卷": {"a": "第1话"},
      });
      final current = ComicChapters.grouped({
        "第一卷": {"a": "第1话"},
        "第二卷": {"b": "第2话", "c": "第3话"},
      });
      expect(countNewChapters(local, current), 2);
    });
  });

  group('chapterTitleOf', () {
    test('平铺章节按序号取标题', () {
      final chapters = ComicChapters({"a": "第1话", "b": "第2话"});
      expect(LocalInsights.chapterTitleOf(chapters, 2, null), "第2话");
    });

    test('越界时夹到最后一话，不抛异常', () {
      final chapters = ComicChapters({"a": "第1话", "b": "第2话"});
      expect(LocalInsights.chapterTitleOf(chapters, 99, null), "第2话");
    });

    test('分组章节用组内序号 + 组号', () {
      final chapters = ComicChapters.grouped({
        "第一卷": {"a": "第1话"},
        "第二卷": {"b": "第2话", "c": "第3话"},
      });
      expect(LocalInsights.chapterTitleOf(chapters, 2, 2), "第3话");
      expect(LocalInsights.chapterTitleOf(chapters, 1, 2), "第2话");
    });

    test('没有章节表返回 null', () {
      expect(LocalInsights.chapterTitleOf(null, 1, null), isNull);
    });

    test('组号越界时夹到有效组', () {
      final chapters = ComicChapters.grouped({
        "第一卷": {"a": "第1话"},
        "第二卷": {"b": "第2话"},
      });
      expect(LocalInsights.chapterTitleOf(chapters, 1, 9), "第2话");
    });
  });

  group('formatLocalSize', () {
    test('按量级换单位', () {
      expect(formatLocalSize(512), "512 B");
      expect(formatLocalSize(2048), "2 KB");
      expect(formatLocalSize(1024 * 1024 * 3), "3.0 MB");
      expect(formatLocalSize(1024 * 1024 * 1024 * 2), "2.00 GB");
    });

    test('零字节不会崩', () {
      expect(formatLocalSize(0), "0 B");
    });
  });

  group('ReadProgressInfo', () {
    test('没读过时 started 为 false', () {
      const info = ReadProgressInfo(ep: 1, page: 1);
      expect(info.started, isFalse);
      expect(info.fraction, 0);
    });

    test('读了第二话就算开始', () {
      const info = ReadProgressInfo(ep: 2, page: 1);
      expect(info.started, isTrue);
    });

    test('进度按已读章节数算，且不会超过 1', () {
      const info = ReadProgressInfo(
        ep: 1,
        page: 3,
        readChapters: 4,
        totalChapters: 10,
      );
      expect(info.fraction, closeTo(0.4, 1e-9));

      const overflow = ReadProgressInfo(
        ep: 1,
        page: 1,
        readChapters: 99,
        totalChapters: 10,
      );
      expect(overflow.fraction, 1.0);
    });

    test('没有章节表时按有没有开始读给个粗略值', () {
      const empty = ReadProgressInfo(ep: 1, page: 1);
      expect(empty.fraction, 0);
      const started = ReadProgressInfo(ep: 1, page: 5);
      expect(started.fraction, 1);
    });
  });
}
