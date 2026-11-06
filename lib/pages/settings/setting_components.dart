part of 'settings_page.dart';

/// 设置明细行的左右留白。
///
/// 每个设置页都按「图标 + 标题」分组，标题是「16 + 图标 24 + 8」从 48 起排字。
/// 明细行给到 48，正好和标题文字对齐：图标独占最左一列，明细整体内收成一个
/// 块，层级不用靠字号也能看出来。取 40 那种"半缩进"反而会让明细卡在图标和
/// 标题文字之间，看着像没对齐。
///
/// 这里曾经用 InheritedWidget 让「没有分组标题的页面」退回 16，结果踩了一个
/// 很隐蔽的坑：那个查找函数拿到的 context 是页面 State
/// 自己的，位于 scope **之上**，查不到 scope 就按默认值 48 处理，于是那几页
/// 怎么改都还是 48。现在统一成「每页都有分组标题 + 恒定 48」，规则只有一条，
/// 也不会再被 context 层级坑到。
const EdgeInsetsDirectional kSettingTilePadding =
    EdgeInsetsDirectional.only(start: 48, end: 16);

class _SwitchSetting extends StatefulWidget {
  const _SwitchSetting({
    required this.title,
    required this.settingKey,
    this.onChanged,
    this.subtitle,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
  });

  final String title;

  final String settingKey;

  final VoidCallback? onChanged;

  final String? subtitle;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  @override
  State<_SwitchSetting> createState() => _SwitchSettingState();
}

class _SwitchSettingState extends State<_SwitchSetting> {
  @override
  Widget build(BuildContext context) {
    var value = widget.comicId != null
        ? appdata.settings.getReaderSetting(
            widget.comicId!,
            widget.comicSource!,
            widget.settingKey,
          )
        : widget.useDeviceSettings
            ? appdata.settings.getDeviceReaderSetting(widget.settingKey)
            : appdata.settings[widget.settingKey];

    assert(value is bool);

    return ListTile(
      contentPadding: kSettingTilePadding,
      title: Text(widget.title),
      subtitle: widget.subtitle == null ? null : Text(widget.subtitle!),
      trailing: Switch(
        value: value,
        onChanged: (value) {
          setState(() {
            if (widget.comicId != null) {
              appdata.settings.setReaderSetting(
                widget.comicId!,
                widget.comicSource!,
                widget.settingKey,
                value,
              );
            } else if (widget.useDeviceSettings) {
              appdata.settings.setDeviceReaderSetting(widget.settingKey, value);
            } else {
              appdata.settings[widget.settingKey] = value;
            }
          });
          appdata.saveData().then((_) {
            widget.onChanged?.call();
          });
        },
      ),
    );
  }
}

class SelectSetting extends StatelessWidget {
  const SelectSetting({
    super.key,
    required this.title,
    required this.settingKey,
    required this.optionTranslation,
    this.onChanged,
    this.help,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
    this.readValue,
    this.writeValue,
  });

  final String title;

  final String settingKey;

  final Map<String, String> optionTranslation;

  final VoidCallback? onChanged;

  final String? help;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  /// 覆盖「一个 settingKey 存一个值」的默认读法。
  ///
  /// 有些概念在存储层是由两三个键共同表示的（长按动作 = 动作 + 是否启用 +
  /// 放大位置；点击翻页 = 开关 + 是否反向）。设置页只该露一项，否则用户会
  /// 看到一个开了另一个没开、行为还不确定的组合。调用方给出「读成哪个虚拟
  /// 选项」，[writeValue] 负责把选择拆回那几个键。
  final String? Function()? readValue;

