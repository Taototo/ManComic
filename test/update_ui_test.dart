import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
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

  testWidgets('关于页安装入口：按钮不侵占标题宽度', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 720));
    var previous = updateDownload.pending;
    updateDownload.pending = const PendingUpdate(
      version: "1.4.18",
      path: "/tmp/ManComic-1.4.18.apk",
      size: 51850225,
    );
    addTearDown(() => updateDownload.pending = previous);

    await tester.pumpWidget(wrap(const UpdateEntryTile()));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text("Install update"), findsOneWidget);
    expect(find.text("Install"), findsOneWidget);

    // 标题必须是一整行：被 trailing 挤没宽度时 Text 会退化成「一字一行」，
    // 渲染出来的宽度只剩一个字的宽度（测试字体里等于字号）。
    expect(tester.getSize(find.text("Install update")).width, greaterThan(100));
    // 按钮按内容宽度收缩，不能撑满整行
    expect(tester.getSize(find.byType(Button)).width, lessThan(180));
  });
}
