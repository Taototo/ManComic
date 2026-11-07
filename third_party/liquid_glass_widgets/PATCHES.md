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

升级上游版本时需要重打这两个补丁。
