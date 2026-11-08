import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/utils/translations.dart';

/// 顶栏的「附加行」。
///
/// 推荐页的源页签原来是自己压在页面顶部的一层独立磨砂条：参数和顶栏那块
/// 玻璃不一样、中间还各有一条边缘高光，看着就是两条各管各的带子。现在
/// 它挂在顶栏里去，和标题共用同一块玻璃——这几个断言守的就是「同一块」：
/// 附加行必须在标题行下面，而且顶栏的总高度要把这一行算进去。
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  const statusBar = 24.0;

  Widget wrap({required Widget? Function(int, BuildContext) headerBuilder}) {
    final key = GlobalKey<NavigatorState>();
    return MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(
          padding: EdgeInsets.only(top: statusBar),
          viewPadding: EdgeInsets.only(top: statusBar),
        ),
        child: NaviPane(
          observer: NaviObserver(),
          navigatorKey: key,
          headerBuilder: headerBuilder,
          headerHeight: (_) => 48,
          paneItems: [
            PaneItemEntry(
              label: 'Explore',
              icon: Icons.explore_outlined,
              activeIcon: Icons.explore,
            ),
            PaneItemEntry(
              label: 'Home',
              icon: Icons.home_outlined,
              activeIcon: Icons.home,
            ),
          ],
          paneActions: const [],
          pageBuilder: (i) => const SizedBox.expand(),
        ),
      ),
    );
  }

  Future<void> pumpPhone(WidgetTester tester, Widget widget) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(widget);
    // 宽度切换动画面板要跑完，否则顶栏会按侧栏模式收起
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('附加行落在标题行下方，且算进顶栏高度', (tester) async {
    await pumpPhone(
      tester,
      wrap(
        headerBuilder: (page, context) => const Text("HEADER"),
      ),
    );

    expect(find.text("HEADER"), findsOneWidget);
    final headerTop = tester.getTopLeft(find.text("HEADER")).dy;
    expect(
      headerTop,
      greaterThanOrEqualTo(statusBar + 48 - 1),
      reason: "附加行钻进标题行里了：它必须排在 48 高的标题行之后",
    );

    final barHeight = tester.getSize(find.byType(LiquidGlassBar).first).height;
    expect(
      barHeight,
      closeTo(statusBar + 48 + 48, 0.5),
      reason: "顶栏玻璃没把附加行包进来，页签栏又会自己压一层磨砂",
    );
  });

  testWidgets('没有附加行时顶栏保持原高度', (tester) async {
    await pumpPhone(
      tester,
      wrap(headerBuilder: (page, context) => null),
    );
    final barHeight = tester.getSize(find.byType(LiquidGlassBar).first).height;
    expect(barHeight, closeTo(statusBar + 48, 0.5));
  });
}
