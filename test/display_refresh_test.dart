import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/fps_overlay.dart';
import 'package:venera/foundation/display_refresh.dart';

void main() {
  group('刷新率档位', () {
    test('auto 表示跟随屏幕最高，不写死数值', () {
      expect(DisplayRefresh.targetFor('auto'), isNull);
    });

    test('数字档位换算成帧率', () {
      expect(DisplayRefresh.targetFor('60'), 60.0);
      expect(DisplayRefresh.targetFor('90'), 90.0);
      expect(DisplayRefresh.targetFor('120'), 120.0);
    });

    test('非法值退回自动，不至于把屏幕钉在一个奇怪的帧率上', () {
      expect(DisplayRefresh.targetFor(''), isNull);
      expect(DisplayRefresh.targetFor('fast'), isNull);
    });

    test('设置里给出的档位都是可解析的', () {
      for (final mode in DisplayRefresh.modes) {
        if (mode == 'auto') continue;
        expect(DisplayRefresh.targetFor(mode), isNotNull, reason: mode);
      }
    });
  });

  group('帧率叠加层', () {
    testWidgets('没有帧数据时不显示读数，也不挡交互', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: FpsOverlay(child: SizedBox.expand()),
        ),
      );
      // 刚挂载时窗口里还没有帧统计，读数应当留空。
      expect(find.textContaining('fps'), findsNothing);
      expect(find.byType(IgnorePointer), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('卸载后计时器停止，不留下未取消的 Timer', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: FpsOverlay(child: SizedBox.expand()),
        ),
      );
      await tester.pumpWidget(const SizedBox());
      // 若 Timer 没取消，pump 会报 "A Timer is still pending"。
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
