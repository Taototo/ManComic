import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/global_state.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/pages/categories_page.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';

/// 源页签栏的高度。
///
/// 这一行现在并进了顶栏那块玻璃（见 [NaviPane.headerBuilder]），高度要同时
/// 用于「顶栏的附加行」和「内容的顶部留白」，所以两边都读同一个常量：一边
/// 是 [ExplorePage.tabBarHeight]，一边是 `AppTabBar` 里的实际高度。
const _kExploreTabBarHeight = 48.0;

/// 「推荐 / 分类」分组的共享状态。
///
/// 这个切换控件现在长在顶栏的标题位上，而顶栏和页面是两棵互不相干的子树，
/// 分组状态必须提到它们共同的上层（[MainPage]）才不会被拆成两份。
///
/// 只做成一个 int + 监听，是因为页面真正需要的只有「现在是哪一组」：
/// 滚动控制器、页签控制器都还留在页面里。
class ExploreGroupController extends ChangeNotifier {
  ExploreGroupController({int group = 0}) : _group = group;

  int _group;

  int get group => _group;

  /// 再次点击当前页签时的回调（滚回顶部），由页面注入。
  ///
  /// 放在这里而不是让顶栏去翻页面的 GlobalState，是因为「回到顶部」对分类
  /// 和推荐两组各有一套逻辑，只有页面自己知道当前该滚哪个控制器。
  VoidCallback? onReselect;

  /// 顶栏附加行（源页签）的构造器，由页面注册。
  ///
  /// 页签栏要画在顶栏那块玻璃**里面**，而它的滚动控制器、页签控制器都在
  /// 页面里。让顶栏去「问页面要一行 widget」，比把整棵页签栏搬到上层、
  /// 再想办法把状态串过去要省事得多。
  Widget? Function(BuildContext context)? headerBuilder;

  /// 页签增减之后叫顶栏重画一次附加行。
  ///
  /// 只有「源 / 分类列表变了」这种非 build 期的改动需要显式叫一次；
  /// 分组切换本来就会 notify。
  void notifyHeaderChanged() => notifyListeners();

  /// 点页签：切换分组，或（点到当前页签时）回到顶部。
  void select(int value) {
    if (value == _group) {
      onReselect?.call();
      return;
    }
    _group = value;
    notifyListeners();
  }
}

/// 发现页。分类页也并入这里，通过顶部的分段控件在「发现 / 分类」之间切换。
class ExplorePage extends StatefulWidget {
  const ExplorePage({
    super.key,
    this.group,
  });

  /// 分组状态。为 null 时页面自己在内部维护一份（供测试或独立使用）。
  final ExploreGroupController? group;

  /// 源页签栏的高度。顶栏把它当作附加行的高度，页面把它当作内容顶部留白，
  /// 两边必须是同一个数。
  static const double tabBarHeight = _kExploreTabBarHeight;

