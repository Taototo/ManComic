import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

/// 液态主题的两条底线：
///
/// 1. **默认主题一个像素都不能变。** 它是「新增一个主题」，不是「改掉原来的
///    外观」。所以配色只在液态分支上做替换，[AppSurface] 在非液态时必须退回
///    到原来那块实心容器。
/// 2. **液态必须是真半透明。** 全站几十处容器直接读 `surfaceContainer*`，
///    靠改配色表一次性变成玻璃感。哪个角色被漏成不透明，那一块就会在彩色
///    底纹上破一个死洞——从界面上看像是渲染错误，很难回溯到配色表。
void main() {
  group('液态配色表', () {
    for (final brightness in Brightness.values) {
      test('$brightness：容器角色半透明，surface 保持不透明', () {
        final base = ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: brightness,
        );
        final liquid = liquidColorScheme(base);

        for (final entry in {
          'surfaceContainerLowest': liquid.surfaceContainerLowest,
          'surfaceContainerLow': liquid.surfaceContainerLow,
          'surfaceContainer': liquid.surfaceContainer,
          'surfaceContainerHigh': liquid.surfaceContainerHigh,
          'surfaceContainerHighest': liquid.surfaceContainerHighest,
        }.entries) {
          expect(
            entry.value.a,
            lessThan(1.0),
            reason: '${entry.key} 应该半透明，否则会挡住底纹',
          );
          // 太透会看不清上面的文字，也太容易透出底下滚动的内容。
          expect(entry.value.a, greaterThan(0.4), reason: '${entry.key} 太透了');
        }

        // surface 被贴边栏、遮罩、图片占位当不透明底用，透掉就会穿帮。
        expect(liquid.surface.a, 1.0);
      });
    }

    test('层次越高的容器越不透明，保留原来的浮起关系', () {
      final liquid = liquidColorScheme(
        ColorScheme.fromSeed(seedColor: Colors.teal),
      );
      final alphas = [
        liquid.surfaceContainerLowest.a,
        liquid.surfaceContainerLow.a,
        liquid.surfaceContainer.a,
        liquid.surfaceContainerHigh.a,
        liquid.surfaceContainerHighest.a,
      ];
      for (var i = 1; i < alphas.length; i++) {
        expect(
          alphas[i],
          greaterThan(alphas[i - 1]),
          reason: '第 $i 档比上一档还透明，浮起关系反了',
        );
      }
    });

    test('除了容器，其余角色原样保留', () {
      final base = ColorScheme.fromSeed(seedColor: Colors.orange);
      final liquid = liquidColorScheme(base);
      expect(liquid.primary, base.primary);
      expect(liquid.onSurface, base.onSurface);
      expect(liquid.error, base.error);
      expect(liquid.outlineVariant, base.outlineVariant);
    });
  });

  group('LiquidTheme 扩展', () {
    testWidgets('主题里没有这个扩展时按关闭处理', (tester) async {
      late bool result;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(),
          home: Builder(
            builder: (context) {
              result = LiquidTheme.isOn(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(result, isFalse);
    });

    testWidgets('液态主题下读到开启', (tester) async {
      late bool result;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: const [LiquidTheme.on]),
          home: Builder(
            builder: (context) {
              result = LiquidTheme.isOn(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(result, isTrue);
    });

    test('lerp 过半即切换，避免过渡期间半玻璃半实心', () {
      const off = LiquidTheme.off;
      const on = LiquidTheme.on;
      expect(off.lerp(on, 0.2).enabled, isFalse);
      expect(off.lerp(on, 0.5).enabled, isTrue);
      expect(on.lerp(off, 0.9).enabled, isFalse);
      expect(on.lerp(null, 0.9).enabled, isTrue);
    });
  });

  group('AppSurface', () {
    testWidgets('默认主题是实心容器，不用玻璃', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(),
          home: const Scaffold(
            body: AppSurface(child: Text('card')),
          ),
        ),
      );
      expect(find.byType(LiquidGlass), findsNothing);
      expect(find.text('card'), findsOneWidget);
    });

    testWidgets('液态主题换成玻璃材质', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: const [LiquidTheme.on]),
          home: const Scaffold(
            body: AppSurface(child: Text('card')),
          ),
        ),
      );
      expect(find.byType(LiquidGlass), findsOneWidget);
      expect(find.text('card'), findsOneWidget);
    });

    testWidgets('带点击的卡片能正常响应，水波纹不会画在玻璃下面', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(extensions: const [LiquidTheme.on]),
          home: Scaffold(
            body: AppSurface(
              onTap: () => tapped++,
              child: const SizedBox(width: 120, height: 60),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(AppSurface));
      await tester.pumpAndSettle();
      expect(tapped, 1);
    });

    testWidgets('外边距在外、内边距在内', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(),
          home: const Scaffold(
            body: AppSurface(
              margin: EdgeInsets.all(8),
              padding: EdgeInsets.all(12),
              child: SizedBox(width: 40, height: 40),
            ),
          ),
        ),
      );
      final surface = tester.getRect(find.byType(AppSurface));
      final inner = tester.getRect(find.byType(SizedBox).first);
      // 内边距加在表面里面，外边距包在外面。再算上 0.6 的细描边（Container
      // 会把描边宽度让进内容区）。
      expect(surface.width, closeTo(40 + 12 * 2 + 8 * 2 + 1.2, 0.01));
      expect(inner.width, 40);
      expect(inner.left - surface.left, closeTo(8 + 12 + 0.6, 0.01));
    });
  });

  group('按压回弹与玻璃按钮', () {
    ThemeData liquidTheme() => ThemeData(
          colorScheme: liquidColorScheme(
            ColorScheme.fromSeed(seedColor: Colors.indigo),
          ),
          extensions: const [LiquidTheme.on],
        );

    testWidgets('默认主题不接管任何手势，原样返回', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(),
          home: const Scaffold(
            body: LiquidPressable(child: SizedBox(width: 50, height: 50)),
          ),
        ),
      );
      // 默认主题下不该有 Listener，否则会和按钮自己的 InkWell 抢指针。
      expect(
        find.descendant(
          of: find.byType(LiquidPressable),
          matching: find.byType(Listener),
        ),
        findsNothing,
      );
    });

    testWidgets('液态下按下放大、松开回弹到原尺寸', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: liquidTheme(),
          home: const Scaffold(
            body: Center(
              child: LiquidPressable(
                scale: 1.1,
                child: SizedBox(width: 50, height: 50, key: ValueKey('box')),
              ),
            ),
          ),
        ),
      );
      double scaleOf() => tester
          .widget<AnimatedScale>(
            find.descendant(
              of: find.byType(LiquidPressable),
              matching: find.byType(AnimatedScale),
            ),
          )
          .scale;

      expect(scaleOf(), 1.0);

      final box = tester.getCenter(find.byKey(const ValueKey('box')));
      final gesture = await tester.startGesture(box);
      await tester.pump(const Duration(milliseconds: 150));
      expect(scaleOf(), 1.1, reason: '按住时应该胀开');

      await gesture.up();
      await tester.pumpAndSettle();
      expect(scaleOf(), 1.0, reason: '松手要弹回去');
    });

    testWidgets('玻璃按钮在默认主题下仍是实心主色', (tester) async {
      final colors = ColorScheme.fromSeed(seedColor: Colors.indigo);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(colorScheme: colors),
          home: Scaffold(
            body: Center(
              child: LiquidGlassButton(
                onPressed: () {},
                child: const Text('Read'),
              ),
            ),
          ),
        ),
      );
      final material = tester.widget<Material>(
        find.descendant(
          of: find.byType(LiquidGlassButton),
          matching: find.byType(Material),
        ).first,
      );
      expect(material.color, colors.primary);
      expect(find.byType(LiquidGlass), findsNothing);
    });

    testWidgets('玻璃按钮在液态下换成一整块玻璃', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: liquidTheme(),
          home: Scaffold(
            body: Center(
              child: LiquidGlassButton(
                onPressed: () {},
                child: const Text('Read'),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(LiquidGlass), findsOneWidget);
      expect(find.byType(LiquidPressable), findsOneWidget);
    });

    testWidgets('玻璃按钮点了会回调', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: liquidTheme(),
          home: Scaffold(
            body: Center(
              child: LiquidGlassButton(
                onPressed: () => taps++,
                child: const Text('Read'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(LiquidGlassButton));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });
  });
}
