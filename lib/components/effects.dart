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
  late final bool _animate = widget.enabled && widget.index < widget.maxIndex;

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
    this.highlight = 1.0,
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

  /// 镜面高光的强度倍数。
  ///
  /// 顶栏/底栏浮在滚动内容上，高光重一点才「亮」；但列表里的普通卡片如果照
  /// 这个强度打，两层白一叠就把底色洗成实心白，背后的色斑全被盖掉——玻璃感
  /// 反而没了。所以给出这个旋钮，卡片用小值。
  final double highlight;

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
                    Colors.white.withValues(
                      alpha: (isDark ? 0.07 : 0.18) * highlight,
                    ),
                    tintColor,
                  ),
                  tintColor,
                  Color.alphaBlend(
                    Colors.white.withValues(
                      alpha: (isDark ? 0.02 : 0.07) * highlight,
                    ),
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
                    Colors.white.withValues(
                      alpha: (isDark ? 0.10 : 0.30) * highlight,
                    ),
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

/// 页面自己的那层背景（surface 底 + 色斑）。
///
/// 液态主题里所有页面都是透明的：`scaffoldBackgroundColor` 和 `canvasColor`
/// 都被改成了透明，好让玻璃卡片透出底下的色斑。但「透明」意味着**能看穿到
/// 下面那一页**——转场时两页同时存在，新页的空白处直接露出旧页的文字和封面，
/// 用户看到的就是「两层内容叠在一起」。
///
/// 所以每一页都必须自己带一层**不透明**的视觉底。底是和全局背景一模一样的一套
/// 色斑，看起来还是同一块背景，但它在页面内部，页面盖住页面时是实打实地盖住。
///
/// 这正是 iOS 液态玻璃的做法：玻璃只对「本页的内容」模糊，不是对「上一页」。
class AppPageBackground extends StatelessWidget {
  const AppPageBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!LiquidTheme.isOn(context)) {
      return child;
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        const GlassPageBackdrop(),
        child,
      ],
    );
  }
}

/// 页面级的背景光斑，给液态玻璃提供「后面有东西」的环境。
///
/// 玻璃的本质是模糊它下面的内容。如果页面底色是一块纯色，模糊完还是纯色，
/// 卡片就只剩描边和高光，看着像一片塑料。这里铺两三个大范围的低饱和色斑，
/// 玻璃从色斑上方经过时才有折射感，卡片之间也会因为底色不同而分出层次。
///
/// 只该放在 `Stack` 的最底层，且必须 `Positioned.fill`。
class GlassPageBackdrop extends StatelessWidget {
  const GlassPageBackdrop({super.key, this.intensity = 1.0});

