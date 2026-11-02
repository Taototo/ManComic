part of 'components.dart';

/// 保留所有子页面状态的「带方向感」切换容器。
///
/// 与 [IndexedStack] 一样保留全部子页面的 State，但切换时不是硬切：
/// 新页面从对应方向淡入，旧页面向反方向淡出，于是「往右切」和「往左切」
/// 有明确的空间关系。
///
/// 方向不需要额外记录：静止时令 i < index 的子页停在左侧、i > index 的
/// 停在右侧，切换时它们自然沿各自的方向滑入滑出。
class DirectionalIndexedStack extends StatelessWidget {
  const DirectionalIndexedStack({
    super.key,
    required this.index,
    required this.children,
    this.duration = const Duration(milliseconds: 240),
    this.slide = 0.05,
  });

  final int index;

  final List<Widget> children;

  final Duration duration;

  /// 静止时的横向偏移（占自身宽度的比例），仅在过渡中可见
  final double slide;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        for (var i = 0; i < children.length; i++)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: i != index,
              // 只画当前页。之前靠 AnimatedOpacity 交叉淡化，两页在过渡期
              // 同时半透明，卡片和文字互相穿透，看着就是「重影」。
              // Offstage 保留 State 但不绘制，切换时只让新页从侧面滑入。
              child: Offstage(
                offstage: i != index,
                child: AnimatedSlide(
                  duration: duration,
                  curve: Curves.easeOutCubic,
                  offset: Offset(
                    i == index ? 0 : (i < index ? -slide : slide),
                    0,
                  ),
                  child: children[i],
                ),
              ),
            ),
          ),
      ],
    );
  }
}


///
/// 只在该页首次拿到数据后的 [window] 时间内播放。这样刷新/首次进入有
/// 层次感，而滚动回来重建的格子（尤其是长列表深处）不会再放一遍，
/// 避免"划回去又闪一下"。
class StaggerIn extends StatefulWidget {
  const StaggerIn({
    super.key,
    required this.index,
    required this.child,
    this.enabled = true,
    this.step = const Duration(milliseconds: 24),
    this.duration = const Duration(milliseconds: 260),
    this.offset = 10,
    this.maxIndex = 8,
  });

  final int index;

  final Widget child;

  final bool enabled;

  /// 相邻两项的启动间隔
  final Duration step;

  /// 单项动画时长（不含延迟）
  final Duration duration;

  /// 起始的向下位移（像素）
  final double offset;

  /// 超过这个序号就不做动画
  final int maxIndex;

  @override
  State<StaggerIn> createState() => _StaggerInState();
}

class _StaggerInState extends State<StaggerIn>
    with SingleTickerProviderStateMixin {
  late final bool _animate =
      widget.enabled && widget.index < widget.maxIndex;

  late final Duration _delay = widget.step * widget.index;

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _delay + widget.duration,
  );

  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Interval(
      _delay.inMicroseconds / _controller.duration!.inMicroseconds,
      1,
      curve: Curves.easeOutCubic,
    ),
  );

  @override
  void initState() {
    super.initState();
    if (_animate) {
      _controller.forward();
    } else {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_animate) {
      return widget.child;
    }
    return AnimatedBuilder(
      animation: _curve,
      child: widget.child,
      builder: (context, child) {
        final t = _curve.value;
        if (t >= 1) {
          return child!;
        }
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, widget.offset * (1 - t)),
            child: child,
          ),
        );
      },
    );
  }
}

class BlurEffect extends StatelessWidget {
  final Widget child;

  final double blur;

  final BorderRadius? borderRadius;

  const BlurEffect({
    required this.child,
    this.borderRadius,
    this.blur = 15,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.zero,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: blur,
          sigmaY: blur,
          tileMode: TileMode.mirror,
        ),
        child: child,
      ),
    );
  }
}

/// 贴边玻璃（顶栏 / 工具栏 / 底栏）：模糊 + 提饱和度 + 顶部一道柔光。
///
/// 和 [LiquidGlass] 同一套观感，但自身不着色、不描边、不投影，
/// 颜色由调用方容器决定，方便替换原来的 [BlurEffect]。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.blur = 15,
    this.saturation = 1.4,
    this.sheen = true,
    this.borderRadius,
  });

  final Widget child;

  final double blur;

  final double saturation;

  final bool sheen;

  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Widget content = child;
    if (sheen) {
      content = Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: isDark ? 0.055 : 0.12),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          child,
        ],
      );
    }
    if (borderRadius != null) {
      content = ClipRRect(borderRadius: borderRadius!, child: content);
    }
    if (blur <= 0.5) {
      return content;
    }
    Widget res = BackdropFilter(
      filter: ui.ImageFilter.blur(
        sigmaX: blur,
        sigmaY: blur,
        tileMode: TileMode.mirror,
      ),
      child: content,
    );
    if (saturation != 1.0) {
      res = ColorFiltered(
        colorFilter: ColorFilter.matrix(_saturationMatrix(saturation)),
        child: res,
      );
    }
    return res;
  }
}

