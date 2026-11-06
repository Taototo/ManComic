import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/source_health.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/utils/translations.dart';

/// 造一个只带基础信息的源。除了 name/key/version 之外全部为 null，
/// 这样 searchPageData 为空，健康服务不会真的发网络请求。
ComicSource _fakeSource(
  String name,
  String key, {
  String version = '1.0.0',
  bool logged = false,
}) {
  final source = ComicSource(
    name,
    key,
    null,
    null,
    null,
    null,
    const [],
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    '/tmp/$key.js',
    'https://example.com/$key.js',
    version,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    null,
    false,
    false,
    null,
    null,
  );
  if (logged) {
    source.data['account'] = 'ok';
  }
  return source;
}

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
        theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
        home: child,
      );

  testWidgets('每个源一张卡，卡片上显示版本和健康分', (tester) async {
    final sources = [
      _fakeSource('拷贝漫画', 'copymanga'),
      _fakeSource('哔咔漫画', 'picacg', version: '2.3.1', logged: true),
      _fakeSource(
        'A very long comic source name that should be ellipsized',
        'long',
      ),
    ];
    for (final source in sources) {
      ComicSourceManager().add(source);
    }
    final service = SourceHealthService.instance;
    // 320ms / 20 条 → 满分，顺带验证三位数在环里放得下
    service.of(sources[0])
      ..status = SourceHealthStatus.ok
      ..latency = 320
      ..count = 20
      ..checkedAt = DateTime.now();
    service.of(sources[1])
      ..status = SourceHealthStatus.error
      ..latency = 8100
      ..message = 'Connection timed out while contacting the upstream host'
      ..checkedAt = DateTime.now();

    await tester.binding.setSurfaceSize(const Size(360, 760));
    await tester.pumpWidget(wrap(const ComicSourcePage()));
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.text('拷贝漫画'), findsOneWidget);
    expect(find.text('哔咔漫画'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
    expect(find.text('10'), findsOneWidget);
    // 没测过的源显示占位符，而不是 0 分
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('点击卡片打开详情面板，且没有溢出', (tester) async {
    final source = _fakeSource('拷贝漫画', 'copymanga');
    ComicSourceManager().add(source);
    SourceHealthService.instance.of(source)
      ..status = SourceHealthStatus.ok
      ..latency = 320
      ..count = 20
      ..checkedAt = DateTime.now();

    await tester.binding.setSurfaceSize(const Size(360, 760));
    await tester.pumpWidget(wrap(const ComicSourcePage()));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.text('拷贝漫画'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 没有新版本时按钮是「重新安装」
    expect(find.text('Reinstall'.tl), findsOneWidget);
    expect(find.text('Edit'.tl), findsOneWidget);
    expect(find.text('Delete'.tl), findsOneWidget);
    // 这个假源既没有设置项也没有账号，不该留下一个空的「设置」标题
    expect(find.text('Settings'.tl), findsNothing);
  });
}
