import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  for (final entry in {
    'interface': const InterfaceSettings(),
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
}
