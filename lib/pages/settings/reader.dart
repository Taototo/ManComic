part of 'settings_page.dart';

class ReaderSettings extends StatefulWidget {
  const ReaderSettings({
    super.key,
    this.onChanged,
    this.comicId,
    this.comicSource,
    this.showGestures = true,
  });

  final void Function(String key)? onChanged;
  final String? comicId;
  final String? comicSource;

  /// 是否把「手势」分组画在本页末尾。
  ///
  /// 阅读器里弹出的设置面板要在一页里看全，所以默认画；设置页把它们拆到了
  /// 「操作」分类，那边传 false，避免同一个开关出现两遍。
  final bool showGestures;

  @override
  State<ReaderSettings> createState() => _ReaderSettingsState();
}

class _ReaderSettingsState extends State<ReaderSettings> {
  bool _isChapterCommentsAtEndSupported() {
    String? readerMode;
    bool? showChapterComments;

    if (widget.comicId != null &&
        widget.comicSource != null &&
        appdata.settings.isComicSpecificSettingsEnabled(
          widget.comicId,
          widget.comicSource,
        )) {
      readerMode = appdata.settings.getReaderSetting(
        widget.comicId!,
        widget.comicSource!,
        'readerMode',
      );
      showChapterComments = appdata.settings.getReaderSetting(
        widget.comicId!,
        widget.comicSource!,
        'showChapterComments',
      );
    } else {
      readerMode = appdata.settings['readerMode'] as String?;
      showChapterComments = appdata.settings['showChapterComments'] as bool?;
    }

    // Must have showChapterComments enabled and be in gallery mode
    if (showChapterComments != true) return false;

    return readerMode == 'galleryLeftToRight' ||
        readerMode == 'galleryRightToLeft';
  }

  void _onShowChapterCommentsChanged() {
    // When showChapterComments is turned off, also turn off showChapterCommentsAtEnd
    bool? showChapterComments;

    if (widget.comicId != null &&
        widget.comicSource != null &&
        appdata.settings.isComicSpecificSettingsEnabled(
          widget.comicId,
          widget.comicSource,
        )) {
      showChapterComments = appdata.settings.getReaderSetting(
        widget.comicId!,
        widget.comicSource!,
        'showChapterComments',
      );
      if (showChapterComments != true) {
        appdata.settings.setReaderSetting(
          widget.comicId!,
          widget.comicSource!,
          'showChapterCommentsAtEnd',
          false,
        );
      }
    } else {
      showChapterComments = appdata.settings['showChapterComments'] as bool?;
      if (showChapterComments != true) {
        appdata.settings['showChapterCommentsAtEnd'] = false;
      }
    }

    setState(() {});
    widget.onChanged?.call("showChapterComments");
  }