  /// 与 [readValue] 配套：用户选了某个虚拟选项时怎么写回底层的键。
  ///
  /// 只做内存赋值即可，保存与刷新由选择器统一处理。
  final void Function(String value)? writeValue;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 450) {
            return _DoubleLineSelectSettings(
              title: title,
              settingKey: settingKey,
              optionTranslation: optionTranslation,
              onChanged: onChanged,
              help: help,
              comicId: comicId,
              comicSource: comicSource,
              useDeviceSettings: useDeviceSettings,
              readValue: readValue,
              writeValue: writeValue,
            );
          } else {
            return _EndSelectorSelectSetting(
              title: title,
              settingKey: settingKey,
              optionTranslation: optionTranslation,
              onChanged: onChanged,
              help: help,
              comicId: comicId,
              comicSource: comicSource,
              useDeviceSettings: useDeviceSettings,
              readValue: readValue,
              writeValue: writeValue,
            );
          }
        },
      ),
    );
  }
}

class _DoubleLineSelectSettings extends StatefulWidget {
  const _DoubleLineSelectSettings({
    required this.title,
    required this.settingKey,
    required this.optionTranslation,
    this.onChanged,
    this.help,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
    this.readValue,
    this.writeValue,
  });

  final String title;

  final String settingKey;

  final Map<String, String> optionTranslation;

  final VoidCallback? onChanged;

  final String? help;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  final String? Function()? readValue;

  final void Function(String value)? writeValue;

  @override
  State<_DoubleLineSelectSettings> createState() =>
      _DoubleLineSelectSettingsState();
}

class _DoubleLineSelectSettingsState extends State<_DoubleLineSelectSettings> {
  Object? _rawValue() => widget.comicId != null
      ? appdata.settings.getReaderSetting(
          widget.comicId!,
          widget.comicSource!,
          widget.settingKey,
        )
      : widget.useDeviceSettings
          ? appdata.settings.getDeviceReaderSetting(widget.settingKey)
          : appdata.settings[widget.settingKey];

