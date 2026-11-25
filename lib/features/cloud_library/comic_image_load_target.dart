import 'package:flutter/foundation.dart';

/// 云端库图片加载目标的最小本地定义。
///
/// ManComi 的 `network/images.dart` 没有这些类型，而库引擎的图片加载配置
/// 用它们描述请求尺寸。保留与原版相同的字段与语义即可。
enum ComicImageTargetFit {
  contain,
  fitWidth,
  fitHeight;

  static ComicImageTargetFit fromString(String? value) => switch (value) {
    'fitWidth' => ComicImageTargetFit.fitWidth,
    'fitHeight' => ComicImageTargetFit.fitHeight,
    _ => ComicImageTargetFit.contain,
  };
}

@immutable
class ComicImageLoadTarget {
  final double? logicalWidth;
  final double? logicalHeight;
  final double devicePixelRatio;
  final ComicImageTargetFit fit;
  final bool splitWideImage;

  ComicImageLoadTarget({
    double? logicalWidth,
    double? logicalHeight,
    double devicePixelRatio = 1.0,
    this.fit = ComicImageTargetFit.contain,
    this.splitWideImage = false,
  }) : logicalWidth =
           (logicalWidth != null && logicalWidth.isFinite && logicalWidth > 0)
           ? logicalWidth
           : null,
       logicalHeight =
           (logicalHeight != null && logicalHeight.isFinite && logicalHeight > 0)
           ? logicalHeight
           : null,
       devicePixelRatio = (devicePixelRatio.isFinite && devicePixelRatio > 0)
           ? devicePixelRatio
           : 1.0;

  const ComicImageLoadTarget.raw({
    this.logicalWidth,
    this.logicalHeight,
    this.devicePixelRatio = 1.0,
    this.fit = ComicImageTargetFit.contain,
    this.splitWideImage = false,
  });

  double get normalizedDevicePixelRatio =>
      (devicePixelRatio.isFinite && devicePixelRatio > 0)
      ? devicePixelRatio
      : 1.0;

  int? get physicalWidth {
    final w = logicalWidth;
    if (w == null || !w.isFinite || w <= 0) return null;
    final pw = (w * normalizedDevicePixelRatio).round();
    return pw > 0 ? pw : null;
  }

  int? get physicalHeight {
    final h = logicalHeight;
    if (h == null || !h.isFinite || h <= 0) return null;
    final ph = (h * normalizedDevicePixelRatio).round();
    return ph > 0 ? ph : null;
  }

  String get cacheIdentity {
    final pw = physicalWidth;
    final ph = physicalHeight;
    return '${pw != null ? 'w$pw' : 'wnull'}-${ph != null ? 'h$ph' : 'hnull'}-'
        'dpr$normalizedDevicePixelRatio-${fit.name}-split$splitWideImage';
  }

  Map<String, dynamic> toJson() => {
    'logicalWidth': logicalWidth,
    'logicalHeight': logicalHeight,
    'devicePixelRatio': normalizedDevicePixelRatio,
    'fit': fit.name,
    'splitWideImage': splitWideImage,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ComicImageLoadTarget &&
          physicalWidth == other.physicalWidth &&
          physicalHeight == other.physicalHeight &&
          normalizedDevicePixelRatio == other.normalizedDevicePixelRatio &&
          fit == other.fit &&
          splitWideImage == other.splitWideImage);

  @override
  int get hashCode => Object.hash(
    physicalWidth,
    physicalHeight,
    normalizedDevicePixelRatio,
    fit,
    splitWideImage,
  );

  @override
  String toString() => 'ComicImageLoadTarget($cacheIdentity)';
}
