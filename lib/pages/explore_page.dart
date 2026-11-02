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

/// 发现页。分类页也并入这里，通过顶部的分段控件在「发现 / 分类」之间切换。
class ExplorePage extends StatefulWidget {
  const ExplorePage({super.key});

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

  Widget buildSegment() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      child: Center(
        child: _GroupSwitcher(
          index: group,
          labels: const ["Explore", "Categories"],
          onChanged: (i) {
            if (i == group) {
              // 再次点击当前页签：滚回顶部
              _toTopCurrentGroup();
              return;
            }
            setState(() {
              group = i;
              showFB = true;
            });
          },
        ),
      ),
    );
  }

  Widget buildExploreTabBar() {
    return Material(
      child: AppTabBar(
        key: PageStorageKey("explore_tabs_${pages.join('|')}"),
        tabs: pages.map((e) => buildTab(e)).toList(),
        controller: exploreController,
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
      child: MediaQuery.removePadding(
        context: context,
        removeTop: true,
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

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (ComicSource.isEmpty) {
      return buildEmpty();
    }

    var hasContent = group == 0 ? pages.isNotEmpty : categories.isNotEmpty;

    return Stack(
      children: [
        Positioned.fill(
          child: Column(
            children: [
              buildSegment().paddingTop(context.padding.top),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: buildTabBar(),
              ),
              Expanded(
                child: hasContent ? buildContent() : buildEmpty(),
              ),
            ],
          ),
        ),
        if (group == 0)
          Positioned(
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
          )
      ],
    );
  }

  @override
  bool get wantKeepAlive => true;
}

/// 「发现 / 分类」分段切换控件。
class _GroupSwitcher extends StatelessWidget {
  const _GroupSwitcher({
    required this.index,
    required this.labels,
    required this.onChanged,
  });

  final int index;

  final List<String> labels;

  final void Function(int) onChanged;

  static const _itemWidth = 76.0;

  static const _height = 30.0;

  static const _padding = 3.0;

  @override
  Widget build(BuildContext context) {
    final cs = context.colorScheme;
    final itemHeight = _height - _padding * 2;
    return Container(
      height: _height,
      padding: const EdgeInsets.all(_padding),
      decoration: BoxDecoration(
        color: cs.onSurface.toOpacity(0.06),
        borderRadius: BorderRadius.circular(_height / 2),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              alignment:
                  index == 0 ? Alignment.centerLeft : Alignment.centerRight,
              child: Container(
                width: _itemWidth,
                height: itemHeight,
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(itemHeight / 2),
                  border: Border.all(
                    color: cs.outlineVariant.toOpacity(0.6),
                    width: 0.6,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.toOpacity(0.08),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < labels.length; i++)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(i),
                  child: SizedBox(
                    width: _itemWidth,
                    height: itemHeight,
                    child: Center(
                      child: AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: i == index
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: i == index
                              ? cs.onSurface
                              : cs.onSurface.toOpacity(0.6),
                        ),
                        child: Text(labels[i].tl),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
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
      return const Center(
        child: Text("Empty Page"),
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
      slivers: _buildPage().toList(),
    );
  }

  Iterable<Widget> _buildPage() sync* {
    for (var part in parts!) {
      yield* _buildExplorePagePart(part, widget.comicSourceKey);
    }
  }
}
