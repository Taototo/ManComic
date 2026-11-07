# 本地补丁（基于上游 1.17.0，MIT License）

上游仓库：https://github.com/sdegenaar/liquid_glass_widgets

1. `lib/widgets/surfaces/glass_tab_bar.dart`：`GlassTabBar.bottom` 构造
   暴露 `springDescription` 参数并转发给私有构造（上游只在
   `.searchable` / `.minimizable` / 私有构造上暴露，`.bottom` 漏了）。
   我们用它把底栏滑块的弹簧从 snappy(350ms) 放慢到 bouncy(550ms)。

升级上游版本时需要重打这个补丁。
