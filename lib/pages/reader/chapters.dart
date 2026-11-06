part of 'reader.dart';

class _ChaptersView extends StatefulWidget {
  const _ChaptersView(this.reader);

  final _ReaderState reader;

  @override
  State<_ChaptersView> createState() => _ChaptersViewState();
}

class _ChaptersViewState extends State<_ChaptersView> {
  bool desc = false;

  late final ScrollController _scrollController;

  final TextEditingController _searchController = TextEditingController();

  String query = '';

  var downloaded = <String>[];

  @override
  void initState() {
    super.initState();
    int epIndex = widget.reader.chapter - 2;
    _scrollController = ScrollController(
      initialScrollOffset: (epIndex * 48.0 + 52).clamp(0, double.infinity),
    );
    var local = LocalManager().find(widget.reader.cid, widget.reader.type);
    if (local != null) {
      downloaded = local.downloadedChapters;
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var chapters = widget.reader.widget.chapters!;
    var current = widget.reader.chapter - 1;
    final titles = chapters.titles.toList();
    final searching = query.trim().isNotEmpty;
    // 搜索时按相关度排（章号命中优先），不再按升降序翻转，
    // 否则「输入 380」的结果会被翻到最后一条。
    final indices = searchChapters(titles, query);
    return Scaffold(
      body: SmoothCustomScrollView(
        controller: searching ? null : _scrollController,
        slivers: [
          SliverAppbar(
            style: AppbarStyle.shadow,
            title: Text("Chapters".tl),
            actions: [
              Tooltip(
                message: "Click to change the order".tl,
                child: TextButton.icon(
                  icon: Icon(
                    !desc ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 18,
                  ),
                  label: Text(!desc ? "Ascending".tl : "Descending".tl),
                  onPressed: () {
                    setState(() {
                      desc = !desc;
                    });
                  },
                ),
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: _ChapterSearchBar(
              controller: _searchController,
              onChanged: (value) {
                setState(() {
                  query = value;
                });
              },
            ),
          ),
          if (indices.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptySearchResult(),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final i = searching
                    ? indices[index]
                    : (desc ? titles.length - 1 - index : index);
                var chapter = titles[i];
                return _ChapterListTile(
                  onTap: () {
                    widget.reader.toChapter(i + 1);
                    Navigator.of(context).pop();
                  },
                  title: chapter,
                  isActive: current == i,
                  isDownloaded: downloaded.contains(chapters.ids.elementAt(i)),
                );
              }, childCount: searching ? indices.length : titles.length),
            ),
        ],
      ),
    );
  }
}

class _GroupedChaptersView extends StatefulWidget {
  const _GroupedChaptersView(this.reader);

  final _ReaderState reader;