  void _apply(String value) {
    final custom = widget.writeValue;
    if (custom != null) {
      custom(value);
    } else if (widget.comicId != null) {
      appdata.settings.setReaderSetting(
        widget.comicId!,
        widget.comicSource!,
        widget.settingKey,
        value,
      );
    } else if (widget.useDeviceSettings) {
      appdata.settings.setDeviceReaderSetting(widget.settingKey, value);
    } else {
      appdata.settings[widget.settingKey] = value;
    }
    setState(() {});
    appdata.saveData();
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    var value = widget.readValue?.call() ?? _rawValue();

    return ListTile(
      contentPadding: kSettingTilePadding,
      title: Row(
        children: [
          Text(widget.title),
          const SizedBox(width: 4),
          if (widget.help != null)
            Button.icon(
              size: 18,
              icon: const Icon(Icons.help_outline),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) {
                    return ContentDialog(
                      title: "Help".tl,
                      content: Text(
                        widget.help!,
                      ).paddingHorizontal(16).fixWidth(double.infinity),
                      actions: [
                        Button.filled(
                          onPressed: context.pop,
                          child: Text("OK".tl),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
        ],
      ),
      subtitle: Text(widget.optionTranslation[value] ?? "None"),
      trailing: const Icon(Icons.arrow_drop_down),
      onTap: () {
        var renderBox = context.findRenderObject() as RenderBox;
        var offset = renderBox.localToGlobal(Offset.zero);
        var size = renderBox.size;
        var rect = offset & size;
        showMenu(
          elevation: 3,
          // 液态主题下交给 popupMenuTheme 的磨砂色，别写死。
          color: LiquidTheme.isOn(context)
              ? null
              : (context.brightness == Brightness.light
                  ? const Color(0xFFF6F6F6)
                  : const Color(0xFF1E1E1E)),
          context: context,
          position: RelativeRect.fromRect(
            rect,
            Offset.zero & MediaQuery.of(context).size,
          ),
          items: widget.optionTranslation.keys
              .map(
                (key) => PopupMenuItem(
                  value: key,
                  height: App.isMobile ? 46 : 40,
                  child: Text(widget.optionTranslation[key]!),
                ),
              )
              .toList(),
        ).then((value) {
          if (value != null) {
            _apply(value);
          }
        });
      },
    );
  }
}

class _EndSelectorSelectSetting extends StatefulWidget {
  const _EndSelectorSelectSetting({
    required this.title,
    required this.settingKey,
    required this.optionTranslation,
    this.onChanged,
    this.help,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
    this.readValue,
    this.writeValue,
  });

  final String title;

  final String settingKey;

  final Map<String, String> optionTranslation;

  final VoidCallback? onChanged;

  final String? help;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  final String? Function()? readValue;

  final void Function(String value)? writeValue;

  @override
  State<_EndSelectorSelectSetting> createState() =>
      _EndSelectorSelectSettingState();
}

class _EndSelectorSelectSettingState extends State<_EndSelectorSelectSetting> {
  Object? _rawValue() => widget.comicId != null
      ? appdata.settings.getReaderSetting(
          widget.comicId!,
          widget.comicSource!,
          widget.settingKey,
        )
      : widget.useDeviceSettings
          ? appdata.settings.getDeviceReaderSetting(widget.settingKey)
          : appdata.settings[widget.settingKey];

  void _apply(String value) {
    final custom = widget.writeValue;
    if (custom != null) {
      custom(value);
    } else if (widget.comicId != null) {
      appdata.settings.setReaderSetting(
        widget.comicId!,
        widget.comicSource!,
        widget.settingKey,
        value,
      );
    } else if (widget.useDeviceSettings) {
      appdata.settings.setDeviceReaderSetting(widget.settingKey, value);
    } else {
      appdata.settings[widget.settingKey] = value;
    }
    setState(() {});
    appdata.saveData();
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    var options = widget.optionTranslation;
    var value = widget.readValue?.call() ?? _rawValue();
    return ListTile(
      contentPadding: kSettingTilePadding,
      title: Row(
        children: [
          Text(widget.title),
          const SizedBox(width: 4),
          if (widget.help != null)
            Button.icon(
              size: 18,
              icon: const Icon(Icons.help_outline),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) {
                    return ContentDialog(
                      title: "Help".tl,
                      content: Text(
                        widget.help!,
                      ).paddingHorizontal(16).fixWidth(double.infinity),
                      actions: [
                        Button.filled(
                          onPressed: context.pop,
                          child: Text("OK".tl),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
        ],
      ),
      trailing: Select(
        current: options[value],
        values: options.values.toList(),
        minWidth: 64,
        onTap: (index) {
          _apply(options.keys.elementAt(index));
        },
      ),
    );
  }
}

class _SliderSetting extends StatefulWidget {
  const _SliderSetting({
    required this.title,
    required this.settingsIndex,
    required this.interval,
    required this.min,
    required this.max,
    this.onChanged,
    this.comicId,
    this.comicSource,
    this.useDeviceSettings = false,
  });

  final String title;

  final String settingsIndex;

  final double interval;

  final double min;

  final double max;

  final VoidCallback? onChanged;

  final String? comicId;

  final String? comicSource;

  final bool useDeviceSettings;

  @override
  State<_SliderSetting> createState() => _SliderSettingState();
}

class _SliderSettingState extends State<_SliderSetting> {
  @override
  Widget build(BuildContext context) {
    var value = (widget.comicId != null
            ? appdata.settings.getReaderSetting(
                widget.comicId!,
                widget.comicSource!,
                widget.settingsIndex,
              )
            : widget.useDeviceSettings
                ? appdata.settings.getDeviceReaderSetting(widget.settingsIndex)
                : appdata.settings[widget.settingsIndex])
        .toDouble();
    return ListTile(
      contentPadding: kSettingTilePadding,
      title: Text(widget.title, softWrap: true, maxLines: 2),
      trailing: Text(value.toString(), style: ts.s12),
      subtitle: Slider(
        value: value,
        onChanged: (value) {
          if (value.toInt() == value) {
            setState(() {
              if (widget.comicId != null) {
                appdata.settings.setReaderSetting(
                  widget.comicId!,
                  widget.comicSource!,
                  widget.settingsIndex,
                  value.toInt(),
                );
              } else if (widget.useDeviceSettings) {
                appdata.settings.setDeviceReaderSetting(
                  widget.settingsIndex,
                  value.toInt(),
                );
              } else {
                appdata.settings[widget.settingsIndex] = value.toInt();
              }
              appdata.saveData();
            });
          } else {
            setState(() {
              if (widget.comicId != null) {
                appdata.settings.setReaderSetting(
                  widget.comicId!,
                  widget.comicSource!,
                  widget.settingsIndex,
                  value,
                );
              } else if (widget.useDeviceSettings) {
                appdata.settings.setDeviceReaderSetting(
                  widget.settingsIndex,
                  value,
                );
              } else {
                appdata.settings[widget.settingsIndex] = value;
              }
              appdata.saveData();
            });
          }
          widget.onChanged?.call();
        },
        divisions: ((widget.max - widget.min) / widget.interval).toInt(),
        min: widget.min,
        max: widget.max,
      ),
    );
  }
}

class _PopupWindowSetting extends StatelessWidget {
  const _PopupWindowSetting({required this.title, required this.builder});

  final Widget Function() builder;

  final String title;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: kSettingTilePadding,
      title: Text(title),
      trailing: const Icon(Icons.arrow_right),
      onTap: () {
        showPopUpWidget(App.rootContext, builder());
      },
    );
  }
}

class _MultiPagesFilter extends StatefulWidget {
  const _MultiPagesFilter({
    required this.title,
    required this.settingsIndex,
    required this.pages,
  });

  final String title;

  final String settingsIndex;

  // key - name
  final Map<String, String> pages;

  @override
  State<_MultiPagesFilter> createState() => _MultiPagesFilterState();
}

class _MultiPagesFilterState extends State<_MultiPagesFilter> {
  late List<String> keys;

  @override
  void initState() {
    keys = List.from(appdata.settings[widget.settingsIndex]);
    keys.remove("");
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
    Future.microtask(() {
      updateSetting();
    });
  }

  var reorderWidgetKey = UniqueKey();
  var scrollController = ScrollController();
  final _key = GlobalKey();

  @override
  Widget build(BuildContext context) {
    var tiles = keys.map((e) => buildItem(e)).toList();

    var view = ReorderableBuilder<String>(
      key: reorderWidgetKey,
      scrollController: scrollController,
      longPressDelay: App.isDesktop
          ? const Duration(milliseconds: 100)
          : const Duration(milliseconds: 500),
      dragChildBoxDecoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainer,
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 5,
            offset: Offset(0, 2),
            spreadRadius: 2,
          ),
        ],
      ),
      onReorder: (reorderFunc) {
        setState(() {
          keys = List.from(reorderFunc(keys));
        });
      },
      children: tiles,
      builder: (children) {
        return GridView(
          key: _key,
          controller: scrollController,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 1,
            mainAxisExtent: 48,
          ),
          children: children,
        );
      },
    );

    return PopUpWidgetScaffold(
      title: widget.title,
      tailing: [
        if (keys.length < widget.pages.length)
          TextButton.icon(
            label: Text("Add".tl),
            icon: const Icon(Icons.add),
            onPressed: showAddDialog,
          ),
      ],
      body: view,
    );
  }

  Widget buildItem(String key) {
    Widget removeButton = Padding(
      padding: const EdgeInsets.only(right: 8),
      child: IconButton(
        onPressed: () {
          setState(() {
            keys.remove(key);
          });
        },
        icon: const Icon(Icons.delete_outline),
      ),
    );

    return ListTile(
      title: Text(widget.pages[key] ?? "(Invalid) $key"),
      key: Key(key),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [removeButton, const Icon(Icons.drag_handle)],
      ),
    );
  }

  void showAddDialog() {
    var canAdd = <String, String>{};
    widget.pages.forEach((key, value) {
      if (!keys.contains(key)) {
        canAdd[key] = value;
      }
    });
    var selected = <String>[];
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: "Add".tl,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: canAdd.entries
                    .map(
                      (e) => CheckboxListTile(
                        value: selected.contains(e.key),
                        title: Text(e.value),
                        key: Key(e.key),
                        onChanged: (value) {
                          setState(() {
                            if (value!) {
                              selected.add(e.key);
                            } else {
                              selected.remove(e.key);
                            }
                          });
                        },
                      ),
                    )
                    .toList(),
              ),
              actions: [
                if (selected.length < canAdd.length)
                  TextButton(
                    child: Text("Select All".tl),
                    onPressed: () {
                      setState(() {
                        selected = canAdd.keys.toList();
                      });
                    },
                  )
                else
                  TextButton(
                    child: Text("Deselect All".tl),
                    onPressed: () {
                      setState(() {
                        selected.clear();
                      });
                    },
                  ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: selected.isNotEmpty
                      ? () {
                          this.setState(() {
                            keys.addAll(selected);
                          });
                          Navigator.pop(context);
                        }
                      : null,
                  child: Text("Add".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void updateSetting() {
    appdata.settings[widget.settingsIndex] = keys;
    appdata.saveData();
  }
}

class _CallbackSetting extends StatelessWidget {
  const _CallbackSetting({
    required this.title,
    required this.callback,
    required this.actionTitle,
    this.subtitle,
  });

  final String title;

  final String? subtitle;

  final VoidCallback callback;

  final String actionTitle;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: kSettingTilePadding,
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: Button.normal(
        onPressed: callback,
        child: Text(actionTitle),
      ).fixHeight(28),
      onTap: callback,
    );
  }
}

/// 分组标题的展平版（只有那一行，不含 sliver 外壳）。
///
/// 有些页面会把若干设置拼成一个普通 Widget 再塞进 sliver，那时不能直接
/// 用下面的 [_SettingPartTitle]（它自带 SliverToBoxAdapter），所以拆成两半。
class _SettingPartTitleRow extends StatelessWidget {
  const _SettingPartTitleRow({required this.title, required this.icon});

  final String title;

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 16, top: 16, bottom: 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: context.colorScheme.onSurface.withValues(alpha: 0.1),
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 24),
          const SizedBox(width: 8),
          Text(title, style: ts.s18),
        ],
      ),
    );
  }
}