  @override
  State<ExplorePage> createState() => _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin<ExplorePage> {
  late TabController exploreController;

  late TabController categoryController;

  bool showFB = true;

  double location = 0;

  late List<String> pages;

  late List<String> categories;

  /// 0 = 发现页，1 = 分类页
  int group = 0;

  /// 分组状态的上游（顶栏里的分段控件改的是它），页面只做镜像。
  void onGroupChanged() {
    if (!mounted) return;
    final value = widget.group?.group ?? group;
    if (value == group) return;
    setState(() {
      group = value;
      showFB = true;
    });
  }

  void onSettingsChanged() {
    var explorePages = List<String>.from(appdata.settings["explore_pages"]);
    var all = ComicSource.all()
        .map((e) => e.explorePages)
        .expand((e) => e.map((e) => e.title))
        .toList();
    explorePages = explorePages.where((e) => all.contains(e)).toList();
    var categoryKeys = loadCategoryKeys();
    var pagesChanged = !pages.isEqualTo(explorePages);
    var categoriesChanged = !categories.isEqualTo(categoryKeys);
    if (!pagesChanged && !categoriesChanged) {
      return;
    }
    setState(() {
      if (pagesChanged) {
        var old = exploreController;
        pages = explorePages;
        exploreController =
            TabController(length: pages.length, vsync: this);
        WidgetsBinding.instance
            .addPostFrameCallback((_) => old.dispose());
      }
      if (categoriesChanged) {
        var old = categoryController;
        categories = categoryKeys;
        categoryController =
            TabController(length: categories.length, vsync: this);
        WidgetsBinding.instance
            .addPostFrameCallback((_) => old.dispose());
      }
    });
    // 页签列表变了，但页签栏长在顶栏里，那棵子树不跟着本页重建。
    widget.group?.notifyHeaderChanged();
  }

  void onNaviItemTapped(int index) {
    // 底栏里的推荐页现在是第 2 项
    if (index != 1) return;
    _toTopCurrentGroup();
  }

  /// 当前分组（推荐/分类）的内容滚回顶部。
  /// 触发来源：再次点击底栏「推荐」或再次点击分段上的当前页签。
  void _toTopCurrentGroup() {
    if (group == 0) {
      if (pages.isEmpty) return;
      var i = exploreController.index;
      if (i < 0 || i >= pages.length) return;
      GlobalState.find<_SingleExplorePageState>(pages[i]).toTop();
    } else {
      if (categories.isEmpty) return;
      var i = categoryController.index;
      if (i < 0 || i >= categories.length) return;
      var c = _categoryControllers[categories[i]];
      if (c != null && c.hasClients) {
        c.animateTo(
          c.position.minScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
        );
      }
    }
  }

  void addPage() {
    showPopUpWidget(App.rootContext, setExplorePagesWidget());
  }

  void addCategoryPage() {
    showPopUpWidget(App.rootContext, setCategoryPagesWidget());
  }

  NaviPaneState? naviPane;

  /// 每个分类页签一个滚动控制器，用于再次点击页签时回到顶部。
  /// 分类页签数量很少，控制器随页面销毁统一释放。
  final Map<String, ScrollController> _categoryControllers = {};

  ScrollController _categoryController(String key) {
    return _categoryControllers.putIfAbsent(key, () => ScrollController());
  }

  @override
  void initState() {
    super.initState();
    group = widget.group?.group ?? 0;
    widget.group?.addListener(onGroupChanged);
    widget.group?.onReselect = _toTopCurrentGroup;
    pages = List<String>.from(appdata.settings["explore_pages"]);
    var all = ComicSource.all()
        .map((e) => e.explorePages)
        .expand((e) => e.map((e) => e.title))
        .toList();
    pages = pages.where((e) => all.contains(e)).toList();
    categories = loadCategoryKeys();
    exploreController = TabController(length: pages.length, vsync: this);
    categoryController = TabController(length: categories.length, vsync: this);
    appdata.settings.addListener(onSettingsChanged);
    // 源页签这一行要画进顶栏那块玻璃里，由顶栏来取。
    widget.group?.headerBuilder = buildHeader;
    NaviPane.of(context).addNaviItemTapListener(onNaviItemTapped);
  }

  @override
  void didChangeDependencies() {
    naviPane = NaviPane.of(context);
    super.didChangeDependencies();
  }

  @override
  void dispose() {
    exploreController.dispose();
    categoryController.dispose();
    for (var c in _categoryControllers.values) {
      c.dispose();
    }
    widget.group?.removeListener(onGroupChanged);
    // 只有自己还是当前注入的回调时才清，避免把后来者的覆盖掉。
    if (widget.group?.onReselect == _toTopCurrentGroup) {
      widget.group?.onReselect = null;
    }
    if (widget.group?.headerBuilder == buildHeader) {
      widget.group?.headerBuilder = null;
    }
    appdata.settings.removeListener(onSettingsChanged);
    naviPane?.removeNaviItemTapListener(onNaviItemTapped);
    super.dispose();
  }

  void refresh() {
    if (group != 0 || pages.isEmpty) return;
    var i = exploreController.index;
    if (i < 0 || i >= pages.length) return;
    GlobalState.find<_SingleExplorePageState>(pages[i]).refresh();
  }

  Widget buildFAB() => Material(
        color: Colors.transparent,
        child: FloatingActionButton(
          key: const Key("FAB"),
          onPressed: refresh,
          child: const Icon(Icons.refresh),
        ),
      );

  Tab buildTab(String i) {
    var comicSource = ComicSource.all()
        .firstWhere((e) => e.explorePages.any((e) => e.title == i));
    return Tab(text: i.ts(comicSource.key), key: Key(i));
  }

  Widget buildBody(String i) => Material(
        child: _SingleExplorePage(i, key: PageStorageKey(i)),
      );

  Widget buildCategoryBody(String key) => Material(
        child: CategoryView(
          key,
          key: PageStorageKey("category_$key"),
          controller: _categoryController(key),
        ),
      );

  /// 内容顶部的留白 = 顶栏（+ 源页签）占掉的高度。
  ///
  /// 必须付成**滚动容器内部**的 sliver padding：付在外面等于把列表从玻璃
  /// 下沿裁开，往上滑也钻不到玻璃后面去，顶栏那块玻璃就永远是空的。
  static Widget topInsetSliver(BuildContext context) => SliverPadding(
        padding: EdgeInsets.only(top: context.padding.top),
      );

  Widget buildExploreTabBar() {
    return Material(
      // 透明 Material 只为了给 InkWell 一个挂靠点：铺底色的话这条页签栏
      // 会在玻璃顶栏下面再压一条实色，顶上就看不到内容从玻璃后面穿过去了。
      type: MaterialType.transparency,
      child: AppTabBar(
        key: PageStorageKey("explore_tabs_${pages.join('|')}"),
        tabs: pages.map((e) => buildTab(e)).toList(),
        controller: exploreController,
        // 选中页签背后跟一块会滑动的玻璃，和「推荐 / 分类」同一套动效语言。
        glass: LiquidGlassEngine.enabled,
        // 双击已选页签：滚回顶部
        onTabReselect: _toTopCurrentGroup,
        actionButton: TabActionButton(
          icon: const Icon(Icons.add),
          text: "Add".tl,
          onPressed: addPage,
        ),
      ),
    );
  }

  Widget buildCategoryTabBar() {
    return Material(
      type: MaterialType.transparency,
      child: AppTabBar(
        key: PageStorageKey("category_tabs_${categories.join('|')}"),
        tabs: categories.map((e) {
          String title = e;
          try {
            title = getCategoryDataWithKey(e).title;
          } catch (e) {
            //
          }
          return Tab(text: title, key: Key(e));
        }).toList(),
        controller: categoryController,
        glass: LiquidGlassEngine.enabled,
        onTabReselect: _toTopCurrentGroup,
        actionButton: TabActionButton(
          icon: const Icon(Icons.add),
          text: "Add".tl,
          onPressed: addCategoryPage,
        ),
      ),
    );
  }

  Widget buildTabBar() {
    if (group == 1) {
      return categories.isEmpty
          ? const SizedBox(key: ValueKey("empty_category"))
          : KeyedSubtree(
              key: const ValueKey("category_tabs"),
              child: buildCategoryTabBar(),
            );
    }
    return pages.isEmpty
        ? const SizedBox(key: ValueKey("empty_explore"))
        : KeyedSubtree(
            key: const ValueKey("explore_tabs"),
            child: buildExploreTabBar(),
          );
  }

  /// 顶栏附加行：当前分组的源页签栏。
  ///
  /// 由 [ExploreGroupController.headerBuilder] 交给顶栏，在那块玻璃里长出来。
  /// 列表为空时返回 null，顶栏就不留这一行。
  Widget? buildHeader(BuildContext context) {
    if (group == 0 ? pages.isEmpty : categories.isEmpty) {
      return null;
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: buildTabBar(),
    );
  }

  Widget buildContent() {
    return NotificationListener<ScrollNotification>(
      onNotification: (notifications) {
        if (group != 0) {
          return false;
        }
        if (notifications.metrics.axis == Axis.horizontal) {
          if (!showFB) {
            setState(() {
              showFB = true;
            });
          }
          return true;
        }

        var current = notifications.metrics.pixels;
        var overflow = notifications.metrics.outOfRange;
        if (current > location && current != 0 && showFB) {
          setState(() {
            showFB = false;
          });
        } else if ((current < location - 50 || current == 0) && !showFB) {
          setState(() {
            showFB = true;
          });
        }
        if ((current > location || current < location - 50) && !overflow) {
          location = current;
        }
        return false;
      },
      // 注意：这里**不能**把顶部 padding 去掉（以前去过）。页面铺满整个
      // 屏幕，顶栏和源页签是盖在上面的两块玻璃，内容要靠 padding.top 自己
      // 让开它们；`MediaQuery.padding` 只是建议值，不会挪动任何布局，去掉
      // 之后列表第一行就直接钻到顶栏底下去了（分类页那种「标题被状态栏切了
      // 一半」就是它）。真正的留白在各内容自己的 sliver padding 里付。
      child: DirectionalIndexedStack(
        index: group,
        children: [
          pages.isEmpty
              ? const SizedBox()
              : TabBarView(
                  controller: exploreController,
                  children: pages.map((e) => buildBody(e)).toList(),
                ),
          categories.isEmpty
              ? const SizedBox()
              : TabBarView(
                  controller: categoryController,
                  children:
                      categories.map((e) => buildCategoryBody(e)).toList(),
                ),
        ],
      ),
    );
  }

  Widget buildEmpty() {
    if (ComicSource.isEmpty) {
      return EmptyState(
        icon: Icons.dashboard_customize_outlined,
        title: "No Comic Sources".tl,
        subtitle: "Add comic sources to start exploring".tl,
        withAppbar: false,
        actions: [
          FilledButton.icon(
            onPressed: () {
              context.to(() => ComicSourcePage());
            },
            icon: const Icon(Icons.add),
            label: Text("Add Source".tl),
          ),
        ],
      );
    } else if (group == 0) {
      return EmptyState(
        icon: Icons.explore_outlined,
        title: "No Explore Pages".tl,
        subtitle: "Select pages to display in explore section".tl,
        withAppbar: false,
        actions: [
          FilledButton.icon(
            onPressed: addPage,
            icon: const Icon(Icons.add),
            label: Text("Add Page".tl),
          ),
        ],
      );
    } else {
      return EmptyState(
        icon: Icons.category_outlined,
        title: "No Category Pages".tl,
        subtitle: "Select category pages to display".tl,
        withAppbar: false,
        actions: [
          FilledButton.icon(
            onPressed: addCategoryPage,
            icon: const Icon(Icons.add),
            label: Text("Add Page".tl),
          ),
        ],
      );
    }
  }

  /// 切换分组。控制器在场时交给它（顶栏的分段控件和这里共用一份状态），
  /// 不在场（单独使用本页）时退回内部状态。
  void selectGroup(int value) {
    final controller = widget.group;
    if (controller != null) {
      controller.select(value);
      return;
    }
    if (value == group) {
      _toTopCurrentGroup();
      return;
    }
    setState(() {
      group = value;
      showFB = true;
    });
  }

  /// 宽屏（侧栏模式）没有顶栏，分段控件得自己画在页面顶部。
  bool get _needsInlineSwitcher => naviPane == null || !naviPane!.hasTopBar;

  Widget buildInlineSwitcher() {
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 6 + context.padding.top, 12, 4),
      child: Center(
        child: GlassGroupSwitcher(
          index: group,
          labels: const ["Explore", "Categories"],
          onChanged: selectGroup,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (ComicSource.isEmpty) {
      return buildEmpty();
    }

    var hasContent = group == 0 ? pages.isNotEmpty : categories.isNotEmpty;
    final inlineSwitcher = _needsInlineSwitcher;

    Widget? fab;
    if (group == 0) {
      fab = Positioned(
        right: 16,
        // 底栏漂浮在页面之上，按钮要抬到底栏上面
        bottom: 16 + context.padding.bottom,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          reverseDuration: const Duration(milliseconds: 150),
          child: showFB ? buildFAB() : const SizedBox(),
          transitionBuilder: (widget, animation) {
            var tween = Tween<Offset>(
                begin: const Offset(0, 1), end: const Offset(0, 0));
            return SlideTransition(
              position: tween.animate(animation),
              child: widget,
            );
          },
        ),
      );
    }

    // 分组切换时两套页签交叉淡入淡出，高度固定 48，不会把内容顶下去。
    Widget tabBarSwitcher() => AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: buildTabBar(),
        );

    // 源页签栏平时是交给顶栏画的（和标题共用同一块玻璃），只有宽屏侧栏
    // 模式或没有分组控制器时才退回页面自己渲染。
    final headerInTopBar = !inlineSwitcher && widget.group != null;

    // 宽屏走侧栏，没有外层玻璃顶栏，页签栏照旧占一行。
    if (inlineSwitcher) {
      return Stack(
        children: [
          Positioned.fill(
            child: Column(
              children: [
                buildInlineSwitcher(),
                tabBarSwitcher(),
                Expanded(
                  // 顶部这段已经被上面两行让开了，内容不用再自己留白。
                  child: MediaQuery(
                    data: MediaQuery.of(context)
                        .removePadding(removeTop: true),
                    child: hasContent ? buildContent() : buildEmpty(),
                  ),
                ),
              ],
            ),
          ),
          if (fab != null) fab,
        ],
      );
    }

    final padding = context.padding;
    final stripHeight = hasContent ? _kExploreTabBarHeight : 0.0;

    return Stack(
      children: [
        // 内容铺满整个屏幕，靠 MediaQuery 把「顶栏（+ 源页签）」这段高度
        // 交给各内容，由它们自己付成滚动容器**内部**的留白——见 buildContent
        // 的注释。好处是：静止在顶部时第一行正好落在玻璃下沿，往上滑又整片
        // 穿到玻璃后面，顶栏始终有东西可以折射。
        Positioned.fill(
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: padding.copyWith(top: padding.top + stripHeight),
            ),
            child: hasContent ? buildContent() : buildEmpty(),
          ),
        ),
        // 回退分支：页签栏没交给顶栏时自己压一层玻璃。
        // （正常路径下这一行在顶栏里，和标题同一块玻璃，不会再出现
        // 「两条磨砂带叠在一起」的割裂感。）
        if (!headerInTopBar && hasContent)
          Positioned(
            left: 0,
            right: 0,
            top: padding.top,
            height: _kExploreTabBarHeight,
            child: LiquidGlassPanel(
              borderRadius: BorderRadius.zero,
              blur: 30,
              tintAlpha: Theme.of(context).brightness == Brightness.dark
                  ? 0.4
                  : 0.55,
              child: tabBarSwitcher(),
            ),
          ),
        if (fab != null) fab,
      ],
    );
  }

  @override
  bool get wantKeepAlive => true;
}

