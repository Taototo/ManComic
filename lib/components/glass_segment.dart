part of 'components.dart';

/// 顶栏里的「推荐 / 分类」分段切换。
///
/// 它长在玻璃顶栏之上，所以不能再给自己包一层 premium 玻璃：
///
/// - premium 档靠 `toImageSync` 把背景采样成纹理，**画面一变就可能采到空
///   纹理**，这正是之前页内分段控件「一闪而过一个黑底」的来源；
/// - 两层玻璃叠在一起时，内层采到的是外层的磨砂结果，多花一次全屏采样
///   却看不出任何区别。
///
/// 所以轨道用一层平的半透明底色（几乎不花性能），**只有滑块的玻璃**——它
/// 会折射轨道和顶栏、并且带果冻物理（横向拉伸 + 回弹），这才是「液态」的
/// 来源。档位固定在 standard：那条路走的是实时 BackdropFilter，不存在纹理
/// 为空的问题。
class GlassGroupSwitcher extends StatelessWidget {
  const GlassGroupSwitcher({
    super.key,
    required this.index,
    required this.labels,
    required this.onChanged,
  });

  final int index;

  final List<String> labels;

  final ValueChanged<int> onChanged;

  static const _height = 30.0;

  /// 单段宽度、内边距都沿用页内那版分段控件（76 × 2 + 3 × 2 = 158）。
  ///
  /// `GlassSegmentedControl` 的水平模式**不认 segmentExtent**（那个参数只对
  /// 竖排生效），宽度完全由文字撑开——所以搬到顶栏之后整块缩成一小坨，比
  /// 原来窄了一截。这里显式给死宽度，内部每段是 Expanded，自然均分。
  static const _segmentExtent = 76.0;

  static const _padding = 3.0;

  static const _width = _segmentExtent * 2 + _padding * 2;

  @override
  Widget build(BuildContext context) {
    final cs = context.colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SizedBox(
      width: _width,
      child: lg.GlassSegmentedControl(
        segments: [
          for (final label in labels) lg.GlassSegment(label: label.tl),
        ],
        selectedIndex: index,
        onSegmentSelected: onChanged,
        height: _height,
        segmentExtent: _segmentExtent,
        padding: const EdgeInsets.all(_padding),
        borderRadius: _height / 2,
        // 轨道：在玻璃顶栏上再压半档，让「当前有两个选项」看得出来。
        backgroundColor: cs.onSurface.withValues(alpha: isDark ? 0.24 : 0.07),
        // 滑块交给玻璃自己画：不指定实色，否则会在玻璃上面再糊一层死色。
        indicatorColor: LiquidGlassEngine.enabled ? null : cs.surface,
        indicatorSettings: LiquidGlassEngine.enabled
            ? LiquidGlassEngine.settings(
                context,
                tintAlpha: isDark ? 0.42 : 0.5,
              )
            : null,
        // 只有这一层玻璃，档位压到 standard：实时采样，不会闪黑。
        quality: lg.GlassQuality.standard,
        // 滑块比轨道内沿略微外扩，边缘的折射才露得出来。
        indicatorExpansion: const EdgeInsets.symmetric(
          horizontal: 1,
          vertical: 1,
        ),
        indicatorPinchStrength: 0.45,
        // 包内默认 snappy(350ms) 快到看不出滑行，和底栏一样放慢到 bouncy。
        springDescription: LiquidGlassEngine.indicatorSpring,
        // 文字压在玻璃上，颜色必须显式给：不依赖着色器猜亮度。
        selectedTextStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: cs.primary,
        ),
        unselectedTextStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: cs.onSurface.withValues(alpha: 0.62),
        ),
      ),
    );
  }
}
