import 'dart:io';

import 'package:flutter/services.dart';

/// 触感反馈。
///
/// Flutter 自带的 `HapticFeedback.selectionClick()` 在 Android 上对应
/// `HapticFeedbackConstants.CLOCK_TICK`，强度和时长全由系统决定——国内 ROM
/// 普遍把它调得又重又长，在底栏这种一点就切的位置上像在「砸」按钮。
///
/// 这里改走一个自己开的小通道，用 `VibrationEffect.createOneShot` 发一段
/// 极短的定振幅震动：设备支持振幅控制时真的能调轻，不支持时退回系统默认
/// 振幅（至少时长仍然更短）。iOS 上没有这条通道，直接沿用系统的
/// selectionClick。
class Haptics {
  Haptics._();

  static const MethodChannel _channel = MethodChannel('venera/haptics');

  /// 点一下时用的参数。再轻就没有「按到了」的实感了。
  static const int _tapDurationMs = 8;

  static const int _tapAmplitude = 45;

  /// 一次很轻的点击反馈。
  ///
  /// 失败（老系统 / 通道没注册 / 测试环境）时退回系统那一下，
  /// 宁可稍重也不要没有反馈。
  static Future<void> tap() async {
    if (!Platform.isAndroid) {
      await HapticFeedback.selectionClick();
      return;
    }
    try {
      await _channel.invokeMethod("tick", {
        "durationMs": _tapDurationMs,
        "amplitude": _tapAmplitude,
      });
    } catch (_) {
      await HapticFeedback.selectionClick();
    }
  }
}