class _SingleExplorePage extends StatefulWidget {
  const _SingleExplorePage(this.title, {super.key});

  final String title;

  @override
  State<_SingleExplorePage> createState() => _SingleExplorePageState();
}

class _SingleExplorePageState extends AutomaticGlobalState<_SingleExplorePage>
    with AutomaticKeepAliveClientMixin<_SingleExplorePage> {
  late final ExplorePageData data;

  late final String comicSourceKey;

  bool _wantKeepAlive = true;

  var scrollController = ScrollController();

  VoidCallback? refreshHandler;

  void onSettingsChanged() {
    var explorePages = appdata.settings["explore_pages"];
    if (!explorePages.contains(widget.title)) {
      _wantKeepAlive = false;
      updateKeepAlive();
    }
  }

  @override
  void initState() {
    super.initState();
    for (var source in ComicSource.all()) {
      for (var d in source.explorePages) {
        if (d.title == widget.title) {
          data = d;
          comicSourceKey = source.key;
          return;
        }
      }
    }
    appdata.settings.addListener(onSettingsChanged);
    throw "Explore Page ${widget.title} Not Found!";
  }

  @override
  void dispose() {
    appdata.settings.removeListener(onSettingsChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (data.loadMultiPart != null) {
      return _MultiPartExplorePage(
        key: const PageStorageKey("comic_list"),
        data: data,
        controller: scrollController,
        comicSourceKey: comicSourceKey,
        refreshHandlerCallback: (c) {
          refreshHandler = c;
        },
      );
    } else if (data.loadPage != null || data.loadNext != null) {
      return ComicList(
        enablePageStorage: true,
        showUpdateTime: true,
        leadingSliver: _ExplorePageState.topInsetSliver(context),
        loadPage: data.loadPage,
        loadNext: data.loadNext,
        key: const PageStorageKey("comic_list"),
        controller: scrollController,
        refreshHandlerCallback: (c) {
          refreshHandler = c;
        },
      );
    } else if (data.loadMixed != null) {
      return _MixedExplorePage(
        data,
        comicSourceKey,
        key: const PageStorageKey("comic_list"),
        controller: scrollController,
        refreshHandlerCallback: (c) {
          refreshHandler = c;
        },
      );
    } else {
      return Center(
        child: Text("Empty Page".tl),
      );
    }
  }

  @override
  Object? get key => widget.title;

  @override
  void refresh() {
    refreshHandler?.call();
  }

  @override
  bool get wantKeepAlive => _wantKeepAlive;

  void toTop() {
    if (scrollController.hasClients) {
      scrollController.animateTo(
        scrollController.position.minScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
      );
    }
  }
}

class _MixedExplorePage extends StatefulWidget {
  const _MixedExplorePage(this.data, this.sourceKey,
      {super.key, this.controller, required this.refreshHandlerCallback});

  final ExplorePageData data;

  final String sourceKey;

  final ScrollController? controller;

  final void Function(VoidCallback c) refreshHandlerCallback;

  @override
  State<_MixedExplorePage> createState() => _MixedExplorePageState();
}

class _MixedExplorePageState
    extends MultiPageLoadingState<_MixedExplorePage, Object> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    widget.refreshHandlerCallback(refresh);
  }

  void refresh() {
    reset();
  }

  Iterable<Widget> buildSlivers(BuildContext context, List<Object> data) sync* {
    List<Comic> cache = [];
    for (var part in data) {
      if (part is ExplorePagePart) {
        if (cache.isNotEmpty) {
          yield SliverGridComics(
            comics: (cache),
            showUpdateTime: true,
          );
          yield const SliverToBoxAdapter(child: Divider());
          cache.clear();
        }
        yield* _buildExplorePagePart(part, widget.sourceKey);
        yield const SliverToBoxAdapter(child: Divider());
      } else {
        cache.addAll(part as List<Comic>);
      }
    }
    if (cache.isNotEmpty) {
      yield SliverGridComics(
        comics: (cache),
        showUpdateTime: true,
      );
    }
  }

  @override
  Widget buildContent(BuildContext context, List<Object> data) {
    return SmoothCustomScrollView(
      controller: widget.controller,
      slivers: [
        _ExplorePageState.topInsetSliver(context),
        ...buildSlivers(context, data),
        const SliverListLoadingIndicator(),
      ],
    );
  }

  @override
  Future<Res<List<Object>>> loadData(int page) async {
    var res = await widget.data.loadMixed!(page);
    if (res.error) {
      return res;
    }
    for (var element in res.data) {
      if (element is! ExplorePagePart && element is! List<Comic>) {
        return const Res.error("function loadMixed return invalid data");
      }
    }
    return res;
  }
}

