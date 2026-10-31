import 'dart:io';

import 'package:flutter/services.dart';

/// 阅读页屏幕亮度控制。
///
/// 直接设置本应用窗口的亮度（`WindowManager.LayoutParams.screenBrightness`），
/// 不干预系统亮度设置，也不会去跟随系统自动亮度的变化——
/// 滑块位置就是当前窗口的实际亮度，退出阅读页后交还系统。
class ScreenBrightness {
  ScreenBrightness._();

  static const MethodChannel _channel = MethodChannel('venera/method_channel');

  /// 是否支持（目前仅 Android 通过窗口覆盖实现）。
  static bool get isSupported => Platform.isAndroid;

  /// 当前生效亮度（0.0 - 1.0）。未设置过窗口亮度时返回系统亮度，失败返回 null。
  static Future<double?> get() async {
    if (!isSupported) return null;
    try {
      final value = await _channel.invokeMethod<double>('getBrightness');
      if (value == null) return null;
      return value.clamp(0.0, 1.0);
    } catch (_) {
      return null;
    }
  }

  /// 直接把窗口亮度设为 [value]（0.0 - 1.0）。
  static Future<void> set(double value) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('setBrightness', {
        'value': value.clamp(0.01, 1.0),
      });
    } catch (_) {
      // 忽略：部分定制系统可能拦截，保持原亮度即可
    }
  }

  /// 取消窗口亮度覆盖，恢复由系统亮度控制。
  static Future<void> reset() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('resetBrightness');
    } catch (_) {
      // ignore
    }
  }
}
