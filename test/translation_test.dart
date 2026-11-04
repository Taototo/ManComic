import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 校验「关于」页及本轮修复的用户可见文案在翻译表里都有对应条目。
///
/// 这类问题不会编译报错，只会在真机上露出一句英文，
/// 所以用测试把「代码里的文案」和「翻译表」钉在一起。
void main() {
  late Map<String, Map<String, String>> translations;

  setUpAll(() {
    var json = jsonDecode(File('assets/translation.json').readAsStringSync())
        as Map<String, dynamic>;
    translations = {
      for (var e in json.entries)
        e.key: Map<String, String>.from(e.value as Map)
    };
  });

  test('简繁两套翻译的 key 集合保持一致', () {
    expect(
      translations['zh_CN']!.keys.toSet(),
      translations['zh_TW']!.keys.toSet(),
      reason: '新增文案要同时补简体和繁体，否则繁体用户会看到英文',
    );
  });

  test('关于页与更新提示的文案都有中文', () {
    const keys = [
      "About",
      "Check for updates",
      "Check",
      "Check for updates on startup",
      "New version available",
      "No new version available",
      "Check for updates failed",
      "Found new version @version, current version @current.",
      "New version found but no APK published",
      "The update will be downloaded and installed automatically.",
      "Open in browser",
      "Update now",
      "Downloading update",
      "Update downloaded",
      "Unable to start the installer",
      "Download failed",
      "Cancel",
      "Download",
      "GitHub",
    ];
    for (var key in keys) {
      expect(translations['zh_CN']![key], isNotNull, reason: '缺少中文: $key');
      expect(translations['zh_TW']![key], isNotNull, reason: '缺少繁体: $key');
    }
  });

  test('本轮补译的界面文案都有中文', () {
    const keys = [
      "Reload Configs",
      "Continue",
      "Rating",
      "Empty Page",
      "More",
      "No Image",
      "Invalid url config",
      "Save",
      "Loading",
      "Network error",
      "Unknown error",
      "@a Tasks",
      "@a sources",
      // 退到最底层再返回时的退出确认
      "Exit",
      "Are you sure you want to exit?",
    ];
    for (var key in keys) {
      expect(translations['zh_CN']![key], isNotNull, reason: '缺少中文: $key');
    }
  });
}
