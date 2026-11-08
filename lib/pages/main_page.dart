import 'package:flutter/material.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/pages/comic_source_page.dart';
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
    _pages = [
      ExplorePage(
        key: const PageStorageKey('explore'),
        group: _exploreGroup,
      ),
      const HomePage(),
      FavoritesPage(
        key: const PageStorageKey('favorites'),
        folders: _favoritesFolders,
        topBar: _favoritesTopBar,
      ),
    ];
    _favoritesTopBar.addListener(onFavoritesTopBarChanged);
    super.initState();
  }

  /// 「推荐 / 分类」分组。切换控件在顶栏标题位上，状态放在这里，
  /// 顶栏和推荐页都能看到同一份。
  final _exploreGroup = ExploreGroupController();

  /// 收藏夹抽屉的入口，由收藏页注册（见 [FavoritesFolderController]）。
  final _favoritesFolders = FavoritesFolderController();

  /// 收藏页交给顶栏的内容（文件夹名 + 排序 / 多选 / 搜索 / 更多）。
  ///
  /// 收藏页原来自己有一条标题栏，就压在玻璃顶栏下面，等于顶上多一条实色
  /// 横杠、同一屏两个搜索图标。现在那条栏去掉，标题和按钮都从这里进顶栏。
  final _favoritesTopBar = FavoritesTopBarController();

  void onFavoritesTopBarChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  late final List<Widget> _pages;

  @override
  void dispose() {
    _favoritesTopBar.removeListener(onFavoritesTopBarChanged);
    _favoritesTopBar.dispose();
    _exploreGroup.dispose();
    super.dispose();
  }

  var index = 0;

  @override
  Widget build(BuildContext context) {
    return NaviPane(
      initialPage: index,
      observer: _observer,
      navigatorKey: _navigatorKey!,
      // 主页不再显示标题字：顶栏只剩一块玻璃，内容直接长在它下面，
      // 和推荐页的观感统一。推荐页把标题位让给「推荐 / 分类」分段控件，
      // 收藏页则显示当前文件夹名——那条栏去掉以后，这里是唯一还写着
      // 「我在哪个文件夹」的地方。
      titleBuilder: (page, context) {
        if (page == _tabFavorites) {
          final title = _favoritesTopBar.title;
          if (title == null || title.isEmpty) {
            return const SizedBox.shrink();
          }
          // 点文件夹名就开抽屉：原来那条栏里标题本来就是这个作用，
          // 现在图标位被 6 颗按钮占满，标题这一下正好补上。
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _favoritesFolders.open?.call(),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          );
        }
        if (page != _tabExplore) {
          return const SizedBox.shrink();
        }
        return AnimatedBuilder(
          animation: _exploreGroup,
          builder: (context, _) {
            return GlassGroupSwitcher(
              index: _exploreGroup.group,
              labels: const ["Explore", "Categories"],
              onChanged: _exploreGroup.select,
            );
          },
        );
      },
      // 推荐页的源页签并进顶栏这块玻璃：顶栏高度加一行 48，页面再把内容
      // 整体让开这么多。两段玻璃合起来看就是一整块，不再有自己的磨砂底
      // 和自己的边缘高光。
      headerBuilder: (page, context) {
        if (page != _tabExplore) {
          return null;
        }
        return AnimatedBuilder(
          animation: _exploreGroup,
          builder: (context, _) =>
              _exploreGroup.headerBuilder?.call(context) ??
              const SizedBox.shrink(),
        );
      },
      headerHeight: (page) => page == _tabExplore ? ExplorePage.tabBarHeight : 0,
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
        // 收藏页自己的按钮（同步 / 排序 / 多选 / 搜索 / 更多）。原来它们长在
        // 页面那条标题栏里，现在整条搬到顶栏，由页面登记、这里拼进来。
        if (index == _tabFavorites) ..._favoritesTopBar.actions,
        // 收藏夹抽屉的入口。原来它长在收藏页自己的标题栏里（那一栏已经
        // 去掉，页面顶部才能和主页一致），现在提到顶栏图标位上。
        if (index == _tabFavorites)
          PaneActionEntry(
            icon: Icons.folder_outlined,
            label: "Folders".tl,
            onTap: () => _favoritesFolders.open?.call(),
          ),
        // 收藏页自带「在当前文件夹里搜」的放大镜，这里再放一个全局搜索就是
        // 同一屏两颗放大镜（原来截图里那两个就是这么来的）。
        if (index != _tabHome && index != _tabFavorites)
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
        // 源设置放在首页顶栏：源挂了是「打开首页发现什么都刷不出来」的第一
        // 嫌疑人，而原先进源管理要绕三层（设置 → 内容 → 漫画源）。
        if (index == _tabHome)
          PaneActionEntry(
            icon: Icons.dns_outlined,
            label: "Comic Sources".tl,
            onTap: () {
              to(() => const ComicSourcePage(), preventDuplicate: true);
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
