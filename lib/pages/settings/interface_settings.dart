part of 'settings_page.dart';

/// 界面：所有「看起来怎么样」的设置。
///
/// 原来的分类里，主题和应用图标在「外观」，缩略图 / 网格 / 尺寸在「探索」，
/// 首页模块又回到「外观」——同一件事被拆到两个页面，找起来只能靠猜。这里
/// 按「影响屏幕上的什么」重新收拢：主题与材质、首页、列表里的缩略图。
class InterfaceSettings extends StatelessWidget {
  const InterfaceSettings({super.key});

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Interface".tl)),
        _SettingPartTitle(title: "Theme".tl, icon: Icons.palette_outlined),
        SelectSetting(
          title: "Theme Mode".tl,
          settingKey: "theme_mode",
          optionTranslation: {
            "system": "System".tl,
            "light": "Light".tl,
            "dark": "Dark".tl,
          },
          onChanged: () async {
            App.forceRebuild();
          },
        ).toSliver(),
        SelectSetting(
          title: "Theme Color".tl,
          settingKey: "color",
          optionTranslation: {
            "system": "System".tl,
            "red": "Red".tl,
            "pink": "Pink".tl,
            "purple": "Purple".tl,
            "green": "Green".tl,
            "orange": "Orange".tl,
            "blue": "Blue".tl,
          },
          onChanged: () async {
            await App.init();
            App.forceRebuild();
          },
        ).toSliver(),
        _SettingPartTitle(title: "App icon".tl, icon: Icons.apps_rounded),
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Pick the icon shown on your home screen. The change takes effect after the app restarts."
                    .tl,
                style: ts.s12,
              ).paddingHorizontal(16).paddingTop(10),
              const SizedBox(height: 2),
              const _AppIconPicker(),
            ],
          ),
        ),
        _SettingPartTitle(
          title: "Glass effect".tl,
          icon: Icons.blur_on_rounded,
        ),
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Adjust the frosted glass blur and opacity of app bars and reader toolbars."
                    .tl,
                style: ts.s12,
              ).paddingHorizontal(16).paddingTop(10),
              const _GlassPreview(),
            ],
          ),
        ),
        _SliderSetting(
          title: "Glass Blur".tl,
          settingsIndex: "glassBlur",
          interval: 2,
          min: 0,
          max: 40,
          onChanged: () {
            App.forceRebuild();
          },
        ).toSliver(),
        _SliderSetting(
          title: "${"Glass Opacity".tl} (%)",
          settingsIndex: "glassOpacity",
          interval: 5,
          min: 10,
          max: 95,
          onChanged: () {
            App.forceRebuild();
          },
        ).toSliver(),
        SliverToBoxAdapter(
          child: Text(
            "Lower opacity makes the glass more transparent. Set blur to 0 to disable the frosted effect."
                .tl,
            style: ts.s12,
          ).paddingHorizontal(16).paddingBottom(12),
        ),
        _SettingPartTitle(title: "Home".tl, icon: Icons.home_outlined),
        _CallbackSetting(
          title: "Home Modules".tl,
          subtitle: "Reorder or hide sections on the home page".tl,
          actionTitle: "Edit".tl,
          callback: () {
            context.to(() => const HomeModulesPage());
          },
        ).toSliver(),
        _SettingPartTitle(
          title: "Comic tiles".tl,
          icon: Icons.grid_view_rounded,
        ),
        SelectSetting(
          title: "Display mode of comic tile".tl,
          settingKey: "comicDisplayMode",
          optionTranslation: {
            "detailed": "Detailed".tl,
            "brief": "Brief".tl,
          },
        ).toSliver(),
        SelectSetting(
          title: "Layout mode of comic grid".tl,
          settingKey: "comicLayoutMode",
          optionTranslation: {
            "grid": "Grid Layout".tl,
            "staggered": "Staggered Layout".tl,
          },
        ).toSliver(),
        SelectSetting(
          title: "Display mode of comic list".tl,
          settingKey: "comicListDisplayMode",
          optionTranslation: {
            "paging": "Paging".tl,
            "Continuous": "Continuous".tl,
          },
        ).toSliver(),
        _SliderSetting(
          title: "Size of comic tile".tl,
          settingsIndex: "comicTileScale",
          interval: 0.05,
          min: 0.5,
          max: 1.5,
        ).toSliver(),
        _SwitchSetting(
          title: "Show favorite status on comic tile".tl,
          settingKey: "showFavoriteStatusOnTile",
        ).toSliver(),
        _SwitchSetting(
          title: "Show history on comic tile".tl,
          settingKey: "showHistoryStatusOnTile",
        ).toSliver(),
      ],
    );
  }
}

