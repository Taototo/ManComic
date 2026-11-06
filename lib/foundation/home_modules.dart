import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:venera/foundation/appdata.dart';

/// 首页一个可配置模块的定义。
class HomeModuleDef {
  const HomeModuleDef(this.id, this.title, this.icon);

  /// 持久化用的稳定 id，不要修改
  final String id;

  /// 翻译键
  final String title;

  final IconData icon;
}

/// 首页模块的顺序与显隐，存在 settings['homeModules'] 里。
class HomeModules {
  static const String _settingKey = 'homeModules';

  static const List<HomeModuleDef> definitions = [
    HomeModuleDef(
      'continue_reading',
      'Continue Reading',
      Icons.play_circle_outline,
    ),
    HomeModuleDef('sync_data', 'Data Sync', Icons.sync),
    HomeModuleDef('history', 'History', Icons.history),
    HomeModuleDef('follow_updates', 'Follow Updates', Icons.update),
    // 「漫画源」入口已移至 设置 → APP，不再作为首页模块
    HomeModuleDef('local', 'Local Comics', Icons.folder_outlined),
    HomeModuleDef(
      'image_favorites',
      'Image Favorites',
      Icons.collections_outlined,
    ),
    HomeModuleDef('random_pick', 'Draw a comic', Icons.casino_outlined),
  ];

  static HomeModuleDef? byId(String id) {
    for (final d in definitions) {
      if (d.id == id) return d;
    }
    return null;
  }

  /// 已保存的顺序（可能含已废弃的 id，读取时会被过滤）。
  static List<String> get order {
    final raw = appdata.settings[_settingKey];
    if (raw is String && raw.isNotEmpty) {
      try {
        final map = jsonDecode(raw);
        if (map is Map && map['order'] is List) {
          return (map['order'] as List).map((e) => e.toString()).toList();
        }
      } catch (_) {}
    }
    return definitions.map((e) => e.id).toList();
  }

  /// 是否已显式配置过（区分“全部关闭”与“从未配置”）。
  static bool get configured {
    final raw = appdata.settings[_settingKey];
    if (raw is String && raw.isNotEmpty) {
      try {
        final map = jsonDecode(raw);
        return map is Map && map['order'] is List;
      } catch (_) {}
    }
    return false;
  }

  /// 启用的模块 id（未配置过时默认全部启用）。
  static Set<String> get enabledIds {
    final raw = appdata.settings[_settingKey];
    if (raw is String && raw.isNotEmpty) {
      try {
        final map = jsonDecode(raw);
        if (map is Map && map['enabled'] is List) {
          return (map['enabled'] as List).map((e) => e.toString()).toSet();
        }
      } catch (_) {}
    }
    return definitions.map((e) => e.id).toSet();
  }

  /// 首页要渲染的模块（已按顺序、已过滤）。
  static List<HomeModuleDef> load() {
    final enabled = enabledIds;
    final ordered = <HomeModuleDef>[];
    final seen = <String>{};
    for (final id in order) {
      if (!seen.add(id)) continue;
      final def = byId(id);
      if (def != null && enabled.contains(id)) {
        ordered.add(def);
      }
    }
    // 新增但旧配置里没有的模块，默认追加在末尾并保持启用
    for (final def in definitions) {
      if (seen.contains(def.id)) continue;
      if (enabled.contains(def.id)) {
        ordered.add(def);
      }
    }
    return ordered;
  }

  static void save(List<String> order, Set<String> enabled) {
    appdata.settings[_settingKey] = jsonEncode({
      'order': order,
      'enabled': enabled.toList(),
    });
    appdata.saveData();
  }

  /// 恢复默认顺序与显隐。
  static void reset() {
    appdata.settings[_settingKey] = jsonEncode({
      'order': definitions.map((e) => e.id).toList(),
      'enabled': definitions.map((e) => e.id).toList(),
    });
    appdata.saveData();
  }
}
