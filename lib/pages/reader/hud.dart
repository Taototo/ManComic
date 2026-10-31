part of 'reader.dart';

/// 阅读页长按唤出的快捷面板（HUD）。
///
/// 提供亮度（直接控制本应用窗口亮度，退出阅读页后恢复跟随系统）、阅读模式切换、
/// 以及章节/设置/收藏图片/锁定四个常用动作，避免每次都走进设置页。
class _ReaderHud extends StatefulWidget {
  const _ReaderHud({required this.onLock});

  final VoidCallback onLock;

  @override
  State<_ReaderHud> createState() => _ReaderHudState();
}

class _ReaderHudState extends State<_ReaderHud> {
  /// 当前亮度（0.01 - 1.0），null 表示尚未读取到
  double? _brightness;

  @override
  void initState() {
    super.initState();
    _loadBrightness();
  }

  Future<void> _loadBrightness() async {
    final value = await ScreenBrightness.get();
    if (!mounted) return;
    setState(() {
      _brightness = value;
    });
  }

  /// 直接设置窗口亮度，不再和系统亮度做倍数换算
  void _setBrightness(double value) {
    setState(() {
      _brightness = value;
    });
    ScreenBrightness.set(value);
  }

  void _setMode(ReaderMode mode) {
    final reader = context.reader;
    if (reader.mode == mode) {
      return;
    }
    reader.mode = mode;
    appdata.settings['readerMode'] = mode.key;
    if (appdata.settings.isComicSpecificSettingsEnabled(
      reader.cid,
      reader.type.sourceKey,
    )) {
      appdata.settings.setReaderSetting(
        reader.cid,
        reader.type.sourceKey,
        'readerMode',
        mode.key,
      );
    }
    appdata.saveData();
    reader.update();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return LiquidGlass(
      borderRadius: BorderRadius.circular(24),
      opacity: 0.82,
      tint: colors.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildBrightnessRow(colors),
            const SizedBox(height: 2),
            Row(
              children: [
                _modeButton(
                  ReaderMode.galleryLeftToRight,
                  Icons.view_carousel_outlined,
                  "Left to Right",
                ),
                _modeButton(
                  ReaderMode.galleryRightToLeft,
                  Icons.view_carousel,
                  "Right to Left",
                ),
                _modeButton(
                  ReaderMode.galleryTopToBottom,
                  Icons.view_day_outlined,
                  "Top to Bottom",
                ),
                _modeButton(
                  ReaderMode.continuousTopToBottom,
                  Icons.view_agenda_outlined,
                  "Webtoon",
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _actionButton(
                  Icons.list,
                  "Chapters",
                  () {
                    context.readerScaffold.closeHud();
                    context.readerScaffold.openChapterDrawer();
                  },
                ),
                _actionButton(
                  Icons.bookmark_add_outlined,
                  "Collect",
                  () {
                    context.readerScaffold.closeHud();
                    context.readerScaffold.addImageFavorite();
                  },
                ),
                _actionButton(
                  Icons.tune,
                  "Settings",
                  () {
                    context.readerScaffold.closeHud();
                    context.readerScaffold.openSetting();
                  },
                ),
                _actionButton(
                  Icons.lock_outline,
                  "Lock",
                  () {
                    context.readerScaffold.closeHud();
                    widget.onLock();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrightnessRow(ColorScheme colors) {
    final value = _brightness;
    if (!ScreenBrightness.isSupported) {
      return const SizedBox.shrink();
    }
    final percent = ((value ?? 0.5) * 100).round();
    return Row(
      children: [
        Icon(
          value == null
              ? Icons.brightness_6_outlined
              : percent < 40
              ? Icons.brightness_low_rounded
              : percent < 75
              ? Icons.brightness_medium_rounded
              : Icons.brightness_high_rounded,
          size: 18,
          color: colors.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Text("Brightness".tl, style: ts.s12),
        Expanded(
          child: Slider(
            value: (value ?? 0.5).clamp(0.01, 1.0),
            min: 0.01,
            max: 1.0,
            onChanged: value == null ? null : _setBrightness,
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            "$percent%",
            textAlign: TextAlign.right,
            style: ts.s10.withColor(colors.onSurfaceVariant),
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          iconSize: 16,
          tooltip: "Eye comfort".tl,
          icon: Icon(
            _warmOn ? Icons.visibility_rounded : Icons.visibility_off_outlined,
            color: _warmOn ? colors.primary : colors.onSurfaceVariant,
          ),
          onPressed: _toggleWarm,
        ),
      ],
    );
  }

  bool get _warmOn =>
      ((appdata.settings['readerWarmFilter'] as num?)?.toDouble() ?? 0) > 0;

  /// 快捷开关护眼暖色；手动打开时同时关闭「仅夜间」，避免白天点了没反应
  void _toggleWarm() {
    if (_warmOn) {
      appdata.settings['readerWarmFilter'] = 0;
    } else {
      appdata.settings['readerWarmFilter'] = 35;
      appdata.settings['readerWarmFilterAuto'] = false;
    }
    appdata.saveData();
    context.readerScaffold.refreshWarmFilter();
    setState(() {});
  }

  Widget _modeButton(ReaderMode mode, IconData icon, String label) {
    final active = context.reader.mode == mode;
    final colors = context.colorScheme;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _setMode(mode),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active
                ? colors.primary.withValues(alpha: 0.18)
                : colors.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: active
                  ? colors.primary.withValues(alpha: 0.8)
                  : colors.outlineVariant.withValues(alpha: 0.4),
              width: active ? 1.2 : 0.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 20,
                color: active ? colors.primary : colors.onSurfaceVariant,
              ),
              const SizedBox(height: 4),
              Text(
                label.tl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ts.s8.withColor(
                  active ? colors.primary : colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionButton(IconData icon, String label, VoidCallback onTap) {
    final colors = context.colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: colors.onSurface),
            const SizedBox(height: 4),
            Text(label.tl, style: ts.s10.withColor(colors.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