/// 内置应用图标选择器：点选后直接切换桌面 launcher 图标。
class _AppIconPicker extends StatefulWidget {
  const _AppIconPicker();

  @override
  State<_AppIconPicker> createState() => _AppIconPickerState();
}

class _AppIconPickerState extends State<_AppIconPicker> {
  late String selected = AppIcon.currentKey;

  bool busy = false;

  Future<void> onSelect(String key) async {
    if (busy || key == selected) {
      return;
    }
    final previous = selected;
    setState(() {
      busy = true;
      selected = key;
    });
    final ok = await AppIcon.apply(key);
    if (!mounted) {
      return;
    }
    setState(() {
      busy = false;
      if (!ok) {
        selected = previous;
      }
    });
    if (!ok) {
      showToast(context: context, message: "Failed to change icon".tl);
      return;
    }
    if (!App.isAndroid) {
      showToast(context: context, message: "Icon changed".tl);
      return;
    }
    // 图标切换要等下次启动才生效：运行中改 launcher 组件会让部分系统直接杀掉当前任务
    showDialog(
      context: context,
      builder: (dialogContext) => ContentDialog(
        title: "Icon Saved".tl,
        content: Text(
          "The launcher icon will be updated the next time the app starts. "
                  "Restart later, or close the app now to apply it."
              .tl,
        ).paddingHorizontal(16).paddingVertical(8),
        actions: [
          TextButton(
            onPressed: () {
              dialogContext.pop();
              AppIcon.closeAndApply();
            },
            child: Text("Restart Now".tl),
          ),
          // 默认动作：稍后重启
          FilledButton(
            onPressed: () => dialogContext.pop(),
            child: Text("Restart Later".tl),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 4,
      runSpacing: 10,
      children: appIconOptions.map((option) {
        final active = option.key == selected;
        return SizedBox(
          width: 64,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => onSelect(option.key),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(15),
                      border: Border.all(
                        width: active ? 2 : 1,
                        color: active
                            ? colors.primary
                            : colors.outlineVariant.toOpacity(0.8),
                      ),
                    ),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.asset(
                            option.asset,
                            width: 50,
                            height: 50,
                            filterQuality: FilterQuality.medium,
                          ),
                        ),
                        if (active)
                          Positioned(
                            right: -4,
                            bottom: -4,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: colors.primary,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: colors.surface,
                                  width: 1.6,
                                ),
                              ),
                              child: Icon(
                                Icons.check,
                                size: 9,
                                color: colors.onPrimary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    option.name.tl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts.s10.withColor(
                      active ? colors.primary : colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    ).paddingHorizontal(8).paddingBottom(8);
  }
}

/// 毛玻璃效果实时预览：一段彩色渐变 + 盖在上面的玻璃条。
class _GlassPreview extends StatelessWidget {
  const _GlassPreview();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 88,
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF6FA8FF),
            Color(0xFFB07CFF),
            Color(0xFFFF9A63),
          ],
        ),
      ),
      child: Stack(
        children: [
          Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.auto_awesome,
                  size: 18,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
                const SizedBox(width: 6),
                Text(
                  "Preview".tl,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: BlurEffect(
              blur: GlassConfig.blur,
              child: Container(
                height: 40,
                color: GlassConfig.surface(context),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(
                      Icons.arrow_back,
                      size: 20,
                      color: context.colorScheme.onSurface,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        "ManComic",
                        style: ts.s16.bold,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      Icons.more_horiz,
                      size: 20,
                      color: context.colorScheme.onSurface,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
