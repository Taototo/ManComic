import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/chapter_search.dart';

void main() {
  group('parseChapterNumber', () {
    test('纯数字直接认', () {
      expect(parseChapterNumber('380'), 380);
      expect(parseChapterNumber('  7 '), 7);
    });

    test('带中文装饰词', () {
      expect(parseChapterNumber('第380话'), 380);
      expect(parseChapterNumber('第 12 章'), 12);
      expect(parseChapterNumber('第9回'), 9);
    });

    test('带英文前缀', () {
      expect(parseChapterNumber('ch.380'), 380);
      expect(parseChapterNumber('Ch 380'), 380);
      expect(parseChapterNumber('chapter380'), 380);
      expect(parseChapterNumber('EP.7'), 7);
    });

    test('多个数字取最后一个', () {
      // 「第10卷 第380话」要的是 380，不是卷号 10
      expect(parseChapterNumber('第10卷 第380话'), 380);
    });

    test('带别的字就不当章号', () {
      // 「番外篇 2」不是第 2 话，交给标题匹配处理
      expect(parseChapterNumber('番外篇 2'), isNull);
      expect(parseChapterNumber('第380话 后记'), isNull);
    });

    test('没有数字或空串返回 null', () {
      expect(parseChapterNumber(''), isNull);
      expect(parseChapterNumber('   '), isNull);
      expect(parseChapterNumber('序章'), isNull);
    });
  });

  group('searchChapters', () {
    final titles = [
      '第1话 开始',
      '第2话 相遇',
      '第10话 转折',
      '第380话 终章',
      '番外篇 2',
    ];

    test('空查询返回全部下标', () {
      expect(searchChapters(titles, ''), [0, 1, 2, 3, 4]);
      expect(searchChapters(titles, '   '), [0, 1, 2, 3, 4]);
    });

    test('章号命中排在最前', () {
      // 输入 380：第 380 话（下标 3）应排第一
      final result = searchChapters(titles, '380');
      expect(result.first, 3);
    });

    test('章号命中不会重复出现', () {
      // 「第2话」同时被章号 2 和标题「2」命中，只应出现一次
      final result = searchChapters(titles, '2');
      final count = result.where((i) => i == 1).length;
      expect(count, 1);
    });

    test('超出范围的章号不当章号用', () {
      // 只有 5 章，输入 999 不该命中任何下标
      expect(searchChapters(titles, '999'), isEmpty);
    });

    test('按标题模糊匹配，忽略大小写', () {
      final list = ['Chapter One', 'chapter two', 'Final'];
      expect(searchChapters(list, 'chapter'), [0, 1]);
      expect(searchChapters(list, 'FINAL'), [2]);
    });

    test('无匹配返回空', () {
      expect(searchChapters(titles, '不存在的章节'), isEmpty);
    });
  });
}