Iterable<Widget> _buildExplorePagePart(
    ExplorePagePart part, String sourceKey) sync* {
  Widget buildTitle(ExplorePagePart part) {
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 60,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 5, 10),
          child: Row(
            children: [
              Text(
                part.title,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
              ),
              const Spacer(),
              if (part.viewMore != null)
                TextButton(
                  onPressed: () {
                    var context = App.mainNavigatorKey!.currentContext!;
                    part.viewMore!.jump(context);
                  },
                  child: Text("View more".tl),
                )
            ],
          ),
        ),
      ),
    );
  }

  Widget buildComics(ExplorePagePart part) {
    return SliverGridComics(comics: part.comics, showUpdateTime: true);
  }

  yield buildTitle(part);
  yield buildComics(part);
}

class _MultiPartExplorePage extends StatefulWidget {
  const _MultiPartExplorePage({
    super.key,
    required this.data,
    required this.controller,
    required this.comicSourceKey,
    required this.refreshHandlerCallback,
  });

  final ExplorePageData data;

  final ScrollController controller;

  final String comicSourceKey;

  final void Function(VoidCallback c) refreshHandlerCallback;

  @override
  State<_MultiPartExplorePage> createState() => _MultiPartExplorePageState();
}

class _MultiPartExplorePageState extends State<_MultiPartExplorePage> {
  late final ExplorePageData data;

