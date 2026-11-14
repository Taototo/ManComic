import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/utils/translations.dart';

/// 加载失败时的那条「后退 / 第 1 / ? 页 / 前进」。
///
/// 用户报的现象：源挂了、页面一片空白，顶上却压着两个能点的按钮，
/// 而且正好盖在状态栏的时间和信号图标上。
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  Widget wrap(Widget child) => MaterialApp(
    theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
    home: child,
  );

  testWidgets('翻页模式加载失败：不画翻页条，也不压状态栏', (tester) async {
    appdata.settings['comicListDisplayMode'] = 'paging';
    await tester.binding.setSurfaceSize(const Size(390, 800));
    await tester.pumpWidget(
      wrap(
        Scaffold(
          body: ComicList(
            loadPage: (page) async => const Res.error('boom'),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    // 一页都没成功，没有"前进"可去
    expect(find.text('Next'.tl), findsNothing);
    expect(find.text('Back'.tl), findsNothing);
    // 错误本身要能看到
    expect(find.textContaining('boom'), findsWidgets);
  });

  testWidgets('连读模式加载失败：同样不画翻页条', (tester) async {
    appdata.settings['comicListDisplayMode'] = 'continuous';
    await tester.binding.setSurfaceSize(const Size(390, 800));
    await tester.pumpWidget(
      wrap(
        Scaffold(
          body: ComicList(
            loadNext: (next) async => const Res.error('boom'),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.text('Next'.tl), findsNothing);
  });
}