  @override
  State<_GroupedChaptersView> createState() => _GroupedChaptersViewState();
}

class _GroupedChaptersViewState extends State<_GroupedChaptersView>
    with SingleTickerProviderStateMixin {
  ComicChapters get chapters => widget.reader.widget.chapters!;

  late final TabController tabController;

  late final ScrollController _scrollController;

  late final String initialGroupName;

  final TextEditingController _searchController = TextEditingController();

  String query = '';

  var downloaded = <String>[];

  @override
  void initState() {
    super.initState();
    int index = 0;
    int epIndex = widget.reader.chapter - 1;
    while (epIndex >= 0) {
      epIndex -= chapters.getGroupByIndex(index).length;
      index++;
    }
    tabController = TabController(
      length: chapters.groups.length,
      vsync: this,
      initialIndex: index - 1,
    );
    initialGroupName = chapters.groups.elementAt(index - 1);
    var epIndexAtGroup = widget.reader.chapter - 1;
    for (var i = 0; i < index - 1; i++) {
      epIndexAtGroup -= chapters.getGroupByIndex(i).length;
    }
    _scrollController = ScrollController(
      initialScrollOffset: (epIndexAtGroup * 48.0).clamp(0, double.infinity),
    );
    var local = LocalManager().find(widget.reader.cid, widget.reader.type);
    if (local != null) {
      downloaded = local.downloadedChapters;
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final searching = query.trim().isNotEmpty;
    final titles = chapters.titles.toList();
    final indices = searchChapters(titles, query);
    return Column(
      children: [
        Appbar(title: Text("Chapters".tl)),
        _ChapterSearchBar(
          controller: _searchController,
          onChanged: (value) {
            setState(() {
              query = value;
            });
          },
        ),
        if (searching)
          // 分组视图下搜索不按 tab 过滤，而是在全部章节里找——用户输入
          // 章号时并不知道它落在哪个分组里，让他先切 tab 是多余的一步。
          Expanded(
            child: indices.isEmpty
                ? const _EmptySearchResult()
                : SmoothCustomScrollView(
                    slivers: [
                      SliverList(
                        delegate: SliverChildBuilderDelegate((context, index) {
                          final i = indices[index];
                          return _ChapterListTile(
                            onTap: () {
                              widget.reader.toChapter(i + 1);
                              context.pop();
                            },
                            title: titles[i],
                            isActive: widget.reader.chapter == i + 1,
                            isDownloaded: downloaded.contains(
                              chapters.ids.elementAt(i),
                            ),
                          );
                        }, childCount: indices.length),
                      ),
                    ],
                  ),
          )
        else ...[
          AppTabBar(
            controller: tabController,
            tabs: chapters.groups.map((e) => Tab(text: e)).toList(),
          ),
          Expanded(
            child: TabViewBody(
              controller: tabController,
              children: chapters.groups.map(buildGroup).toList(),
            ),
          ),
        ],
      ],
    );
  }

  Widget buildGroup(String groupName) {
    var group = chapters.getGroup(groupName);
    return SmoothCustomScrollView(
      controller: initialGroupName == groupName ? _scrollController : null,
      slivers: [
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              var name = group.values.elementAt(index);
              var i = 0;
              for (var g in chapters.groups) {
                if (g == groupName) {
                  break;
                }
                i += chapters.getGroup(g).length;
              }
              i += index + 1;
              return _ChapterListTile(
                onTap: () {
                  widget.reader.toChapter(i);
                  context.pop();
                },
                title: name,
                isActive: widget.reader.chapter == i,
                isDownloaded: downloaded.contains(group.keys.elementAt(index)),
              );
            },
            childCount: group.length,
          ),
        ),
      ],
    );
  }
}

class _ChapterSearchBar extends StatelessWidget {
  const _ChapterSearchBar({required this.controller, required this.onChanged});

  final TextEditingController controller;

  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: ts.s14,
        decoration: InputDecoration(
          isDense: true,
          hintText: "Search by title or chapter number".tl,
          hintStyle: ts.s14.withColor(
            context.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: "Clear".tl,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(
              color: context.colorScheme.outlineVariant,
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptySearchResult extends StatelessWidget {
  const _EmptySearchResult();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          "No chapters matched".tl,
          textAlign: TextAlign.center,
          style: ts.s14.withColor(context.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

class _ChapterListTile extends StatelessWidget {
  const _ChapterListTile({
    required this.title,
    required this.isActive,
    required this.isDownloaded,
    required this.onTap,
  });

  final String title;

  final bool isActive;

  final bool isDownloaded;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color:
                  isActive ? context.colorScheme.primary : Colors.transparent,
              width: 4,
            ),
          ),
        ),
        child: Row(
          children: [
            Text(
              title,
              style: isActive
                  ? ts.withColor(context.colorScheme.primary).bold.s16
                  : ts.s16,
            ),
            const Spacer(),
            if (isDownloaded)
              Icon(
                Icons.download_done_rounded,
                color: context.colorScheme.secondary,
              ),
          ],
        ),
      ),
    );
  }
}
