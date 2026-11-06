import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:local_auth/local_auth.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/background_tasks.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/notification_service.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/update_check_policy.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/home_modules_page.dart';
import 'package:venera/pages/reading_report_page.dart';
import 'package:venera/utils/app_icon.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';
import 'package:venera/utils/version.dart';
import 'package:yaml/yaml.dart';

part 'setting_components.dart';
part 'explore_settings.dart';
part 'reader.dart';
part 'interface_settings.dart';
part 'action_settings.dart';
part 'feature_settings.dart';
part 'network.dart';
part 'about.dart';
part 'update_download.dart';
part 'debug.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({this.initialPage = -1, super.key});

  final int initialPage;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int currentPage = -1;

  ColorScheme get colors => Theme.of(context).colorScheme;

  bool get enableTwoViews => context.width > 720;

  /// 分类按「你在改什么」划分，而不是按页面/模块划分。
  ///
  /// 以前是 探索 / 阅读 / 外观 / 本地收藏 / 漫画源 / APP / 网络 / 关于——
  /// 其中「APP」只是「没想好放哪的都塞进来」，「探索」既是页面名又装着一堆
  /// 缩略图设置，本地收藏整页其实都是收藏操作。现在按语义收成六类：
  ///
  /// * 界面 —— 看起来怎么样（主题、图标、材质、缩略图）
  /// * 阅读 —— 书怎么看（翻页、显示、图片、评论）
  /// * 操作 —— 手怎么用（手势、收藏操作、隐私）
  /// * 功能 —— 能做什么（数据、通知、内容来源、屏蔽）
  /// * 网络 —— 怎么连
  /// * 关于 —— 版本与更新
  ///
  /// 调试相关的东西不在这里——「重载配置 / JS 求值器」对绝大多数人没有意义，
  /// 放在列表里只会增加噪声。需要时在「关于」页连点版本号 7 次打开。
  final categories = <String>[
    "Interface",
    "Reading",
    "Actions",
    "Features",
    "Network",
    "About",
  ];

  final icons = <IconData>[
    Icons.palette_outlined,
    Icons.auto_stories_outlined,
    Icons.touch_app_outlined,
    Icons.widgets_outlined,
    Icons.public,
    Icons.info_outline,
  ];

  @override
  void initState() {
    currentPage = widget.initialPage;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Material(child: buildBody());
  }

  Widget buildBody() {
    if (enableTwoViews) {
      return Row(
        children: [
          SizedBox(width: 280, height: double.infinity, child: buildLeft()),
          Container(
            height: double.infinity,
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: context.colorScheme.outlineVariant,
                  width: 0.6,
                ),
              ),
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, animation) {
                return LayoutBuilder(
                  builder: (context, constrains) {
                    return AnimatedBuilder(
                      animation: animation,
                      builder: (context, _) {
                        var width = constrains.maxWidth;
                        var value = animation.isForwardOrCompleted
                            ? 1 - animation.value
                            : 1;
                        var left = width * value;
                        return Stack(
                          children: [
                            Positioned(
                              top: 0,
                              bottom: 0,
                              left: left,
                              width: width,
                              child: child,
                            ),
                          ],
                        );
                      },
                    );
                  },
                );
              },
              child: buildRight(),
            ),
          ),
        ],
      );
    } else {
      return buildLeft();
    }
  }

  Widget buildLeft() {
    return Material(
      child: Column(
        children: [
          SizedBox(height: MediaQuery.of(context).padding.top),
          SizedBox(
            height: 56,
            child: Row(
              children: [
                const SizedBox(width: 8),
                Tooltip(
                  message: "Back".tl,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: context.pop,
                  ),
                ),
                const SizedBox(width: 24),
                Text("Settings".tl, style: ts.s20),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Expanded(child: buildCategories()),
        ],
      ),
    );
  }

  Widget buildCategories() {
    Widget buildItem(String name, int id) {
      final bool selected = id == currentPage;

      Widget content = AnimatedContainer(
        key: ValueKey(id),
        duration: const Duration(milliseconds: 200),
        width: double.infinity,
        height: 46,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
        decoration: BoxDecoration(
          color: selected ? colors.primaryContainer.toOpacity(0.36) : null,
          border: Border(
            left: BorderSide(
              color: selected ? colors.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(icons[id]),
            const SizedBox(width: 16),
            Text(name, style: ts.s16),
            const Spacer(),
            if (selected) const Icon(Icons.arrow_right),
          ],
        ),
      );

      return Padding(
        padding: enableTwoViews
            ? const EdgeInsets.fromLTRB(8, 0, 8, 0)
            : EdgeInsets.zero,
        child: InkWell(
          onTap: () {
            if (enableTwoViews) {
              setState(() => currentPage = id);
            } else {
              context.to(() => _SettingsDetailPage(pageIndex: id));
            }
          },
          child: content,
        ).paddingVertical(4),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: categories.length,
      itemBuilder: (context, index) => buildItem(categories[index].tl, index),
    );
  }

  Widget buildRight() {
    if (currentPage == -1) {
      return const SizedBox();
    }
    return Navigator(
      onGenerateRoute: (settings) {
        return PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) {
            return _buildSettingsContent(currentPage);
          },
          transitionDuration: Duration.zero,
        );
      },
    );
  }

  Widget _buildSettingsContent(int pageIndex) {
    return switch (pageIndex) {
      0 => const InterfaceSettings(),
      // 手势已经拆到「操作」分类，阅读页不再重复显示。
      1 => const ReaderSettings(showGestures: false),
      2 => const ActionSettings(),
      3 => const FeatureSettings(),
      4 => const NetworkSettings(),
      5 => const AboutSettings(),
      _ => throw UnimplementedError(),
    };
  }
}

class _SettingsDetailPage extends StatelessWidget {
  const _SettingsDetailPage({required this.pageIndex});

  final int pageIndex;

  @override
  Widget build(BuildContext context) {
    return Material(child: _buildPage());
  }

  Widget _buildPage() {
    return switch (pageIndex) {
      0 => const InterfaceSettings(),
      1 => const ReaderSettings(showGestures: false),
      2 => const ActionSettings(),
      3 => const FeatureSettings(),
      4 => const NetworkSettings(),
      5 => const AboutSettings(),
      _ => throw UnimplementedError(),
    };
  }
}