  /// 整体浓淡，1.0 为默认。背景本身很花（比如漫画封面墙）时调低。
  final double intensity;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? 1.6 : 1.0;
    // 色斑要「角落浓、中间空」，不能铺满一屏。
    //
    // 第一版按角落 alpha 0.28 + 超大半径铺，结果每个像素都被染了一点，整屏变成
    // 一块均匀的灰蓝——看上去像配错了底色，而不是玻璃底下有光。玻璃成立的前提
    // 是**同一屏里既有被染色区、又有干净区**，卡片跨过交界时才看得出「隔着玻璃」。
    // 所以半径收到 1.0 附近让颜色在出来之前就衰减掉，浓度相应提到 0.6 才够显眼。
    return IgnorePointer(
      child: RepaintBoundary(
        child: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: colors.surface)),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-1.0, -1.05),
                    radius: 1.05,
                    colors: [
                      colors.primary.withValues(
                        alpha: (isDark ? 0.55 : 0.44) * intensity * base,
                      ),
                      colors.primary.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(1.05, 1.0),
                    radius: 1.0,
                    colors: [
                      colors.tertiary.withValues(
                        alpha: (isDark ? 0.45 : 0.34) * intensity * base,
                      ),
                      colors.tertiary.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(1.0, -0.85),
                    radius: 0.72,
                    colors: [
                      colors.secondary.withValues(
                        alpha: (isDark ? 0.38 : 0.26) * intensity * base,
                      ),
                      colors.secondary.withValues(alpha: 0.0),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
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

/// 界面风格。`material` 是默认外观（保持原样），`liquid` 是液态主题。
const String themeStyleMaterial = 'material';

const String themeStyleLiquid = 'liquid';

/// 当前选中的界面风格。设置里写坏的值一律按默认外观处理。
String get appThemeStyle =>
    appdata.settings['themeStyle'] == themeStyleLiquid
        ? themeStyleLiquid
        : themeStyleMaterial;

bool get isLiquidTheme => appThemeStyle == themeStyleLiquid;

/// 液态主题开关，经 [ThemeExtension] 下发。
///
/// 为什么不用全局读 appdata：组件在 `Theme.of(context)` 里拿到的才是「当前这棵
/// 树实际生效的」主题。设置页切换风格时 `App.forceRebuild()` 会重建整棵树，
/// extension 跟着新 ThemeData 一起换掉；而直接读 appdata 的组件在动画/过渡期间
/// 会读到新值却仍画在旧主题上，出现半玻璃半实心的瞬间。也方便测试里塞一个
/// 假主题验证两种分支。
@immutable
class LiquidTheme extends ThemeExtension<LiquidTheme> {
  const LiquidTheme({required this.enabled});

  static const LiquidTheme off = LiquidTheme(enabled: false);

  static const LiquidTheme on = LiquidTheme(enabled: true);

  final bool enabled;

  static bool isOn(BuildContext context) =>
      Theme.of(context).extension<LiquidTheme>()?.enabled ?? false;

  @override
  LiquidTheme copyWith({bool? enabled}) =>
      LiquidTheme(enabled: enabled ?? this.enabled);

  @override
  LiquidTheme lerp(covariant LiquidTheme? other, double t) {
    if (other == null || other.enabled == enabled) {
      return this;
    }
    return t < 0.5 ? this : other;
  }
}

/// 液态主题的配色：把「容器」类表面改成半透明，让页面底下的色斑透上来。
///
/// 这么做而不是逐个改页面，是因为全站有 40 多处容器直接取
/// `surfaceContainerLow`。改配色表一次，所有还没单独适配的地方立刻不再是
/// 一块死色，观感统一；需要更精致玻璃的位置再逐个换成 [AppSurface]。
///
/// `surface` 本身保持不透明：贴边栏、遮罩层、图片占位底色都取它，一旦透掉
/// 底下的内容会穿上来。层次越高的容器越不透明，维持原本的「浮起」关系。
ColorScheme liquidColorScheme(ColorScheme base) {
  Color glass(Color c, double alpha) => c.withValues(alpha: alpha);
  return base.copyWith(
    surfaceContainerLowest: glass(base.surfaceContainerLowest, 0.52),
    surfaceContainerLow: glass(base.surfaceContainerLow, 0.62),
    surfaceContainer: glass(base.surfaceContainer, 0.68),
    surfaceContainerHigh: glass(base.surfaceContainerHigh, 0.74),
    surfaceContainerHighest: glass(base.surfaceContainerHighest, 0.80),
  );
}

/// 统一卡片表面。
///
/// 默认主题下就是原来到处在写的那块
/// `surfaceContainerLow + outlineVariant 细边 + 圆角`；液态主题下换成**静态
/// 玻璃**——半透明底 + 斜向高光 + 1px 渐变描边，但**不做 BackdropFilter**。
///
/// 这一点是关键：列表里同时可见的卡片可能十几张，每张都挂一个 BackdropFilter
/// 就是每帧十几次全屏重采样，帧率立刻塌。玻璃观感来自「透出下面的色斑」，
/// 静态玻璃同样能透（半透明底），只是不做实时模糊——iOS 自己的液态玻璃里，
/// 只有盖在滚动内容上的浮层才真模糊，普通卡片也是静态材质。
class AppSurface extends StatelessWidget {
  const AppSurface({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.padding,
    this.margin,
    this.color,
    this.border,
    this.onTap,
    this.clip = false,
    this.shadow = true,
  });

  final Widget child;

  final BorderRadius borderRadius;

  final EdgeInsetsGeometry? padding;

  final EdgeInsetsGeometry? margin;

  /// 覆盖底色。液态主题下会作为玻璃的着色层。
  final Color? color;

  /// 覆盖描边。默认是 outlineVariant 半透明细边。
  final BoxBorder? border;

  final VoidCallback? onTap;

  final bool clip;

  /// 液态主题下的投影。嵌套在别的卡片里的小块可以关掉。
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final liquid = LiquidTheme.isOn(context);

    Widget content = padding == null
        ? child
        : Padding(padding: padding!, child: child);

    // 水波纹要画在玻璃之上。Material 必须是玻璃的**子节点**：外层 Material 的
    // ink 会画在背景之下，隔着不透明（或半透明）玻璃完全看不见。
    if (onTap != null) {
      content = Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: borderRadius,
          onTap: onTap,
          child: content,
        ),
      );
    }

    Widget surface = liquid
        ? LiquidGlass(
            borderRadius: borderRadius,
            blur: 0,
            // 卡片不做模糊，但底要够透：0.62 时叠在白底上几乎是一块实心浅灰，
            // 背景的色斑完全被盖住，看起来就是「换了个浅色主题」而不是玻璃。
            // 0.42 时角落的蓝紫能明显透上来，字仍然清楚（底下是浅色环境）。
            opacity: 0.42,
            tint: color,
            shadow: shadow,
            highlight: 0.55,
            child: content,
          )
        : Container(
            decoration: BoxDecoration(
              color: color ?? colors.surfaceContainerLow,
              borderRadius: borderRadius,
              border: border ??
                  Border.all(
                    color: colors.outlineVariant.withValues(alpha: 0.45),
                    width: 0.6,
                  ),
            ),
            child: content,
          );

    if (clip) {
      surface = ClipRRect(borderRadius: borderRadius, child: surface);
    }
    if (margin != null) {
      surface = Padding(padding: margin!, child: surface);
    }
    return surface;
  }
}

