import 'package:flutter/material.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/reading_report_page.dart';
import 'package:venera/pages/search_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/translations.dart';

import '../components/components.dart';
import '../foundation/app.dart';
import 'explore_page.dart';
import 'favorites/favorites_page.dart';
import 'home_page.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  late final NaviObserver _observer;

  GlobalKey<NavigatorState>? _navigatorKey;

  void to(Widget Function() widget, {bool preventDuplicate = false}) async {
    if (preventDuplicate) {
      var page = widget();
      if ("/${page.runtimeType}" == _observer.routes.last.toString()) return;
    }
    _navigatorKey!.currentContext!.to(widget);
  }

  void back() {
    _navigatorKey!.currentContext!.pop();
  }

  /// 底栏曾经是「首页 / 发现 / 分类 / 收藏」，分类页并入发现页后变成三项，
  /// 这里做一次性的索引迁移，避免老用户启动后落到错误的页面。
  static const _kNavMergedCategoriesKey = "navMergedCategories";

  int resolveInitialPage() {
    var saved = int.tryParse(appdata.settings['initialPage'].toString()) ?? 0;
    if (appdata.settings[_kNavMergedCategoriesKey] != "1") {
      saved = switch (saved) {
        2 => 1,
        3 => 2,
        _ => saved,
      };
      appdata.settings['initialPage'] = saved.toString();
      appdata.settings[_kNavMergedCategoriesKey] = "1";
      appdata.saveData();
    }
    return saved.clamp(0, 2);
  }

  @override
  void initState() {
    _observer = NaviObserver();
    _navigatorKey = GlobalKey();
    App.mainNavigatorKey = _navigatorKey;
    index = resolveInitialPage();
    super.initState();
  }

  final _pages = [
    const HomePage(),
    const ExplorePage(
      key: PageStorageKey('explore'),
    ),
    const FavoritesPage(
      key: PageStorageKey('favorites'),
    ),
  ];

  var index = 0;

  @override
  Widget build(BuildContext context) {
    return NaviPane(
      initialPage: index,
      observer: _observer,
      navigatorKey: _navigatorKey!,
      paneItems: [
        PaneItemEntry(
          label: 'Home'.tl,
          icon: Icons.home_outlined,
          activeIcon: Icons.home,
        ),
        PaneItemEntry(
          label: 'Explore'.tl,
          icon: Icons.explore_outlined,
          activeIcon: Icons.explore,
        ),
        PaneItemEntry(
          label: 'Favorites'.tl,
          icon: Icons.local_activity_outlined,
          activeIcon: Icons.local_activity,
        ),
      ],
      onPageChanged: (i) {
        setState(() {
          index = i;
        });
      },
      paneActions: [
        if(index != 0)
          PaneActionEntry(
            icon: Icons.search,
            label: "Search".tl,
            onTap: () {
              to(() => const SearchPage(), preventDuplicate: true);
            },
          ),
        // 布局切换按钮 - 仅在发现页显示
        if (index == 1)
          PaneActionEntry(
            icon: (appdata.settings['comicLayoutMode'] ?? 'grid') == 'staggered'
                ? Icons.grid_view
                : Icons.view_module,
            label: (appdata.settings['comicLayoutMode'] ?? 'grid') == 'staggered'
                ? "Grid".tl
                : "Flow".tl,
            onTap: () {
              final layoutMode =
                  appdata.settings['comicLayoutMode'] ?? 'grid';
              final newMode = layoutMode == 'grid' ? 'staggered' : 'grid';
              appdata.settings['comicLayoutMode'] = newMode;
              appdata.saveData();
              final message = newMode == 'staggered'
                  ? "Switched to Staggered Layout".tl
                  : "Switched to Grid Layout".tl;
              App.rootContext.showMessage(message: message);
              setState(() {});
            },
          ),
        // 年度阅读报告入口 - 仅首页显示，放在设置按钮旁边
        if (index == 0)
          PaneActionEntry(
            icon: Icons.insights_rounded,
            label: "Reading Report".tl,
            onTap: () {
              to(() => const ReadingReportPage(), preventDuplicate: true);
            },
          ),
        PaneActionEntry(
          icon: Icons.settings,
          label: "Settings".tl,
          onTap: () {
            to(() => const SettingsPage(), preventDuplicate: true);
          },
        )
      ],
      pageBuilder: (index) {
        return _pages[index];
      },
    );
  }
}
