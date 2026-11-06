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

  /// 底栏顺序：推荐 / 主页 / 收藏。
  ///
  /// 注意 [appdata.settings] 里的 `initialPage` 存的是「哪一页」而不是下标
  /// （0 主页、1 推荐、2 收藏），设置页的文案也是按这个编号写的。底栏换了
  /// 顺序以后两者不再相等，所以这里必须显式映射一次，不能直接把存下来的
  /// 数字当索引用——否则老用户开机会落到隔壁那一页。
  static const _tabExplore = 0;

  static const _tabHome = 1;

  static const _tabFavorites = 2;

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
    return switch (saved) {
      1 => _tabExplore,
      2 => _tabFavorites,
      _ => _tabHome,
    };
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
    const ExplorePage(
      key: PageStorageKey('explore'),
    ),
    const HomePage(),
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
          label: 'Explore'.tl,
          icon: Icons.explore_outlined,
          activeIcon: Icons.explore,
        ),
        PaneItemEntry(
          label: 'Home'.tl,
          icon: Icons.home_outlined,
          activeIcon: Icons.home,
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
        if (index != _tabHome)
          PaneActionEntry(
            icon: Icons.search,
            label: "Search".tl,
            onTap: () {
              to(() => const SearchPage(), preventDuplicate: true);
            },
          ),
        // 缩略图显示模式开关 - 仅在发现页显示
        //
        // 这里原来是「网格 / 瀑布流」的布局切换。布局是「整页怎么排」，改一次
        // 基本就不再动了；而「详细 / 简洁」是「一张卡显示多少信息」，翻两页
        // 就想换一次——后者才是高频操作，放到顶栏才合理。布局本身仍在
        // 设置 - 界面 里。
        if (index == _tabExplore)
          PaneActionEntry(
            icon: (appdata.settings['comicDisplayMode'] ?? 'detailed') ==
                    'detailed'
                ? Icons.view_agenda_outlined
                : Icons.grid_view_rounded,
            label: (appdata.settings['comicDisplayMode'] ?? 'detailed') ==
                    'detailed'
                ? "Brief".tl
                : "Detailed".tl,
            onTap: () {
              final current =
                  appdata.settings['comicDisplayMode'] ?? 'detailed';
              final next = current == 'detailed' ? 'brief' : 'detailed';
              appdata.settings['comicDisplayMode'] = next;
              // 详细模式在瀑布流里没有意义（瀑布流一律用简洁卡片），
              // 想切回详细就得同时回到网格，否则点了没有任何视觉变化。
              if (next == 'detailed' &&
                  (appdata.settings['comicLayoutMode'] ?? 'grid') ==
                      'staggered') {
                appdata.settings['comicLayoutMode'] = 'grid';
              }
              appdata.saveData();
              App.rootContext.showMessage(
                message: next == 'detailed'
                    ? "Switched to Detailed Mode".tl
                    : "Switched to Brief Mode".tl,
              );
              setState(() {});
            },
          ),
        // 年度阅读报告入口 - 仅首页显示，放在设置按钮旁边
        if (index == _tabHome)
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