/// 饱和度矩阵（1.0 = 不变，>1 更鲜艳）。
List<double> _saturationMatrix(double s) {
  const lumR = 0.213;
  const lumG = 0.715;
  const lumB = 0.072;
  final sr = (1 - s) * lumR;
  final sg = (1 - s) * lumG;
  final sb = (1 - s) * lumB;
  return <double>[
    sr + s, sg, sb, 0, 0, //
    sr, sg + s, sb, 0, 0, //
    sr, sg, sb + s, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
}

/// 液态玻璃材质（Liquid Glass）。
///
/// 相比单纯的高斯模糊 + 半透明底色，这里做了 4 层叠加来获得「玻璃」质感：
/// 1. 背景模糊 + 轻微提高饱和度（让透出的内容更通透，不会灰掉）
/// 2. 斜向的浅色渐变底色（左上有光，右下压暗）
/// 3. 左上角柔和的镜面高光
/// 4. 1px 渐变描边 + 外投影（玻璃浮在内容之上）
class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(26)),
    this.blur,
    this.opacity,
    this.tint,
    this.saturation = 1.4,
    this.shadow = true,
    this.borderWidth = 0.7,
  });

  final Widget child;

  final BorderRadius borderRadius;

  /// 模糊半径，默认取全局玻璃设置
  final double? blur;

  /// 底色不透明度，默认取全局玻璃设置
  final double? opacity;

  /// 底色，默认取主题 surface
  final Color? tint;

  /// 背景饱和度倍数
  final double saturation;

  final bool shadow;

  /// 渐变描边宽度，0 表示不描边（顶栏/底栏这类贴边的场景用 0）
  final double borderWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final blurValue = (blur ?? GlassConfig.blur).clamp(0.0, 40.0);
    final baseAlpha = (opacity ?? GlassConfig.opacity).clamp(0.05, 0.95);
    final tintColor = (tint ?? colors.surface).withValues(alpha: baseAlpha);

    Widget glass = Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.alphaBlend(
                    Colors.white.withValues(alpha: isDark ? 0.07 : 0.18),
                    tintColor,
                  ),
                  tintColor,
                  Color.alphaBlend(
                    Colors.white.withValues(alpha: isDark ? 0.02 : 0.07),
                    tintColor,
                  ),
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: const Alignment(-0.75, -1.15),
                  radius: 1.6,
                  colors: [
                    Colors.white.withValues(alpha: isDark ? 0.10 : 0.30),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );

    if (blurValue > 0.5) {
      glass = BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: blurValue,
          sigmaY: blurValue,
          tileMode: TileMode.mirror,
        ),
        child: glass,
      );
      if (saturation != 1.0) {
        glass = ColorFiltered(
          colorFilter: ColorFilter.matrix(_saturationMatrix(saturation)),
          child: glass,
        );
      }
    }

    Widget body = ClipRRect(borderRadius: borderRadius, child: glass);

    // 用外层渐变 + 内缩模拟渐变描边（BoxDecoration 的 border 不支持渐变）
    if (borderWidth > 0) {
      body = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [
                    Colors.white.withValues(alpha: 0.30),
                    Colors.white.withValues(alpha: 0.05),
                    Colors.white.withValues(alpha: 0.16),
                  ]
                : [
                    Colors.white.withValues(alpha: 0.85),
                    Colors.white.withValues(alpha: 0.28),
                    Colors.white.withValues(alpha: 0.55),
                  ],
          ),
        ),
        child: Padding(
          padding: EdgeInsets.all(borderWidth),
          child: body,
        ),
      );
    }

    if (shadow) {
      body = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.42 : 0.14),
              blurRadius: 26,
              offset: const Offset(0, 10),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.20 : 0.05),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: body,
      );
    }

    return body;
  }
}


/// 全局毛玻璃（玻璃拟态）外观配置。
///
/// 读取 设置 -> 外观 中的「glassBlur」「glassOpacity」两项，
/// 所有顶栏、底栏、阅读器工具栏都从这里取值，实现统一且可调的玻璃效果。
class GlassConfig {
  GlassConfig._();

  static const double _defaultBlur = 26;

  static const double _defaultOpacity = 0.58;

  /// 模糊半径，0 表示不模糊（等同纯色）。
  static double get blur {
    final v = appdata.settings['glassBlur'];
    if (v is num) return v.toDouble().clamp(0, 40);
    return _defaultBlur;
  }

  /// 基础不透明度（0.10 - 1.00），由百分比设置换算而来。
  static double get opacity {
    final v = appdata.settings['glassOpacity'];
    if (v is num) return (v.toDouble() / 100).clamp(0.10, 1.0);
    return _defaultOpacity;
  }

  /// 是否开启了玻璃效果（模糊为 0 且不透明度很高时关闭，省性能）。
  static bool get enabled => blur > 0.5;

  /// 取主题 surface 色并乘以透明度系数。[factor] 为 1.0 时即基准不透明度。
  static Color surface(BuildContext context, [double factor = 1.0]) {
    return Theme.of(context).colorScheme.surface.withValues(
          alpha: (opacity * factor).clamp(0.0, 1.0),
        );
  }
}
