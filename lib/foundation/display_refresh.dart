import 'dart:io';

import 'package:flutter/services.dart';
import 'package:venera/foundation/log.dart';

/// 屏幕刷新率控制。
///
/// Flutter 的帧由屏幕 vsync 驱动，本身就能跑满高刷；真正会掉到 60 的是
/// **系统**：不少 ROM 在省电策略里给非白名单应用锁 60Hz，切后台回来也会
/// 把窗口的帧率提示重置。所以要主动向系统申请，并在回到前台时重放。
///
/// 具体申请逻辑在 `MainActivity.applyFrameRate`：`Window.setFrameRate`
/// （Android 11+ 的 VRR 提示）加 `preferredDisplayModeId`（老设备与只认
/// 显示模式的 ROM）两条路一起走。
class DisplayRefresh {
  DisplayRefresh._();

  static const MethodChannel _channel = MethodChannel('venera/display');

  /// 设置里可选的档位。auto 表示跟随屏幕能给的最高刷新率。
  static const List<String> modes = ['auto', '60', '90', '120'];

  static double _refreshRate = 60;
  static double _maxRefreshRate = 60;
  static List<double> _supported = const [60];

  /// 当前屏幕实际刷新率（由系统回报，可能低于申请值）。
  static double get refreshRate => _refreshRate;

  /// 屏幕在相同分辨率下能达到的最高刷新率。
  static double get maxRefreshRate => _maxRefreshRate;

  /// 屏幕支持的全部刷新率档位，升序。
  static List<double> get supportedRates => List.unmodifiable(_supported);

  /// 把设置里的档位换算成要申请的帧率；null 表示「屏幕最高」。
  static double? targetFor(String mode) {
    if (mode == 'auto') return null;
    return double.tryParse(mode);
  }

  /// 按设置申请帧率，并刷新缓存下来的显示信息。
  ///
  /// 桌面端没有这个通道，直接跳过。
  static Future<void> apply(String mode) async {
    if (!Platform.isAndroid) return;
    try {
      final info = await _channel.invokeMapMethod<String, dynamic>(
        'applyFrameRate',
        {'target': targetFor(mode)},
      );
      _read(info);
      Log.info(
        "Display",
        "requested ${mode == 'auto' ? 'max' : mode}Hz, "
            "active ${_refreshRate.toStringAsFixed(0)}Hz, "
            "max ${_maxRefreshRate.toStringAsFixed(0)}Hz",
      );
    } catch (e, s) {
      Log.error("Display", "applyFrameRate($mode) failed: $e\n$s");
    }
  }

  /// 只读取当前显示信息，不改变任何设置。
  static Future<void> refreshInfo() async {
    if (!Platform.isAndroid) return;
    try {
      final info =
          await _channel.invokeMapMethod<String, dynamic>('getDisplayInfo');
      _read(info);
    } catch (e) {
      // 查询失败不影响使用，保持默认值即可。
    }
  }

  static void _read(Map<String, dynamic>? info) {
    if (info == null) return;
    final active = info['refreshRate'];
    final max = info['maxRefreshRate'];
    final supported = info['supported'];
    if (active is num) _refreshRate = active.toDouble();
    if (max is num) _maxRefreshRate = max.toDouble();
    if (supported is List) {
      _supported = supported.whereType<num>().map((e) => e.toDouble()).toList();
      if (_supported.isEmpty) _supported = [_refreshRate];
    }
  }
}
