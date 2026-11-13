import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

/// 下拉菜单必须是磨砂玻璃，不能是 Material 那块写死的白板。
///
/// `showMenu` 的 `color` 在两处被写死成 `0xFFF6F6F6`：浅色下就是纯白，
/// 压在瀑布流上尤其突兀（分类页「全部 / 完结」那几个下拉最显眼）。
String read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  group('下拉菜单是玻璃的', () {
    test('Select 不再用 Material 的 showMenu', () {
      var src = read('lib/components/select.dart');
      expect(src.contains('showMenu('), isFalse, reason: 'showMenu 的底色改不动');
      expect(src.contains('0xFFF6F6F6'), isFalse, reason: '写死的白板底色');
      expect(src.contains('showGlassMenu<int>('), isTrue);
    });

    test('设置页的下拉也接同一套浮层', () {
      var src = read('lib/pages/settings/setting_components.dart');
      expect(src.contains('0xFFF6F6F6'), isFalse);
      expect(src.contains('showGlassMenu<String>('), isTrue);
    });

    test('浮层用与抽屉同档的磨砂参数', () {
      var src = read('lib/components/glass_menu.dart');
      expect(src.contains('blur: 44'), isTrue, reason: '不给 blur 会退回 26，磨砂不够');
      expect(src.contains('quality: lg.GlassQuality.standard'), isTrue);
      // 菜单压暗背景会把玻璃采成一块灰板，所以遮罩必须是透明的。
      expect(src.contains('barrierColor: Colors.transparent'), isTrue);
      expect(src.contains('showGeneralDialog<T>'), isTrue);
    });

    test('菜单不会被排到屏幕外', () {
      var src = read('lib/components/glass_menu.dart');
      // 下方放不下要翻到上方，两边都不够才贴边。
      expect(src.contains('anchor.top - height - 2'), isTrue);
      expect(src.contains('screen.height - padding.bottom - 8'), isTrue);
      // 选项多的时候（题材列表常常几十个）要能滚。
      expect(src.contains('ListView.builder('), isTrue);
    });
  });

  group('浮层能真的弹出来', () {
    testWidgets('点开下拉、选中一项、回调拿到下标', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      int? picked;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          ),
          home: Scaffold(
            body: Center(
              child: Select(
                current: 'All',
                values: const ['All', 'Finished', 'Updating'],
                onTap: (index) => picked = index,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();

      expect(find.byType(LiquidGlassPanel), findsWidgets);
      expect(find.text('Finished'), findsWidgets);

      await tester.tap(find.text('Finished').last);
      await tester.pumpAndSettle();

      expect(picked, 1);
      // 选完菜单必须收掉，不能留在屏幕上。
      expect(find.byType(LiquidGlassPanel), findsNothing);
    });
  });
}