  @override
  Widget build(BuildContext context) {
    final comicId = widget.comicId;
    final sourceKey = widget.comicSource;
    final key = "$comicId@$sourceKey";

    // 读写走同一套优先级：漫画专属 > 设备专属 > 全局。规则在
    // [_ReaderSettingScope] 里，手势分组也用它，两边不会走偏。
    final scope = _ReaderSettingScope(
      comicId: comicId,
      comicSource: sourceKey,
    );
    final isEnabledSpecificSettings = scope.comicSpecific;
    final useDeviceSpecificSettings = scope.deviceSpecific;
    final read = scope.read;
    final write = scope.write;

    final specificComicId = isEnabledSpecificSettings ? widget.comicId : null;
    final specificComicSource =
        isEnabledSpecificSettings ? widget.comicSource : null;

    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Reading".tl)),
        if (comicId != null && sourceKey != null)
          SliverMainAxisGroup(
            slivers: [
              SwitchListTile(
                contentPadding: kSettingTilePadding,
                title: Text("Enable comic specific settings".tl),
                value: isEnabledSpecificSettings,
                onChanged: (b) {
                  setState(() {
                    appdata.settings.setEnabledComicSpecificSettings(
                      comicId,
                      sourceKey,
                      b,
                    );
                  });
                },
              ).toSliver(),
              if (isEnabledSpecificSettings)
                Center(
                  child: TextButton(
                    onPressed: () {
                      setState(() {
                        appdata.settings.resetComicReaderSettings(key);
                      });
                    },
                    child: Text(
                      "Clear specific reader settings for this comic".tl,
                    ),
                  ),
                ).toSliver(),
              Divider().toSliver(),
            ],
          ),
        if (comicId == null)
          SliverMainAxisGroup(
            slivers: [
              SwitchListTile(
                contentPadding: kSettingTilePadding,
                title: Text("Enable device specific settings".tl),
                value: useDeviceSpecificSettings,
                onChanged: (b) {
                  setState(() {
                    appdata.settings.setEnabledDeviceSpecificSettings(b);
                  });
                  appdata.saveData();
                },
              ).toSliver(),
              if (useDeviceSpecificSettings)
                Center(
                  child: TextButton(
                    onPressed: () {
                      setState(() {
                        appdata.settings.resetDeviceReaderSettings();
                      });
                      appdata.saveData();
                    },
                    child: Text(
                      "Clear specific reader settings for this device".tl,
                    ),
                  ),
                ).toSliver(),
              Divider().toSliver(),
            ],
          ),
        _SettingPartTitle(
          title: "Page turning".tl,
          icon: Icons.swap_horiz_rounded,
        ),
        // 原来是「点击翻页」+「反向点击翻页」两个开关：关掉第一个，
        // 第二个就成了不起作用的孤儿项。合并成一项三选一。
        SelectSetting(
          title: "Tap to turn pages".tl,
          settingKey: "enableTapToTurnPages",
          help: "Tap the left or right edge of the page to turn it. "
                  "Reversed swaps the two sides."
              .tl,
          optionTranslation: {
            "off": "Off".tl,
            "normal": "Normal".tl,
            "reversed": "Reversed".tl,
          },
          readValue: () => tapTurnOptionOf(
            read("enableTapToTurnPages"),
            read("reverseTapToTurnPages"),
          ),
          writeValue: (value) {
            write("enableTapToTurnPages", value != "off");
            write("reverseTapToTurnPages", value == "reversed");
          },
          onChanged: () {
            widget.onChanged?.call("enableTapToTurnPages");
            widget.onChanged?.call("reverseTapToTurnPages");
          },
          comicId: specificComicId,
          comicSource: specificComicSource,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _SwitchSetting(
          title: "Page animation".tl,
          settingKey: "enablePageAnimation",
          onChanged: () {
            widget.onChanged?.call("enablePageAnimation");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SelectSetting(
          title: "Reading mode".tl,
          settingKey: "readerMode",
          optionTranslation: {
            "galleryLeftToRight": "Gallery (Left to Right)".tl,
            "galleryRightToLeft": "Gallery (Right to Left)".tl,
            "galleryTopToBottom": "Gallery (Top to Bottom)".tl,
            "continuousLeftToRight": "Continuous (Left to Right)".tl,
            "continuousRightToLeft": "Continuous (Right to Left)".tl,
            "continuousTopToBottom": "Continuous (Top to Bottom)".tl,
          },
          onChanged: () {
            setState(() {});
            var readerMode = appdata.settings['readerMode'];
            if (readerMode?.toLowerCase().startsWith('continuous') ?? false) {
              appdata.settings['readerScreenPicNumberForLandscape'] = 1;
              widget.onChanged?.call('readerScreenPicNumberForLandscape');
              appdata.settings['readerScreenPicNumberForPortrait'] = 1;
              widget.onChanged?.call('readerScreenPicNumberForPortrait');
            }
            widget.onChanged?.call("readerMode");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _SliderSetting(
          title: "Auto page turning interval".tl,
          settingsIndex: "autoPageTurningInterval",
          interval: 1,
          min: 1,
          max: 20,
          onChanged: () {
            setState(() {});
            widget.onChanged?.call("autoPageTurningInterval");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SliverAnimatedVisibility(
          visible: appdata.settings['readerMode']!.startsWith('gallery'),
          child: _SliderSetting(
            title:
                "The number of pic in screen for landscape (Only Gallery Mode)"
                    .tl,
            settingsIndex: "readerScreenPicNumberForLandscape",
            interval: 1,
            min: 1,
            max: 5,
            onChanged: () {
              setState(() {});
              widget.onChanged?.call("readerScreenPicNumberForLandscape");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        SliverAnimatedVisibility(
          visible: appdata.settings['readerMode']!.startsWith('gallery'),
          child: _SliderSetting(
            title:
                "The number of pic in screen for portrait (Only Gallery Mode)"
                    .tl,
            settingsIndex: "readerScreenPicNumberForPortrait",
            interval: 1,
            min: 1,
            max: 5,
            onChanged: () {
              widget.onChanged?.call("readerScreenPicNumberForPortrait");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        SliverAnimatedVisibility(
          visible: appdata.settings['readerMode']!.startsWith('gallery') &&
              (appdata.settings['readerScreenPicNumberForLandscape'] > 1 ||
                  appdata.settings['readerScreenPicNumberForPortrait'] > 1),
          child: _SwitchSetting(
            title: "Show single image on first page".tl,
            settingKey: "showSingleImageOnFirstPage",
            onChanged: () {
              widget.onChanged?.call("showSingleImageOnFirstPage");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        // 滚轮加速只对鼠标有意义，手机上露出来只是噪声。
        if (App.isDesktop)
          SliverAnimatedVisibility(
            visible: appdata.settings['readerMode']!.startsWith('continuous'),
            child: _SliderSetting(
              title: "Mouse scroll speed".tl,
              settingsIndex: "readerScrollSpeed",
              interval: 0.1,
              min: 0.5,
              max: 3,
              onChanged: () {
                widget.onChanged?.call("readerScrollSpeed");
              },
              comicId: isEnabledSpecificSettings ? widget.comicId : null,
              comicSource:
                  isEnabledSpecificSettings ? widget.comicSource : null,
              useDeviceSettings: useDeviceSpecificSettings,
            ),
          ),
        _SettingPartTitle(
          title: "Display".tl,
          icon: Icons.visibility_outlined,
        ),
        SelectSetting(
          title: "Auto trim blank margins".tl,
          settingKey: "readerAutoTrim",
          optionTranslation: {
            "off": "Off".tl,
            "conservative": "Conservative".tl,
            "normal": "Normal".tl,
            "aggressive": "Aggressive".tl,
          },
          onChanged: () {
            setState(() {});
            widget.onChanged?.call("readerAutoTrim");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _SliderSetting(
          title: "Eye comfort warmth".tl,
          settingsIndex: "readerWarmFilter",
          interval: 5,
          min: 0,
          max: 100,
          onChanged: () {
            setState(() {});
            widget.onChanged?.call("readerWarmFilter");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SliverAnimatedVisibility(
          visible: (appdata.settings['readerWarmFilter'] as num? ?? 0) > 0,
          child: _SwitchSetting(
            title: "Only at night (20:00 - 07:00)".tl,
            settingKey: "readerWarmFilterAuto",
            onChanged: () {
              setState(() {});
              widget.onChanged?.call("readerWarmFilterAuto");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
        _SwitchSetting(
          title: 'Limit image width'.tl,
          subtitle: 'When using Continuous(Top to Bottom) mode'.tl,
          settingKey: 'limitImageWidth',
          onChanged: () {
            widget.onChanged?.call('limitImageWidth');
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        if (App.isAndroid)
          _SwitchSetting(
            title: 'Turn page by volume keys'.tl,
            settingKey: 'enableTurnPageByVolumeKey',
            onChanged: () {
              widget.onChanged?.call('enableTurnPageByVolumeKey');
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ).toSliver(),
        // 原来是「在阅读器显示时间电量」和「显示系统状态栏」两个开关：
        // 两个都开会出现两套时间，两个都关又什么都没有。本质是同一处
        // 显示什么，合成一个三选一。
        SelectSetting(
          title: "Reader top bar".tl,
          settingKey: "enableClockAndBatteryInfoInReader",
          optionTranslation: {
            "off": "Off".tl,
            "clock": "Time & battery".tl,
            "statusBar": "System status bar".tl,
          },
          readValue: () => readerTopBarOptionOf(
            read("enableClockAndBatteryInfoInReader"),
            read("showSystemStatusBar"),
          ),
          writeValue: (value) {
            write("enableClockAndBatteryInfoInReader", value == "clock");
            write("showSystemStatusBar", value == "statusBar");
          },
          onChanged: () {
            widget.onChanged?.call("enableClockAndBatteryInfoInReader");
            widget.onChanged?.call("showSystemStatusBar");
          },
          comicId: specificComicId,
          comicSource: specificComicSource,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _SwitchSetting(
          title: "Show Page Number".tl,
          settingKey: "showPageNumberInReader",
          onChanged: () {
            widget.onChanged?.call("showPageNumberInReader");
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        if (widget.showGestures)
          SliverToBoxAdapter(
            child: ReaderGestureSettings(
              comicId: widget.comicId,
              comicSource: widget.comicSource,
              onChanged: widget.onChanged,
            ),
          ),
        _SettingPartTitle(
          title: "Image & performance".tl,
          icon: Icons.image_outlined,
        ),
        _CallbackSetting(
          title: "Custom Image Processing".tl,
          callback: () => context.to(() => _CustomImageProcessing()),
          actionTitle: "Edit".tl,
        ).toSliver(),
        _SliderSetting(
          title: "Number of images preloaded".tl,
          settingsIndex: "preloadImageCount",
          interval: 1,
          min: 1,
          max: 16,
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        _SettingPartTitle(
          title: "Comments".tl,
          icon: Icons.comment_outlined,
        ),
        _SwitchSetting(
          title: "Show Chapter Comments".tl,
          settingKey: "showChapterComments",
          onChanged: _onShowChapterCommentsChanged,
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ).toSliver(),
        SliverAnimatedVisibility(
          visible: _isChapterCommentsAtEndSupported(),
          child: _SwitchSetting(
            title: "Show Comments at Chapter End".tl,
            settingKey: "showChapterCommentsAtEnd",
            onChanged: () {
              widget.onChanged?.call("showChapterCommentsAtEnd");
            },
            comicId: isEnabledSpecificSettings ? widget.comicId : null,
            comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
            useDeviceSettings: useDeviceSpecificSettings,
          ),
        ),
      ],
    );
  }
}

class _CustomImageProcessing extends StatefulWidget {
  const _CustomImageProcessing();

  @override
  State<_CustomImageProcessing> createState() => __CustomImageProcessingState();
}

class __CustomImageProcessingState extends State<_CustomImageProcessing> {
  var current = '';

  @override
  void initState() {
    super.initState();
    current = appdata.settings['customImageProcessing'];
  }

  @override
  void dispose() {
    appdata.settings['customImageProcessing'] = current;
    appdata.saveData();
    super.dispose();
  }

  int resetKey = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Custom Image Processing".tl),
        actions: [
          TextButton(
            onPressed: () {
              current = defaultCustomImageProcessing;
              appdata.settings['customImageProcessing'] = current;
              resetKey++;
              setState(() {});
            },
            child: Text("Reset".tl),
          ),
        ],
      ),
      body: Column(
        children: [
          _SwitchSetting(
            title: "Enable".tl,
            settingKey: "enableCustomImageProcessing",
          ),
          Expanded(
            child: Container(
              margin: EdgeInsets.all(8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: context.colorScheme.outlineVariant),
              ),
              child: SizedBox.expand(
                child: CodeEditor(
                  key: ValueKey(resetKey),
                  initialValue: appdata.settings['customImageProcessing'],
                  onChanged: (value) {
                    current = value;
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「操作」分类里的手势分组。
///
/// 抽成独立组件是因为它有两个宿主：阅读器里的设置面板（和其余阅读设置一起
/// 显示）和设置页的「操作」分类。读写的层级规则和 [ReaderSettings] 完全一致
/// （漫画专属 > 设备专属 > 全局），所以两边共用 [_ReaderSettingScope]。
class ReaderGestureSettings extends StatefulWidget {
  const ReaderGestureSettings({
    super.key,
    this.comicId,
    this.comicSource,
    this.onChanged,
  });

  final String? comicId;

  final String? comicSource;

  final void Function(String key)? onChanged;

  @override
  State<ReaderGestureSettings> createState() => _ReaderGestureSettingsState();
}

class _ReaderGestureSettingsState extends State<ReaderGestureSettings> {
  late final scope = _ReaderSettingScope(
    comicId: widget.comicId,
    comicSource: widget.comicSource,
  );

  @override
  Widget build(BuildContext context) {
    final read = scope.read;
    final write = scope.write;
    final useDeviceSpecificSettings = scope.deviceSpecific;
    final isEnabledSpecificSettings = scope.comicSpecific;
    final specificComicId = isEnabledSpecificSettings ? widget.comicId : null;
    final specificComicSource =
        isEnabledSpecificSettings ? widget.comicSource : null;

    return Column(
      children: [
        _SettingPartTitleRow(title: "Gestures".tl, icon: Icons.gesture),
        _SwitchSetting(
          title: 'Double tap to zoom'.tl,
          settingKey: 'enableDoubleTapToZoom',
          onChanged: () {
            setState(() {});
            widget.onChanged?.call('enableDoubleTapToZoom');
          },
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ),
        // 原来是三项：长按动作（快捷面板/缩放）、是否允许长按缩放、
        // 缩放位置。三者共同决定一件事，用户很容易配成「动作选了缩放、
        // 开关却是关的」这种长按完全没反应的状态。合并成一项三选一。
        SelectSetting(
          title: "Long press in reader".tl,
          settingKey: "longPressAction",
          optionTranslation: {
            "hud": "Quick panel".tl,
            "zoomPress": "Zoom at press position".tl,
            "zoomCenter": "Zoom at screen center".tl,
          },
          readValue: () => longPressOptionOf(
            read("longPressAction"),
            read("enableLongPressToZoom"),
            read("longPressZoomPosition"),
          ),
          writeValue: (value) {
            final keys = longPressKeysOf(value);
            write("longPressAction", keys.action);
            if (keys.zoomEnabled != null) {
              write("enableLongPressToZoom", keys.zoomEnabled);
            }
            if (keys.position != null) {
              write("longPressZoomPosition", keys.position);
            }
          },
          onChanged: () {
            setState(() {});
            widget.onChanged?.call("longPressAction");
            widget.onChanged?.call("enableLongPressToZoom");
            widget.onChanged?.call("longPressZoomPosition");
          },
          comicId: specificComicId,
          comicSource: specificComicSource,
          useDeviceSettings: useDeviceSpecificSettings,
        ),
        SelectSetting(
          title: "Quick collect image".tl,
          settingKey: "quickCollectImage",
          optionTranslation: {
            "No": "Not enable".tl,
            "DoubleTap": "Double Tap".tl,
            "Swipe": "Swipe".tl,
          },
          onChanged: () {
            widget.onChanged?.call("quickCollectImage");
          },
          help:
              "On the image browsing page, you can quickly collect images by sliding horizontally or vertically according to your reading mode"
                  .tl,
          comicId: isEnabledSpecificSettings ? widget.comicId : null,
          comicSource: isEnabledSpecificSettings ? widget.comicSource : null,
          useDeviceSettings: useDeviceSpecificSettings,
        ),
      ],
    );
  }
}

/// 阅读设置的读写层级：漫画专属 > 设备专属 > 全局。
///
/// 这段规则原来在 `_ReaderSettingsState.build` 里以闭包形式存在，手势分组
/// 拆出去以后要再用一遍，就提成了对象——规则只有一份，不会两边走偏。
class _ReaderSettingScope {
  const _ReaderSettingScope({this.comicId, this.comicSource});

  final String? comicId;

  final String? comicSource;

  bool get comicSpecific =>
      comicId != null &&
      comicSource != null &&
      appdata.settings.isComicSpecificSettingsEnabled(comicId, comicSource);

  bool get deviceSpecific =>
      !comicSpecific && appdata.settings.isDeviceSpecificSettingsEnabled();

  Object? read(String settingKey) {
    if (comicSpecific) {
      return appdata.settings
          .getReaderSetting(comicId!, comicSource!, settingKey);
    }
    if (deviceSpecific) {
      return appdata.settings.getDeviceReaderSetting(settingKey);
    }
    return appdata.settings[settingKey];
  }

  void write(String settingKey, Object? value) {
    if (comicSpecific) {
      appdata.settings.setReaderSetting(
        comicId!,
        comicSource!,
        settingKey,
        value,
      );
    } else if (deviceSpecific) {
      appdata.settings.setDeviceReaderSetting(settingKey, value);
    } else {
      appdata.settings[settingKey] = value;
    }
  }
}
