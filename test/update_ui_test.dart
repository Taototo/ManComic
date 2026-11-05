import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

/// 渲染冒烟：三种更新卡片在窄屏上不能溢出，按钮必须真的能触发回调。
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
      home: Scaffold(body: child),
    );
  }

  testWidgets('下载卡片：收起与取消各走各的回调', (tester) async {
    var minimized = 0;
    var cancelled = 0;
    await tester.binding.setSurfaceSize(const Size(360, 720));
    await tester.pumpWidget(
      wrap(
        UpdateDownloadDialog(
          received: 12 * 1048576,
          total: 49 * 1048576,
          speed: 2.4 * 1048576,
          onMinimize: () => minimized++,
          onCancel: () => cancelled++,
        ),
      ),
    );
    // 进度环是常驻动画（repeat），不能用 pumpAndSettle
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down_rounded));
    await tester.pump(const Duration(milliseconds: 300));
    expect(minimized, 1);
    expect(cancelled, 0);

    await tester.tap(find.text("Cancel"));
    await tester.pump(const Duration(milliseconds: 300));
    expect(cancelled, 1);
  });

  testWidgets('完成提示：立即安装与稍后安装', (tester) async {
    var installed = 0;
    var later = 0;
    await tester.binding.setSurfaceSize(const Size(360, 720));
    await tester.pumpWidget(
      wrap(
        UpdateReadyDialog(
          pending: const PendingUpdate(
            version: "1.4.16",
            path: "/tmp/ManComic-1.4.16.apk",
            size: 51816205,
          ),
          onInstall: () => installed++,
          onLater: () => later++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.download_done_rounded), findsOneWidget);
    expect(find.text("1.4.16"), findsOneWidget);

    await tester.tap(find.text("Install later"));
    await tester.pumpAndSettle();
    expect(later, 1);
    expect(installed, 0);

    await tester.tap(find.text("Install now"));
    await tester.pumpAndSettle();
    expect(installed, 1);
  });

  testWidgets('顶部悬浮条只能在 Stack 里渲染', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    await tester.pumpWidget(
      wrap(
        Stack(
          children: [
            const SizedBox.expand(),
            const UpdateDownloadBanner(),
            Builder(builder: (context) => const SizedBox.expand()),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });
}
