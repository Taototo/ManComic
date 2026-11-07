import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/utils/translations.dart';

/// 页内标题栏必须自己消费 `MediaQuery.padding.top`。
///
/// 1.4.33 加过一层「外层顶栏已经付过这段高度」的判断，把留白直接清零。
/// 结果是收藏页的标题栏连统一起来的分组菜单按钮整体钻到玻璃顶栏底下：
/// 它没被移出布局，只是被盖住且点不到，看起来就是「收藏分类没了」。
///
/// `MediaQuery.padding` 是建议值，不会自己挪动任何布局。主导航把页面铺满
/// 整个屏幕（顶栏盖在上面），页面只能靠标题栏自己把这 72 让出来。
void main() {
  // 状态栏 + 外层顶栏（48）。
  const topInset = 72.0;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  Widget wrap(Widget body) {
    return MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      ),
      home: MediaQuery(
        data: const MediaQueryData(
          padding: EdgeInsets.only(top: topInset),
          viewPadding: EdgeInsets.only(top: topInset),
        ),
        child: body,
      ),
    );
  }

  testWidgets('SliverAppbar 的标题落在顶栏下沿之下', (tester) async {
    await tester.pumpWidget(
      wrap(
        Scaffold(
          body: CustomScrollView(
            slivers: [
              SliverAppbar(title: const Text("分类")),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    final top = tester.getTopLeft(find.text("分类")).dy;
    expect(
      top,
      greaterThanOrEqualTo(topInset),
      reason: "标题栏内容被外层玻璃顶栏盖住了，点不到分类菜单",
    );
  });

  testWidgets('Appbar 的标题落在顶栏下沿之下', (tester) async {
    await tester.pumpWidget(
      wrap(
        Scaffold(
          appBar: Appbar(title: const Text("分类")),
        ),
      ),
    );
    await tester.pump();

    final top = tester.getTopLeft(find.text("分类")).dy;
    expect(
      top,
      greaterThanOrEqualTo(topInset),
      reason: "Appbar 把留白当成已付过，标题钻到玻璃下面",
    );
  });
}
