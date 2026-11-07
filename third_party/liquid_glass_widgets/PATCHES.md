# 本地补丁（基于上游 1.17.0，MIT License）

上游仓库：https://github.com/sdegenaar/liquid_glass_widgets

1. `lib/widgets/surfaces/glass_tab_bar.dart`：`GlassTabBar.bottom` 构造
   暴露 `springDescription` 参数并转发给私有构造（上游只在
   `.searchable` / `.minimizable` / 私有构造上暴露，`.bottom` 漏了）。
   我们用它把底栏滑块的弹簧从 snappy(350ms) 放慢到 bouncy(550ms)。

2. `lib/widgets/interactive/glass_segmented_control.dart` +
   `lib/src/widgets/interactive/segmented_control_internal.dart`：
   `GlassSegmentedControl` 暴露 `springDescription` 并转发给
   `SegmentedControlContent`，后者用它覆盖硬编码的
   `GlassSpring.snappy(350ms)`。用途同上：顶栏「推荐 / 分类」的滑块要和
   底栏同一套节奏，350ms 快到看不出滑行。

3. `lib/widgets/shared/adaptive_liquid_glass_layer.dart`：
   `useFullRenderer` 分支原来无条件把子树包进 `LiquidGlassBlendGroup`，
   现在 `blendAmount <= 0` 时直接返回子树。上游把「是否融合」只表达成
   融合距离（0 = 不融合），但那层 group 依然会跑一趟 `blendedGeometry`
   着色器 + saveLayer；在页签切换的那一帧它会画成整块纯黑（底栏「切页闪
   黑底」）。关掉之后 premium 档的折射/厚度/边缘高光都还在，只少了滑块与
   底栏轮廓互相融合那点过渡 —— 顺带省一趟全屏 pass。

升级上游版本时需要重打这三个补丁。
