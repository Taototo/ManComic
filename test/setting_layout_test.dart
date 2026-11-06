import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/settings/settings_page.dart';

/// 设置页的版式约定：左内边距只有一种，且每个页面都有分组标题。
///
/// 这两条必须一起成立。曾经为了让「没有标题的页面」回到 16，引入了
/// InheritedWidget 按页面判断缩进，结果判断函数拿到的是页面 State 自己的
/// context（位于 scope 之上），永远读不到值、永远按 48 处理——关于页怎么改
/// 都还是缩进 48。现在规则只剩一条：**每页都有分组标题，明细行恒为 48**。
/// 这个测试就是防止哪天又有人加回「按页面切换缩进」。
void main() {
  test('明细行缩进只有一种取值', () {
    expect(kSettingTilePadding.start, 48);
    expect(kSettingTilePadding.end, 16);
  });

  test('每个设置页都有分组标题', () {
    // 页面文件 → 至少需要几个分组标题
    const pages = {
      'interface_settings.dart': 5,
      'action_settings.dart': 2,
      'feature_settings.dart': 4,
      'reader.dart': 4,
      // 下载线程搬去「功能」后，网络页只剩「连接」一组。
      'network.dart': 1,
      'about.dart': 2,
    };
    for (final entry in pages.entries) {
      final source = File(
        'lib/pages/settings/${entry.key}',
      ).readAsStringSync();
      final count = RegExp(r'_SettingPartTitle\(').allMatches(source).length;
      expect(
        count,
        greaterThanOrEqualTo(entry.value),
        reason: '${entry.key} 的分组标题只剩 $count 个',
      );
    }
  });

  test('没有再按页面切换缩进的机制', () {
    final dir = Directory('lib/pages/settings');
    for (final entity in dir.listSync()) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      final source = entity.readAsStringSync();
      expect(
        source.contains('SettingIndentScope'),
        isFalse,
        reason: '${entity.path} 里还在用 SettingIndentScope',
      );
      expect(
        source.contains('kSettingTilePaddingOf'),
        isFalse,
        reason: '${entity.path} 里还在用 kSettingTilePaddingOf',
      );
    }
  });
}
