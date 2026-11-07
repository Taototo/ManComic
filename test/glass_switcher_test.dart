import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/utils/translations.dart';

/// 「推荐 / 分类」分段控件搬到顶栏标题位之后，宽度必须保持页内那版的大小。
///
/// `GlassSegmentedControl` 在水平模式下**不吃 `segmentExtent`**（那个参数只
/// 对竖排生效），宽度完全由文字撑开。搬进顶栏后整块缩成一小坨，比原来窄了
/// 一大截——只能靠外层给死宽度把每段均分回来。
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  Widget wrap(Widget child) {
    return MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: Scaffold(
        body: Center(child: child),
      ),
    );
  }

  testWidgets('分段控件的宽度沿用页内版（158）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    await tester.pumpWidget(
      wrap(
        GlassGroupSwitcher(
          index: 0,
          labels: const ["Explore", "Categories"],
          onChanged: (_) {},
        ),
      ),
    );
    await tester.pump();

    final size = tester.getSize(find.byType(GlassGroupSwitcher));
    // 76 × 2 段 + 3 × 2 内边距
    expect(size.width, 158);
    expect(size.height, 30);
    expect(tester.takeException(), isNull);
  });

  testWidgets('源页签的玻璃滑块能渲染', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    await tester.pumpWidget(
      wrap(
        DefaultTabController(
          length: 3,
          child: AppTabBar(
            glass: true,
            tabs: const [
              Tab(text: "Source A"),
              Tab(text: "Source B"),
              Tab(text: "Source C"),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 玻璃滑块是叠在页签行上的，页签文字必须还在
    expect(find.text("Source B"), findsOneWidget);
  });
}