/// 液态主题下的「按压回弹」。
///
/// iOS 26 的液态玻璃控件按下时不是变暗，而是**先胀开一点、松手再弹回**——
/// 像一块果冻被指尖压了一下又回位。这里用两段动画复刻：
///
/// - 按下：110ms `easeOut` 到 [scale]，快，跟手；
/// - 松开：380ms `elasticOut` 回 1.0，中途会冲过 1.0 再荡回来，这一下「涟
///   漪」是液态感的来源，用普通 `easeOut` 只会是一次平淡的收缩。
///
/// 默认主题下直接返回 child，不做任何包装——这是「新主题」，不该动老外观。
class LiquidPressable extends StatefulWidget {
  const LiquidPressable({
    super.key,
    required this.child,
    this.scale = 1.06,
    this.enabled = true,
  });

  final Widget child;

  /// 按下时放大到多少。大按钮用小一点（1.03），小块用大一点（1.08）。
  final double scale;

  /// 交给外层手势控制。按钮自己正在处理 loading 时就不该再弹。
  final bool enabled;

  @override
  State<LiquidPressable> createState() => _LiquidPressableState();
}

class _LiquidPressableState extends State<LiquidPressable> {
  bool _down = false;

  void _set(bool v) {
    if (!widget.enabled || _down == v) return;
    setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    if (!LiquidTheme.isOn(context)) return widget.child;
    return Listener(
      // 用 Listener 而不是 GestureDetector：按钮自己已经有 InkWell 在抢点击，
      // 再套一层手势会互相吃掉，表现成「按下没反应」。Listener 只旁听指针，
      // 不参与手势竞技场。
      //
      // behavior 必须是 opaque：默认的 deferToChild 会一路问到最里面那层，
      // 玻璃按钮内部是透明的 Material，指针可能直接穿过去收不到。
      behavior: HitTestBehavior.opaque,
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedScale(
        scale: _down ? widget.scale : 1.0,
        duration: _down
            ? const Duration(milliseconds: 110)
            : const Duration(milliseconds: 380),
        curve: _down ? Curves.easeOut : Curves.elasticOut,
        child: widget.child,
      ),
    );
  }
}

/// 液态主题下的玻璃胶囊按钮。
///
/// 详情页的 Read / Continue / Download 这类主操作。默认主题下退回 [FilledButton]
/// 的等效外观（实心主色 / tonal 色），保证不切主题时一模一样。
class LiquidGlassButton extends StatelessWidget {
  const LiquidGlassButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.tonal = false,
    this.height = 44,
  });

  final Widget child;

  final VoidCallback? onPressed;

  /// tonal 是次要操作（下载），用更淡的着色；否则是主操作（开始阅读）。
  final bool tonal;

  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final radius = BorderRadius.circular(height / 2);

    if (!LiquidTheme.isOn(context)) {
      final label = DefaultTextStyle.of(context).style.merge(
            TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: enabled
                  ? (tonal ? colors.onSecondaryContainer : colors.onPrimary)
                  : colors.onSurface.withValues(alpha: 0.38),
            ),
          );
      return SizedBox(
        height: height,
        child: Material(
          color: enabled
              ? (tonal ? colors.secondaryContainer : colors.primary)
              : colors.onSurface.withValues(alpha: 0.12),
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: onPressed,
            child: Center(child: DefaultTextStyle(style: label, child: child)),
          ),
        ),
      );
    }

    // 液态：主操作用主色薄薄地给玻璃上色，次要操作用中性玻璃。都不做实时
    // 模糊——它们和卡片同时可见，逐个挂 BackdropFilter 会把帧率拖垮。
    final tint = tonal ? colors.surface : colors.primary;

    return LiquidPressable(
      scale: 1.04,
      enabled: enabled,
      child: SizedBox(
        height: height,
        child: LiquidGlass(
          borderRadius: radius,
          blur: 0,
          // 主操作也留一点通透：0.72 时能感觉到主色底下有东西，但不是
          // 「半透明按钮」那种看不清的状态；全不透明就跟没换主题一样了。
          opacity: tonal ? 0.34 : 0.72,
          tint: tint,
          shadow: false,
          highlight: tonal ? 0.6 : 1.4,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: radius,
              onTap: onPressed,
              child: Center(
                child: DefaultTextStyle(
                  style: DefaultTextStyle.of(context).style.merge(
                        TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: tonal ? colors.onSurface : colors.onPrimary,
                        ),
                      ),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
