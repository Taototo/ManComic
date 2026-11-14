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
import 'package:venera/foundation/display_refresh.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/notification_service.dart';
import 'package:venera/foundation/storage_usage.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/update_check_policy.dart';
import 'package:venera/foundation/subscription.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/network/xray_core.dart';
import 'package:venera/network/xray_tunnel.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/home_modules_page.dart';
import 'package:venera/pages/reading_report_page.dart';
import 'package:venera/utils/app_icon.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/download_background.dart';
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
part 'storage_settings.dart';
part 'network.dart';
part 'xray_page.dart';
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
  /// 这套分类参考 VeneraX：App / Reading / Favorites / Data & Sync / Explore /
  /// Network / About，属于同一件事的设置挨在一起，并且每个分类配一句说明——
  /// 光看名字猜不到「Data & Sync」里有下载线程，「Explore」里有列表缩略图。
  ///
  /// 调试相关的东西不在这里——「重载配置 / JS 求值器」对绝大多数人没有意义，
  /// 放在列表里只会增加噪声。需要时在「关于」页连点版本号 7 次打开。
  final categories = <String>[
    "App",
    "Reading",
    "Favorites",
    "Data & Sync",
    // 这里叫 Content 而不是 Explore：应用里的 Explore 已经是「推荐」页的
    // 专名，同一个词出现在设置里会让人以为是在调推荐页。
    "Content",
    "Network",
    "About",
  ];

  final icons = <IconData>[
    Icons.apps,
    Icons.book,
    Icons.collections_bookmark_rounded,
    Icons.cloud_sync_outlined,
    Icons.explore,
    Icons.public,
    Icons.info_outline,
  ];

  final descriptions = <String>[
    "Appearance, language, privacy and home layout",
    "Page layout, gestures and reading display",
    "Favorite folders and collection behavior",
    "Storage, cache, backups and downloads",
    "Comic lists, sources and content filters",
    "Proxy, DNS and connections",
    "Version, updates and help",
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
        height: 66,
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
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts.s16,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    descriptions[id].tl,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ts.s10.withColor(colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
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
      0 => const AppSettings(),
      // 手势回到阅读页：它管的就是「书怎么看」，和翻页、显示是一类事。
      1 => const ReaderSettings(showGestures: true, showReports: true),
      2 => const FavoritesSettings(),
      3 => const DataSettings(),
      4 => const ExploreSettings(),
      5 => const NetworkSettings(),
      6 => const AboutSettings(),
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
      0 => const AppSettings(),
      // 手势回到阅读页：它管的就是「书怎么看」，和翻页、显示是一类事。
      1 => const ReaderSettings(showGestures: true, showReports: true),
      2 => const FavoritesSettings(),
      3 => const DataSettings(),
      4 => const ExploreSettings(),
      5 => const NetworkSettings(),
      6 => const AboutSettings(),
      _ => throw UnimplementedError(),
    };
  }
}
