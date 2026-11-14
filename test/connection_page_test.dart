import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/connection_page.dart';
import 'package:venera/utils/translations.dart';

/// 「漫画源 / 内置代理」合集页。
///
/// 这两页原来分别是两颗顶栏按钮，合并之后最容易错的是「滑动能到、分段能点、
/// 并且两页都真的在」——任何一条断了，用户看到的就是一片空白还退不回去。
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  tearDown(() {
    for (final source in ComicSource.all()) {
      ComicSourceManager().remove(source.key);
    }
  });

  Widget wrap(Widget child) => MaterialApp(
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
    home: child,
  );

  testWidgets('分段控件带两页标签，默认停在漫画源', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    await tester.pumpWidget(wrap(const ConnectionPage()));
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    // 两个标签名都是分段控件里的，不依赖翻译结果
    expect(find.text('Comic Sources'.tl), findsOneWidget);
    expect(find.text('Built-in proxy'.tl), findsOneWidget);
    // 第一页是源列表：没有源时提示仍在该页
    expect(find.text('Built-in proxy'.tl).evaluate().length, 1);
  });

  testWidgets('点第二段切到内置代理页，能看到连接测试', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    await tester.pumpWidget(wrap(const ConnectionPage()));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('Built-in proxy'.tl));
    // 分段切换是 350ms 的动画，给够时间再断言
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.takeException(), isNull);
    expect(find.text('Test all'.tl), findsOneWidget);
    expect(find.text('Enable'.tl), findsOneWidget);
  });

  testWidgets('左滑能从漫画源切到内置代理', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    await tester.pumpWidget(wrap(const ConnectionPage()));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.drag(find.byType(TabBarView), const Offset(-350, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(tester.takeException(), isNull);
    expect(find.text('Test all'.tl), findsOneWidget);
  });

  testWidgets('嵌入模式下不再画自己的标题栏', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    await tester.pumpWidget(
      wrap(const Scaffold(body: ComicSourcePage(embedded: true))),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    // 独立页面时有 SliverAppbar 的标题；嵌进合集页后由合集页的顶栏负责。
    // 这一层如果没退掉，合集页顶栏下面就会再长出一个「Comic Source」。
    expect(find.text('Comic Source'.tl), findsNothing);
    expect(find.byType(Scaffold), findsOneWidget);
  });
}
