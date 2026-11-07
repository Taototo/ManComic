part of 'components.dart';

/// 液态玻璃引擎开关与适配层。
///
/// `liquid_glass_widgets` 提供的是真正的折射着色器（边缘会把背景弯折，
/// 而不是单纯变糊），但有两个问题必须在这里收口：
///
/// 1. 它导出的 `LiquidGlass` 和本项目自研的 [LiquidGlass] **重名**，
///    谁先 import 谁生效，直接引会变成一团乱账；
/// 2. 它是实验特性，必须能一键退回原来的观感做 A/B 对比。
///
/// 所以调用方只认 [LiquidGlassPanel]，具体走哪套渲染由设置决定。
class LiquidGlassEngine {
  LiquidGlassEngine._();

  /// 设置 -> 外观 -> 液态玻璃。试用版默认开启。
  ///
  /// 只认显式的 `false`：老用户升级上来时这个 key 还不存在，
  /// 不能因为「没配过」就当成关闭。
  static bool get enabled => appdata.settings['liquidGlass'] != false;

  /// 渲染档位。
  ///
  /// 顶栏/底栏都是固定不滚动的位置，理论上可以用 premium，
  /// 但它每帧要把背景采样成纹理，滚动手感会明显变重；默认停在
  /// standard，真机上想要更"厚"的玻璃再手动切。
  static lg.GlassQuality get quality {
    return switch (appdata.settings['liquidGlassQuality']) {
      'premium' => lg.GlassQuality.premium,
      'minimal' => lg.GlassQuality.minimal,
      _ => lg.GlassQuality.standard,
    };
  }

  /// 自研实现的模糊半径是 sigma（量级 0-40），新引擎的 blur 是另一套
  /// 标度（量级 0-15）。按 3.5 倍折算，默认 26 落到 7.4。
  static double mapBlur(double sigma) => (sigma / 3.5).clamp(0.0, 15.0);

  /// 组装新引擎的玻璃参数。
  ///
  /// 透镜感（边缘把背景弯折、像凸透镜）只在玻璃**足够清透**时可见：
  /// 底色 alpha 一高，折射就被磨砂层盖住，只剩「糊」。所以这里的 tint
  /// 给得比自研实现淡得多，厚度和折射率反过来给大，让 spherical 透镜
  /// 模型在边缘真正弯出弧度。
  static lg.LiquidGlassSettings settings(
    BuildContext context, {
    double? blurSigma,
    double? opacity,
    Color? tint,
    double saturation = 1.4,
    bool shadow = true,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final alpha = ((opacity ?? GlassConfig.opacity) * 0.35).clamp(0.0, 0.6);
    final tintColor =
        (tint ?? theme.colorScheme.surface).withValues(alpha: alpha);
    return lg.LiquidGlassSettings(
      blur: mapBlur(blurSigma ?? GlassConfig.blur),
      glassColor: tintColor,
      saturation: saturation,
      // 厚度直接决定边缘弯折的幅度；暗色下略收，避免高光发灰。
      thickness: isDark ? 20 : 28,
      lightIntensity: isDark ? 0.55 : 0.9,
      // 空气≈1.0，普通玻璃≈1.5。默认 1.2 偏塑料，提到 1.4 透镜感明显。
      refractiveIndex: 1.4,
      shadowElevation: shadow ? 1.0 : 0.0,
    );
  }
}

/// 与 [LiquidGlass] 参数对齐的玻璃面板，内部按设置切换渲染引擎。
///
/// 参数沿用自研那套命名，是为了让原来的调用点只换一个类名就能接上新引擎，
/// 不用在业务代码里出现两套不同的玻璃词汇。
class LiquidGlassPanel extends StatelessWidget {
  const LiquidGlassPanel({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(26)),
    this.blur,
    this.opacity,
    this.tint,
    this.saturation = 1.4,
    this.shadow = true,
    this.quality,
  });

  final Widget child;

  final BorderRadius borderRadius;

  /// 模糊半径，默认取全局玻璃设置
  final double? blur;

  /// 底色不透明度，默认取全局玻璃设置
  final double? opacity;

  /// 底色，默认取主题 surface
  final Color? tint;

  final double saturation;

  final bool shadow;

  /// 覆盖全局档位。顶栏和底栏都是固定表面，可以单独调高。
  final lg.GlassQuality? quality;

  @override
  Widget build(BuildContext context) {
    // 回退分支：和引入新引擎之前的渲染完全一致。
    if (!LiquidGlassEngine.enabled) {
      return LiquidGlass(
        borderRadius: borderRadius,
        blur: blur,
        opacity: opacity,
        tint: tint,
        saturation: saturation,
        shadow: shadow,
        child: child,
      );
    }

    final radius = borderRadius.topLeft.x;

    return lg.AdaptiveGlass(
      shape: radius <= 0.5
          ? const lg.LiquidRoundedRectangle(borderRadius: 0)
          : lg.LiquidRoundedSuperellipse(borderRadius: radius),
      quality: quality ?? LiquidGlassEngine.quality,
      settings: LiquidGlassEngine.settings(
        context,
        blurSigma: blur,
        opacity: opacity,
        tint: tint,
        saturation: saturation,
        shadow: shadow,
      ),
      child: child,
    );
  }
}

/// 给顶栏/底栏这类「贴边固定表面」用的玻璃。
///
/// 和 [LiquidGlassPanel] 的区别只有一处：默认按 premium 档跑。
/// 它们不随内容滚动，采样背景的次数固定，值得多花这点性能换厚度；
/// 真正翻列表的卡片仍然走 standard。
class LiquidGlassBar extends StatelessWidget {
  const LiquidGlassBar({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.quality,
  });

  final Widget child;

  final BorderRadius borderRadius;

  final lg.GlassQuality? quality;

  @override
  Widget build(BuildContext context) {
    return LiquidGlassPanel(
      borderRadius: borderRadius,
      quality: quality ?? lg.GlassQuality.premium,
      child: child,
    );
  }
}