  List<ExplorePagePart>? parts;

  bool loading = true;

  String? message;

  Map<String, dynamic> get state => {
        "loading": loading,
        "message": message,
        "parts": parts,
      };

  void restoreState(dynamic state) {
    if (state == null) return;
    loading = state["loading"];
    message = state["message"];
    parts = state["parts"];
  }

  void storeState() {
    PageStorage.of(context).writeState(context, state);
  }

  void refresh() {
    setState(() {
      loading = true;
      message = null;
      parts = null;
    });
    storeState();
  }

  @override
  void initState() {
    super.initState();
    data = widget.data;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    restoreState(PageStorage.of(context).readState(context));
    widget.refreshHandlerCallback(refresh);
  }

  void load() async {
    var res = await data.loadMultiPart!();
    loading = false;
    if (mounted) {
      setState(() {
        if (res.error) {
          message = res.errorMessage;
        } else {
          parts = res.data;
        }
      });
      storeState();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      load();
      return const Center(
        child: FiveDotLoadingAnimation(),
      );
    } else if (message != null) {
      return NetworkError(
        message: message!,
        retry: () {
          setState(() {
            loading = true;
            message = null;
          });
        },
        withAppbar: false,
      );
    } else {
      return buildPage();
    }
  }

  Widget buildPage() {
    return SmoothCustomScrollView(
      key: const PageStorageKey('scroll'),
      controller: widget.controller,
      slivers: [
        _ExplorePageState.topInsetSliver(context),
        ..._buildPage(),
      ],
    );
  }

  Iterable<Widget> _buildPage() sync* {
    for (var part in parts!) {
      yield* _buildExplorePagePart(part, widget.comicSourceKey);
    }
  }
}
