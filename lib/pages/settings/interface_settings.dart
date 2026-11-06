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
        // 只有 Android 有「向系统申请帧率」这条路：桌面和 iOS 不提供这个
        // 通道，显示出来只会是一个点了没反应的选项。
        if (App.isAndroid) ...[
          _SettingPartTitle(title: "Display".tl, icon: Icons.speed_rounded),
          // 高刷屏上应用跑 60 帧是最常见的「莫名不跟手」来源：不少 ROM 会给
          // 非白名单应用锁 60Hz。这里让用户能手动钉住一档，也方便对比耗电。
          SelectSetting(
            title: "Refresh Rate".tl,
            settingKey: "refreshRate",
            optionTranslation: {
              "auto": "Auto".tl,
              "60": "60 Hz",
              "90": "90 Hz",
              "120": "120 Hz",
            },
            help: "Auto uses the highest rate the screen supports. Lower rates "
                    "save battery; higher rates make scrolling smoother."
                .tl,
            onChanged: () async {
              await DisplayRefresh.apply(appdata.settings['refreshRate']);
            },
          ).toSliver(),
          _SwitchSetting(
            title: "Show frame rate".tl,
            subtitle:
                "Live fps, frame times and dropped frames in the corner".tl,
            settingKey: "showFps",
            onChanged: () {
              App.forceRebuild();
            },
          ).toSliver(),
          SliverToBoxAdapter(child: const _ScreenInfo()),
        ],
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
        _SettingPartTitle(title: "Home".tl, icon: Icons.home_outlined),
        // 启动落在哪一页是首页的一部分，之前被塞在「功能 > 其他」里，
        // 找的人不会想到去那儿。
        SelectSetting(
          title: "Initial Page".tl,
          settingKey: "initialPage",
          optionTranslation: {
            '0': "Home Page".tl,
            '1': "Explore Page".tl,
            '2': "Categories Page".tl,
            '3': "Favorites Page".tl,
          },
        ).toSliver(),
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
        // 语言原来在「功能 > 其他」——那个分组是个垃圾桶，什么都能往里扔。
        // 改界面上的文字属于界面，和主题、缩略图是同一类事。
        _SettingPartTitle(
          title: "Language".tl,
          icon: Icons.translate_rounded,
        ),
        SelectSetting(
          title: "Language".tl,
          settingKey: "language",
          optionTranslation: const {
            "system": "System",
            "zh-CN": "简体中文",
            "zh-TW": "繁體中文",
            "en-US": "English",
          },
          onChanged: () {
            App.forceRebuild();
          },
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

/// 屏幕刷新率读数。
///
/// 只查一次（在 initState 里发起），不要放在 build 里现取：那会让每次重建
/// 都发一次平台调用，而 FutureBuilder 拿到新 Future 又会触发重建，转起来
/// 就是无限循环。
class _ScreenInfo extends StatefulWidget {
  const _ScreenInfo();

  @override
  State<_ScreenInfo> createState() => _ScreenInfoState();
}

class _ScreenInfoState extends State<_ScreenInfo> {
  late final Future<void> _future = DisplayRefresh.refreshInfo();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: _future,
      builder: (context, _) {
        // 屏幕实际是多少就写多少：用户申请 120 但系统只给 60 时，
        // 这一行能直接说明是应用没申请到，还是屏幕本来就不支持。
        final rates = DisplayRefresh.supportedRates
            .map((e) => e.toStringAsFixed(0))
            .join(" / ");
        final active = DisplayRefresh.refreshRate.toStringAsFixed(0);
        return Text(
          "Screen: @rate Hz (supported: @list Hz)"
              .tlParams({"rate": active, "list": rates}),
          style: ts.s12,
        ).paddingHorizontal(16).paddingBottom(12);
      },
    );
  }
}
