import 'dart:io';

import 'package:flutter/services.dart';
import 'package:venera/foundation/appdata.dart';

/// 一个内置应用图标的描述。
class AppIconOption {
  /// 存储 / 与原生端约定的键名
  final String key;

  /// 显示名（会被翻译）
  final String name;

  /// 设置页预览、启动页、关于页使用的资源
  final String asset;

  const AppIconOption(this.key, this.name, this.asset);
}

/// 内置图标列表，顺序与 Android 端 activity-alias 一一对应。
/// 第一项即默认图标（comic4.png 线稿恐龙）。
/// key 与 Android 端 activity-alias 通过 [iconAliases] 一一对应，
/// alias 组件名（Icon1/Icon2/Icon4/Icon5/Icon6）必须保持稳定，改名会导致桌面入口失效。
const List<AppIconOption> appIconOptions = [
  AppIconOption('default', 'Sketch', 'assets/icons/icon_0.png'),
  AppIconOption('classic', 'Classic', 'assets/icons/icon_1.png'),
  AppIconOption('neon', 'Neon', 'assets/icons/icon_2.png'),
  AppIconOption('cat', 'Cat', 'assets/icons/icon_3.png'),
  AppIconOption('logo', 'Logo', 'assets/icons/icon_4.png'),
];

/// 应用图标管理：桌面图标切换（Android activity-alias）+ 本地记录。
class AppIcon {
  static const MethodChannel _channel = MethodChannel('venera/method_channel');

  static const String _storageKey = 'app_icon';

  /// 当前选择的图标键名
  static String get currentKey {
    final v = appdata.implicitData[_storageKey];
    if (v is String && appIconOptions.any((e) => e.key == v)) {
      return v;
    }
    return 'default';
  }

  static AppIconOption get current => optionOf(currentKey);

  /// 当前图标对应的资源路径（启动页 / 关于页 / 设置页预览共用）
  static String get currentAsset => current.asset;

  static AppIconOption optionOf(String key) {
    return appIconOptions.firstWhere(
      (e) => e.key == key,
      orElse: () => appIconOptions.first,
    );
  }

  /// 切换图标。
  ///
  /// Android 上这里**不会**立即改 launcher 组件：运行中启用/禁用 activity-alias
  /// 会让部分系统直接结束当前任务（表现为闪退）。这里只记录选择，
  /// 由原生端在下次启动的最早期（onCreate）完成切换。
  static Future<bool> apply(String key) async {
    var ok = true;
    if (Platform.isAndroid) {
      try {
        ok = await _channel.invokeMethod<bool>('setAppIcon', {'key': key}) ?? true;
      } catch (_) {
        ok = false;
      }
    }
    if (!ok) {
      return false;
    }
    appdata.implicitData[_storageKey] = key;
    appdata.writeImplicitData();
    return true;
  }

  /// 关闭应用，退出前把待切换的图标应用到桌面。
  ///
  /// 用于「立即重启」按钮：不再重启到新任务的加载页，
  /// 而是直接退出，下次从桌面打开即为新图标。
  static Future<void> closeAndApply() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('closeApp');
    } catch (_) {
      // ignore
    }
  }

  /// 读取系统当前实际启用的图标。
  /// 仅用于诊断/自愈，不会覆盖用户刚刚选中的图标（因为它要等下次启动才生效）。
  static Future<String?> systemKey() async {
    if (!Platform.isAndroid) {
      return currentKey;
    }
    try {
      return await _channel.invokeMethod<String>('getAppIcon');
    } catch (_) {
      return null;
    }
  }

  /// 自愈：保证系统里至少存在一个可用的桌面入口，
  /// 并把「本地选择 ≠ 系统生效」的差异重新排进待切换队列。
  static Future<void> ensureApplied() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      final sysKey = await systemKey();
      if (sysKey == currentKey) return;
      // 交回原生端排队，下次启动生效
      await _channel.invokeMethod<bool>('setAppIcon', {'key': currentKey});
    } catch (_) {
      // 忽略：失败时保留原状态，不影响启动
    }
  }
}
