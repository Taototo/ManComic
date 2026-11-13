import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/utils/translations.dart';

/// 「抽一本」的玻璃必须在**弹窗底板**上，不能做到卡片上。
///
/// 踩过的坑：Dialog 的底板是一块不透明的 surface，把半透明玻璃放在里面的
/// 小部件上，玻璃背后只有纯色，没有任何东西可以折射——调多少参数都只是
/// 一块发白的磨砂片。要透出背后的收藏页，必须让 Dialog 本身透明、由玻璃
/// 面板当背景层，同时把遮罩调淡，否则采到的永远是黑色。
String read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

String dialogSource() => read('lib/components/message.dart');

/// 取 `class ContentDialog` 到文件末尾的那一段，避免匹配到别的 Dialog。
String contentDialogBody() {
  var src = dialogSource();
  var start = src.indexOf('class ContentDialog');
  expect(start, greaterThan(0));
  return src.substring(start);
}

String randomPickSource() => read('lib/pages/random_pick_dialog.dart');

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  group('玻璃长在弹窗底板上', () {
    test('ContentDialog 提供 glass 开关，默认关闭', () {
      var body = contentDialogBody();
      expect(body.contains('this.glass = false'), isTrue);
      expect(body.contains('final bool glass;'), isTrue);
    });

    test('glass 模式下弹窗自身透明，不留实心底色', () {
      var body = contentDialogBody();
      expect(
        body.contains(
          'backgroundColor: glass ? Colors.transparent : context.colorScheme.surface',
        ),
        isTrue,
        reason: 'Dialog 必须透明，否则玻璃背后是一块纯色',
      );
      expect(
        body.contains('elevation: glass ? 0 : 2'),
        isTrue,
        reason: '玻璃自带阴影，Dialog 再抬 elevation 会叠两层投影',
      );
    });

    test('玻璃作为背景层垫在内容下，靠 Positioned.fill 避开固有尺寸测量', () {
      var body = contentDialogBody();
      // 玻璃内部是 LayoutBuilder / 着色器，IntrinsicWidth 去问它会抛异常，
      // 所以只能放在 Stack 的 Positioned.fill 里（positioned 子节点不参与
      // 固有尺寸计算）。
      expect(body.contains('Positioned.fill('), isTrue);
      expect(body.contains('LiquidGlassPanel('), isTrue);
      expect(
        body.contains('quality: lg.GlassQuality.standard'),
        isTrue,
        reason: '弹窗会被反复重挂载，premium 的 toImageSync 采不到背景',
      );
      var stackIndex = body.indexOf('Positioned.fill(');
      var panelIndex = body.indexOf('LiquidGlassPanel(');
      expect(stackIndex, lessThan(panelIndex));
    });

    test('抽一本用了玻璃底板', () {
      var src = randomPickSource();
      var start = src.indexOf('return ContentDialog(');
      expect(start, greaterThan(0));
      var body = src.substring(start, src.indexOf('content:', start));
      expect(body.contains('glass: true'), isTrue);
    });

    test('抽一本的遮罩必须调淡，否则玻璃采到的全是黑色', () {
      var src = randomPickSource();
      var start = src.indexOf('Future<FavoriteItem?> showRandomPickDialog');
      expect(start, greaterThan(0));
      var body = src.substring(start, src.indexOf('\n}', start));
      expect(body.contains('barrierColor:'), isTrue);
      expect(
        body.contains('Colors.black54'),
        isFalse,
        reason: '默认遮罩会把背后页面压成一片黑',
      );
      // 取值参考 iOS 26 原生弹窗：浅色约 0.21，深色约 0.47。
      expect(body.contains('0.22'), isTrue);
      expect(body.contains('0.42'), isTrue);
    });

    test('卡片本身是实体，不能又套一层玻璃', () {
      var src = randomPickSource();
      var start = src.indexOf('Widget _buildCardBack');
      expect(start, greaterThan(0));
      var body = src.substring(start, src.indexOf('\n  Widget _buildCardFront'));
      expect(
        body.contains('LiquidGlassPanel'),
        isFalse,
        reason: '两层玻璃叠加会盖掉底板的质感，看起来像磨砂塑料',
      );
      expect(body.contains('BoxDecoration('), isTrue);
    });

    testWidgets('玻璃弹窗能正常布局（固有尺寸测量不会炸）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          ),
          home: const Scaffold(
            body: Center(
              child: ContentDialog(
                title: 'Draw a comic',
                glass: true,
                content: SizedBox(height: 240, child: Text('content')),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // 玻璃内部是 LayoutBuilder + 着色器，一旦被 IntrinsicWidth 直接
      // 测量就会抛 "does not support returning intrinsic dimensions"。
      expect(tester.takeException(), isNull);
      expect(find.byType(LiquidGlassPanel), findsWidgets);
      final size = tester.getSize(find.byType(ContentDialog));
      expect(size.width, greaterThan(0));
      expect(size.height, greaterThan(0));
    });
  });
}
