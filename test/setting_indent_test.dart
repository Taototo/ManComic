import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/settings/settings_page.dart';

/// 明细行缩进取决于「本页有没有分组标题」：
/// 有标题的页面内收到 48 去对齐标题文字，没有标题的页面回到 16，
/// 否则整页左边会平白多出一段空白。
void main() {
  Future<EdgeInsetsDirectional> paddingOf(
    WidgetTester tester, {
    bool? indented,
  }) async {
    late EdgeInsetsDirectional padding;
    Widget body = Builder(
      builder: (context) {
        padding = kSettingTilePaddingOf(context);
        return const SizedBox.shrink();
      },
    );
    if (indented != null) {
      body = SettingIndentScope(indented: indented, child: body);
    }
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: body)));
    return padding;
  }

  testWidgets('没有分组标题时用普通左边距 16', (tester) async {
    var padding = await paddingOf(tester, indented: false);
    expect(padding.start, 16);
    expect(padding.end, 16);
  });

  testWidgets('有分组标题时内收到 48 对齐标题文字', (tester) async {
    var padding = await paddingOf(tester, indented: true);
    expect(padding.start, 48);
  });

  testWidgets('没包 scope 时按有标题处理，不会突然全部顶到最左', (tester) async {
    var padding = await paddingOf(tester);
    expect(padding.start, 48);
  });

  testWidgets('scope 只影响自己这棵子树', (tester) async {
    late EdgeInsetsDirectional inside;
    late EdgeInsetsDirectional sibling;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SettingIndentScope(
                indented: false,
                child: Builder(
                  builder: (context) {
                    inside = kSettingTilePaddingOf(context);
                    return const SizedBox.shrink();
                  },
                ),
              ),
              Builder(
                builder: (context) {
                  sibling = kSettingTilePaddingOf(context);
                  return const SizedBox.shrink();
                },
              ),
            ],
          ),
        ),
      ),
    );
    expect(inside.start, 16);
    expect(sibling.start, 48);
  });
}