class _SettingPartTitle extends StatelessWidget {
  const _SettingPartTitle({required this.title, required this.icon});

  final String title;

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: _SettingPartTitleRow(title: title, icon: icon),
    );
  }
}

/// 长按动作在设置页里是一个三选一，但底层由三个键共同表示。
///
/// 抽成纯函数是为了能单独测：这层映射一旦写反，用户在设置里选的和阅读器里
/// 真正发生的事就对不上，而且很难从界面上看出来。
String longPressOptionOf(
  Object? action,
  Object? zoomEnabled,
  Object? position,
) {
  // 旧配置里可能「动作是缩放、开关却是关的」，实际长按没有任何反应，
  // 按快捷面板显示才和用户看到的一致。
  if (action != "zoom" || zoomEnabled != true) {
    return "hud";
  }
  return position == "center" ? "zoomCenter" : "zoomPress";
}

/// [longPressOptionOf] 的反向映射：选中某个选项时要写哪几个键。
///
/// 选「快捷面板」时不返回放大位置（null = 不用写），这样用户从「居中放大」
/// 切到「快捷面板」再切回来，位置还在，不会被顺手重置成默认值。
({String action, bool? zoomEnabled, String? position}) longPressKeysOf(
  String option,
) {
  if (option == "hud") {
    return (action: "hud", zoomEnabled: null, position: null);
  }
  return (
    action: "zoom",
    zoomEnabled: true,
    position: option == "zoomCenter" ? "center" : "press",
  );
}

/// 点击翻页：开关 + 是否反向，两项合成「关闭 / 正常 / 反向」。
String tapTurnOptionOf(Object? enabled, Object? reversed) {
  if (enabled != true) {
    return "off";
  }
  return reversed == true ? "reversed" : "normal";
}

/// 阅读器顶部的信息显示：App 自绘的时间电量、系统状态栏，或者都关掉。
///
/// 两者同时打开会出现两套时间，所以合成一个三选一。
String readerTopBarOptionOf(Object? clock, Object? statusBar) {
  if (statusBar == true) {
    return "statusBar";
  }
  if (clock == true) {
    return "clock";
  }
  return "off";
}
