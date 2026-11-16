import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/reading_report_page.dart';

/// 阅读报告页「最近 30 天读过的作品」是固定高度的滚动区。
///
/// 原来的列表是直接铺开的：读了三十本就是三十行，把下面的年度报告推到很
/// 远的地方。改成固定五行以后，高度算错了只表现为「多露半行」或者「少了
/// 一行」，跟别的问题混在一起很难看出来，所以这里按数字钉住。
String read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  group('最近 30 天列表的高度', () {
    test('一屏固定五行', () {
      expect(kRecentRows, 5);
      // 五行 + 四条分隔线
      expect(recentListHeight(5), 5 * 78 + 4 * 0.7);
      expect(recentListHeight(9), recentListHeight(5));
      expect(recentListHeight(30), recentListHeight(5));
    });

    test('不足五行按实际条数收缩，不留空白', () {
      expect(recentListHeight(1), 78);
      expect(recentListHeight(3), 3 * 78 + 2 * 0.7);
      expect(recentListHeight(0), 0);
    });

    test('高度随条数单调不减', () {
      var last = -1.0;
      for (var i = 0; i <= 8; i++) {
        final h = recentListHeight(i);
        expect(h, greaterThanOrEqualTo(last));
        last = h;
      }
    });
  });

  group('守卫', () {
    final src = read('lib/pages/reading_report_page.dart');

    test('超出五行时有常显滚动条', () {
      expect(src.contains('kRecentRows'), isTrue);
      expect(src.contains('thumbVisibility: true'), isTrue);
      // 滚动条不常显的话，列表自己在框里截断，用户不知道下面还有
      expect(src.contains('Scrollbar('), isTrue);
    });

    test('内层滚动自带 controller，不抢外层', () {
      expect(src.contains('_recentScroll = ScrollController()'), isTrue);
      expect(src.contains('controller: overflow ? _recentScroll : null'), isTrue);
      expect(src.contains('_recentScroll.dispose()'), isTrue);
    });

    test('行高的三个数字和行组件对得上', () {
      // _ComicStatRow 是 58 的封面 + 上下各 10 的留白，分隔线 0.7
      final row = src.substring(src.indexOf('class _ComicStatRow'));
      expect(row.contains('height: 58'), isTrue);
      expect(row.contains('EdgeInsets.fromLTRB(12, 10, 12, 10)'), isTrue);
      expect(row.contains('height: 0.7'), isTrue);
      expect(kRecentRowHeight, 58 + 10 + 10);
      expect(kRecentDividerHeight, 0.7);
    });
  });
}
