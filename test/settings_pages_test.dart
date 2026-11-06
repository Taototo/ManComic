import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

/// 重构后的设置页渲染冒烟。
///
/// 分类合并时最容易犯的错是「把某一组忘了搬过去」——编译不会报错，页面也能
/// 打开，只是少了一整块设置。这里只保证页面能渲染、不溢出、不抛异常；
/// 「分组标题还在不在」由 setting_layout_test 静态检查兜住。
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppTranslation.init();
  });

  Widget wrap(Widget child) => MaterialApp(
        theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
        home: Scaffold(body: child),
      );

  // 只挑不依赖运行环境的页：Favorites / Data / Explore 一进 build 就要读
  // 收藏数据库、本地漫画路径和已加载的源，在 widget 测试里没有这些。
  for (final entry in {
    'app': const AppSettings(),
    'network': const NetworkSettings(),
    'about': const AboutSettings(),
  }.entries) {
    testWidgets('${entry.key} 页在窄屏可渲染', (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 900));
      await tester.pumpWidget(wrap(entry.value));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('storage 页在窄屏可渲染', (tester) async {
    // 这一页要读 App 的几个目录去量大小，测试里没有真正的应用环境，
    // 指到临时目录让它能量、能渲染就行。
    //
    // 注意：目录统计是真实的文件 I/O，必须放在 runAsync 里。testWidgets
    // 默认跑在 FakeAsync 下，真实 I/O 的 Future 等不到，测试会一直挂着。
    late Directory temp;
    await tester.runAsync(() async {
      temp = await Directory.systemTemp.createTemp('storage_page_test');
      File('${temp.path}/logs.txt').writeAsStringSync('log line');
    });
    App.cachePath = temp.path;
    App.dataPath = temp.path;
    LocalManager().path = temp.path;

    await tester.binding.setSurfaceSize(const Size(360, 900));
    await tester.runAsync(() async {
      await tester.pumpWidget(wrap(const StorageSettings()));
      // 等 initState 里的异步统计跑完
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    expect(tester.takeException(), isNull);
    // 「日志」行出现说明数据真的加载出来了，而不是停在 loading
    expect(find.text('Logs'.tl), findsOneWidget);
  });
}
