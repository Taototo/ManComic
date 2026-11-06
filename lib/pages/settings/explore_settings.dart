part of 'settings_page.dart';

/// 「内容来源」分组：每个页面显示哪些源、默认搜哪里、按语言过滤。
///
/// 这些设置原来是「探索」页设置的全部内容，但其中一半根本不属于探索页——
/// 分类页、网络收藏页、搜索源各自是独立页面。现在作为功能页里的一组。
List<Widget> contentSourceSlivers() => [
      _PopupWindowSetting(
        title: "Explore Pages".tl,
        builder: setExplorePagesWidget,
      ).toSliver(),
      _PopupWindowSetting(
        title: "Category Pages".tl,
        builder: setCategoryPagesWidget,
      ).toSliver(),
      _PopupWindowSetting(
        title: "Network Favorite Pages".tl,
        builder: setFavoritesPagesWidget,
      ).toSliver(),
      _PopupWindowSetting(
        title: "Search Sources".tl,
        builder: setSearchSourcesWidget,
      ).toSliver(),
      SelectSetting(
        title: "Default Search Target".tl,
        settingKey: "defaultSearchTarget",
        optionTranslation: {
          '_aggregated_': "Aggregated".tl,
          ...() {
            var map = <String, String>{};
            for (var c in ComicSource.all()) {
              map[c.key] = c.name;
            }
            return map;
          }(),
        },
      ).toSliver(),
      SelectSetting(
        title: "Auto Language Filters".tl,
        settingKey: "autoAddLanguageFilter",
        optionTranslation: {
          'none': "None".tl,
          'chinese': "Chinese",
          'english': "English",
          'japanese': "Japanese",
        },
      ).toSliver(),
    ];

/// 「过滤与屏蔽」分组：标题关键词和评论关键词。
List<Widget> keywordFilterSlivers() => [
      _PopupWindowSetting(
        title: "Keyword blocking".tl,
        builder: () => const _ManageBlockingWordView(),
      ).toSliver(),
      _PopupWindowSetting(
        title: "Comment keyword blocking".tl,
        builder: () => const _ManageBlockingCommentWordView(),
      ).toSliver(),
    ];

class _ManageBlockingWordView extends StatefulWidget {
  const _ManageBlockingWordView();

  @override
  State<_ManageBlockingWordView> createState() =>
      _ManageBlockingWordViewState();
}

class _ManageBlockingWordViewState extends State<_ManageBlockingWordView> {
  @override
  Widget build(BuildContext context) {
    assert(appdata.settings["blockedWords"] is List);
    return PopUpWidgetScaffold(
      title: "Keyword blocking".tl,
      tailing: [
        TextButton.icon(
          icon: const Icon(Icons.add),
          label: Text("Add".tl),
          onPressed: add,
        ),
      ],
      body: ListView.builder(
        itemCount: appdata.settings["blockedWords"].length,
        itemBuilder: (context, index) {
          return ListTile(
            title: Text(appdata.settings["blockedWords"][index]),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                appdata.settings["blockedWords"].removeAt(index);
                appdata.saveData();
                setState(() {});
              },
            ),
          );
        },
      ),
    );
  }

  void add() {
    showDialog(
      context: App.rootContext,
      builder: (context) {
        var controller = TextEditingController();
        String? error;
        return StatefulBuilder(builder: (context, setState) {
          return ContentDialog(
            title: "Add keyword".tl,
            content: TextField(
              controller: controller,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                label: Text("Keyword".tl),
                errorText: error,
              ),
              onChanged: (s) {
                if (error != null) {
                  setState(() {
                    error = null;
                  });
                }
              },
            ).paddingHorizontal(12),
            actions: [
              Button.filled(
                onPressed: () {
                  if (appdata.settings["blockedWords"]
                      .contains(controller.text)) {
                    setState(() {
                      error = "Keyword already exists".tl;
                    });
                    return;
                  }
                  appdata.settings["blockedWords"].add(controller.text);
                  appdata.saveData();
                  this.setState(() {});
                  context.pop();
                },
                child: Text("Add".tl),
              ),
            ],
          );
        });
      },
    );
  }
}

Widget setExplorePagesWidget() {
  var pages = <String, String>{};
  for (var c in ComicSource.all()) {
    for (var page in c.explorePages) {
      pages[page.title] = page.title.ts(c.key);
    }
  }
  return _MultiPagesFilter(
    title: "Explore Pages".tl,
    settingsIndex: "explore_pages",
    pages: pages,
  );
}

Widget setCategoryPagesWidget() {
  var pages = <String, String>{};
  for (var c in ComicSource.all()) {
    if (c.categoryData != null) {
      pages[c.categoryData!.key] = c.categoryData!.title;
    }
  }
  return _MultiPagesFilter(
    title: "Category Pages".tl,
    settingsIndex: "categories",
    pages: pages,
  );
}

Widget setFavoritesPagesWidget() {
  var pages = <String, String>{};
  for (var c in ComicSource.all()) {
    if (c.favoriteData != null) {
      pages[c.favoriteData!.key] = c.favoriteData!.title;
    }
  }
  return _MultiPagesFilter(
    title: "Network Favorite Pages".tl,
    settingsIndex: "favorites",
    pages: pages,
  );
}

Widget setSearchSourcesWidget() {
  var pages = <String, String>{};
  for (var c in ComicSource.all()) {
    if (c.searchPageData != null) {
      pages[c.key] = c.name;
    }
  }
  return _MultiPagesFilter(
    title: "Search Sources".tl,
    settingsIndex: "searchSources",
    pages: pages,
  );
}

class _ManageBlockingCommentWordView extends StatefulWidget {
  const _ManageBlockingCommentWordView();

  @override
  State<_ManageBlockingCommentWordView> createState() =>
      _ManageBlockingCommentWordViewState();
}

class _ManageBlockingCommentWordViewState
    extends State<_ManageBlockingCommentWordView> {
  @override
  Widget build(BuildContext context) {
    assert(appdata.settings["blockedCommentWords"] is List);
    return PopUpWidgetScaffold(
      title: "Comment keyword blocking".tl,
      tailing: [
        TextButton.icon(
          icon: const Icon(Icons.add),
          label: Text("Add".tl),
          onPressed: add,
        ),
      ],
      body: ListView.builder(
        itemCount: appdata.settings["blockedCommentWords"].length,
        itemBuilder: (context, index) {
          return ListTile(
            title: Text(appdata.settings["blockedCommentWords"][index]),
            trailing: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () {
                appdata.settings["blockedCommentWords"].removeAt(index);
                appdata.saveData();
                setState(() {});
              },
            ),
          );
        },
      ),
    );
  }

  void add() {
    showDialog(
      context: App.rootContext,
      builder: (context) {
        var controller = TextEditingController();
        String? error;
        return StatefulBuilder(builder: (context, setState) {
          return ContentDialog(
            title: "Add keyword".tl,
            content: TextField(
              controller: controller,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                label: Text("Keyword".tl),
                errorText: error,
              ),
              onChanged: (s) {
                if (error != null) {
                  setState(() {
                    error = null;
                  });
                }
              },
            ).paddingHorizontal(12),
            actions: [
              Button.filled(
                onPressed: () {
                  if (appdata.settings["blockedCommentWords"]
                      .contains(controller.text)) {
                    setState(() {
                      error = "Keyword already exists".tl;
                    });
                    return;
                  }
                  appdata.settings["blockedCommentWords"].add(controller.text);
                  appdata.saveData();
                  this.setState(() {});
                  context.pop();
                },
                child: Text("Add".tl),
              ),
            ],
          );
        });
      },
    );
  }
}
