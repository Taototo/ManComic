import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';

/// 长按菜单的分组规则：破坏性动作前单独隔一条线。
/// 这条线插错（例如每项之间都插，或者连续两个删除项插两条）
/// 会让菜单看起来比实际更长，正是这次要解决的「项太多」的观感来源。
void main() {
  Future<void> openMenu(WidgetTester tester, List<MenuEntry> entries) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showMenuX(context, const Offset(20, 120), entries),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('普通动作之间不加分隔线', (tester) async {
    await openMenu(tester, [
      MenuEntry(icon: Icons.copy, text: 'Copy Title', onClick: () {}),
      MenuEntry(icon: Icons.block, text: 'Block', onClick: () {}),
    ]);
    expect(find.text('Copy Title'), findsOneWidget);
    expect(find.byType(Divider), findsNothing);
  });

  testWidgets('危险动作前加一条分隔线', (tester) async {
    await openMenu(tester, [
      MenuEntry(icon: Icons.copy, text: 'Copy Title', onClick: () {}),
      MenuEntry(icon: Icons.download, text: 'Download', onClick: () {}),
      MenuEntry(
        icon: Icons.delete_outline,
        text: 'Delete',
        isDanger: true,
        onClick: () {},
      ),
    ]);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.byType(Divider), findsOneWidget);
  });

  testWidgets('连续的危险动作只在第一项前加线', (tester) async {
    await openMenu(tester, [
      MenuEntry(icon: Icons.copy, text: 'Copy Title', onClick: () {}),
      MenuEntry(icon: Icons.delete, text: 'Delete', isDanger: true, onClick: () {}),
      MenuEntry(icon: Icons.remove, text: 'Remove', isDanger: true, onClick: () {}),
    ]);
    expect(find.byType(Divider), findsOneWidget);
  });

  testWidgets('第一项就是危险动作时不加线', (tester) async {
    await openMenu(tester, [
      MenuEntry(icon: Icons.delete, text: 'Delete', isDanger: true, onClick: () {}),
    ]);
    expect(find.byType(Divider), findsNothing);
  });
}
