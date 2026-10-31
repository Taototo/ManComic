import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// 图片边缘的纯色留白占比（0 - 1，按上下顺序）。
class EdgeTrim {
  /// 顶部需要裁掉的比例
  final double top;

  /// 底部需要裁掉的比例
  final double bottom;

  const EdgeTrim(this.top, this.bottom);

  static const none = EdgeTrim(0, 0);

  bool get isNone => top <= 0.001 && bottom <= 0.001;

  @override
  String toString() => 'EdgeTrim(${top.toStringAsFixed(3)}, ${bottom.toStringAsFixed(3)})';
}

/// 裁边强度预设
enum TrimLevel {
  off('off', 0, 0),
  conservative('conservative', 10, 0.18),
  normal('normal', 18, 0.30),
  aggressive('aggressive', 30, 0.45);

  /// 设置里存的值
  final String key;

  /// 相邻像素允许的色差（0-255）
  final double tolerance;

  /// 单边最多裁掉的比例
  final double maxRatio;

  const TrimLevel(this.key, this.tolerance, this.maxRatio);

  static TrimLevel fromKey(String? key) {
    for (var e in values) {
      if (e.key == key) return e;
    }
    return TrimLevel.normal;
  }
}

/// 分析图片上下边缘的纯色留白。
///
/// 做法：把图片缩到很小（宽 64），逐行判断是否为「整行同色」，
/// 从上下两端向内累计，遇到第一行有内容的就停下。
/// 这样不必回读整张大图的像素，代价可以忽略。
Future<EdgeTrim> computeEdgeTrim(
  ui.Image image,
  TrimLevel level,
) async {
  if (level == TrimLevel.off) {
    return EdgeTrim.none;
  }
  const targetWidth = 64;
  final scale = targetWidth / image.width;
  final targetHeight = (image.height * scale).round().clamp(1, 4096);

  ui.Image? small;
  try {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, targetWidth.toDouble(), targetHeight.toDouble()),
      Paint()..filterQuality = FilterQuality.low,
    );
    small = await recorder.endRecording().toImage(targetWidth, targetHeight);
    final data = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) {
      return EdgeTrim.none;
    }
    final bytes = data.buffer.asUint8List();
    final tol = level.tolerance;

    bool uniformRow(int y) {
      var minR = 255, minG = 255, minB = 255;
      var maxR = 0, maxG = 0, maxB = 0;
      final offset = y * targetWidth * 4;
      for (var x = 0; x < targetWidth; x++) {
        final i = offset + x * 4;
        final r = bytes[i], g = bytes[i + 1], b = bytes[i + 2];
        if (r < minR) minR = r;
        if (g < minG) minG = g;
        if (b < minB) minB = b;
        if (r > maxR) maxR = r;
        if (g > maxG) maxG = g;
        if (b > maxB) maxB = b;
        if (maxR - minR > tol || maxG - minG > tol || maxB - minB > tol) {
          return false;
        }
      }
      return true;
    }

    final maxTop = (targetHeight * level.maxRatio).floor();
    var top = 0;
    while (top < maxTop && uniformRow(top)) {
      top++;
    }
    final maxBottom = (targetHeight * level.maxRatio).floor();
    var bottom = 0;
    while (bottom < maxBottom &&
        uniformRow(targetHeight - 1 - bottom)) {
      bottom++;
    }

    // 上下都裁得很多时很可能是纯色图（例如只有一行字的过场页），保守回退
    if (top + bottom > targetHeight * 0.55) {
      return EdgeTrim.none;
    }
    return EdgeTrim(top / targetHeight, bottom / targetHeight);
  } catch (_) {
    return EdgeTrim.none;
  } finally {
    small?.dispose();
  }
}
