import "package:flutter/material.dart";
import 'package:shimmer_animation/shimmer_animation.dart';
import "package:venera/components/components.dart";
import "package:venera/foundation/app.dart";
import "package:venera/foundation/appdata.dart";
import "package:venera/foundation/comic_source/comic_source.dart";
import "package:venera/pages/comic_details_page/comic_page.dart";
import "package:venera/pages/search_result_page.dart";
import "package:venera/utils/translations.dart";

class AggregatedSearchPage extends StatefulWidget {
  const AggregatedSearchPage({super.key, required this.keyword});

  final String keyword;

  @override
  State<AggregatedSearchPage> createState() => _AggregatedSearchPageState();
}

class _AggregatedSearchPageState extends State<AggregatedSearchPage> {
  late final List<ComicSource> sources;

  late final SearchBarController controller;

  var _keyword = "";

  /// 是否把同一个作品在多个源的结果合并成一条
  bool _merged = false;

  /// 各源已经加载好的结果，用于合并视图
  final Map<String, List<Comic>> _results = {};

  final Set<String> _loading = {};

  /// 加载单个源的搜索结果（聚合页与合并视图共用）
  static Future<({List<Comic>? comics, String? error})> loadSource(
    ComicSource source,
    String keyword,
  ) async {
    final data = source.searchPageData;
    if (data == null) {
      return (comics: null, error: null);
    }
    final options = (data.searchOptions ?? []).map((e) => e.defaultValue).toList();
    if (data.loadPage != null) {
      final res = await data.loadPage!(keyword, 1, options);
      return (comics: res.error ? null : res.data, error: res.error ? (res.errorMessage ?? "Unknown error") : null);
    } else if (data.loadNext != null) {
      final res = await data.loadNext!(keyword, null, options);
      return (comics: res.error ? null : res.data, error: res.error ? (res.errorMessage ?? "Unknown error") : null);
    }
    return (comics: null, error: null);
  }

  void _onResultLoaded(String sourceKey, List<Comic> comics) {
    if (_results[sourceKey] == comics) return;
    setState(() {
      _results[sourceKey] = comics;
    });
  }

  /// 合并视图下兜底加载所有源
  void _ensureAllLoaded() {
    for (final source in sources) {
      if (_results.containsKey(source.key) || _loading.contains(source.key)) {
        continue;
      }
      _loading.add(source.key);
      loadSource(source, _keyword).then((res) {
        _loading.remove(source.key);
        if (!mounted) return;
        setState(() {
          _results[source.key] = res.comics ?? [];
        });
      });
    }
  }

  String _normalizeTitle(String title) {
    return title
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), '')
        .replaceAll(RegExp(r'[\[\]（）()【】<>《》「」『』:：,，.。!！?？\-—_]'), '');
  }

  List<(Comic, int)> get _clusters {
    final map = <String, List<Comic>>{};
    for (final entry in _results.entries) {
      for (final comic in entry.value) {
        final key = _normalizeTitle(comic.title);
        if (key.isEmpty) continue;
        map.putIfAbsent(key, () => []).add(comic);
      }
    }
    final list = map.values.map((e) => (e.first, e.length)).toList();
    list.sort((a, b) => a.$1.title.compareTo(b.$1.title));
    return list;
  }

  void _showSourcePicker(BuildContext context, String title) {
    final key = _normalizeTitle(title);
    final items = <Comic>[];
    for (final entry in _results.entries) {
      for (final comic in entry.value) {
        if (_normalizeTitle(comic.title) == key) {
          items.add(comic);
        }
      }
    }
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(title, style: ts.s16, maxLines: 2),
              ),
              for (final comic in items)
                ListTile(
                  dense: true,
                  title: Text(
                    ComicSource.find(comic.sourceKey)?.name ?? comic.sourceKey,
                  ),
                  subtitle: comic.subtitle == null || comic.subtitle!.isEmpty
                      ? null
                      : Text(comic.subtitle!, maxLines: 1),
                  onTap: () {
                    Navigator.of(context).pop();
                    context.to(
                      () => ComicPage(
                        id: comic.id,
                        sourceKey: comic.sourceKey,
                        cover: comic.cover,
                        title: comic.title,
                      ),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  void initState() {
    var all = ComicSource.all()
        .where((e) => e.searchPageData != null)
        .map((e) => e.key)
        .toList();
    var settings = appdata.settings['searchSources'] as List;
    var sources = <String>[];
    for (var source in settings) {
      if (all.contains(source)) {
        sources.add(source);
      }
    }
    this.sources = sources.map((e) => ComicSource.find(e)!).toList();
    _keyword = widget.keyword;
    controller = SearchBarController(
      currentText: widget.keyword,
      onSearch: (text) {
        setState(() {
          _keyword = text;
        });
      },
    );
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final merged = _merged;
    if (merged) {
      _ensureAllLoaded();
    }
    return SmoothCustomScrollView(slivers: [
      SliverSearchBar(controller: controller),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              FilterChip(
                label: Text("Merge same comic".tl),
                selected: merged,
                onSelected: (value) {
                  setState(() {
                    _merged = value;
                  });
                },
              ),
              const SizedBox(width: 8),
              if (merged)
                Text(
                  _results.length >= sources.length
                      ? "${_clusters.length} 部作品".tl
                      : "Loading".tl,
                  style: ts.s10.withColor(context.colorScheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
      ),
      if (!merged)
        SliverList(
          key: ValueKey(_keyword),
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final source = sources[index];
              return _SliverSearchResult(
                key: ValueKey(source.key),
                source: source,
                keyword: _keyword,
                onLoaded: (comics) => _onResultLoaded(source.key, comics),
              );
            },
            childCount: sources.length,
          ),
        )
      else
        SliverGridComics(
          comics: _clusters.map((e) => e.$1).toList(),
          badgeBuilder: (c) {
            for (final cluster in _clusters) {
              if (identical(cluster.$1, c)) {
                return cluster.$2 > 1
                    ? "@a sources".tlParams({"a": "${cluster.$2}"})
                    : null;
              }
            }
            return null;
          },
          onTap: (comic, heroID) {
            _showSourcePicker(context, comic.title);
          },
        ),
    ]);
  }
}

class _SliverSearchResult extends StatefulWidget {
  const _SliverSearchResult({
    required this.source,
    required this.keyword,
    this.onLoaded,
    super.key,
  });

  final ComicSource source;

  final String keyword;

  /// 结果加载完成后回传给聚合页，供「合并同一作品」使用
  final void Function(List<Comic> comics)? onLoaded;

  @override
  State<_SliverSearchResult> createState() => _SliverSearchResultState();
}

class _SliverSearchResultState extends State<_SliverSearchResult>
    with AutomaticKeepAliveClientMixin {
  bool isLoading = true;

  static const _kComicHeight = 162.0;

  get _comicWidth => _kComicHeight * 0.7;

  static const _kLeftPadding = 16.0;

  List<Comic>? comics;

  String? error;

  void load() async {
    final res = await _AggregatedSearchPageState.loadSource(
      widget.source,
      widget.keyword,
    );
    if (!mounted) return;
    setState(() {
      if (res.error != null) {
        error = res.error;
      } else {
        comics = res.comics;
        widget.onLoaded?.call(res.comics ?? []);
      }
      isLoading = false;
    });
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  Widget buildPlaceHolder() {
    return Container(
      height: _kComicHeight,
      width: _comicWidth,
      margin: const EdgeInsets.only(left: _kLeftPadding),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }

  Widget buildComic(Comic c) {
    return SimpleComicTile(comic: c, withTitle: true)
        .paddingLeft(_kLeftPadding)
        .paddingBottom(2);
  }

  @override
  Widget build(BuildContext context) {
    if (error != null && error!.startsWith("CloudflareException")) {
      error = "Cloudflare verification required".tl;
    }
    super.build(context);
    return InkWell(
      onTap: () {
        context.to(
          () => SearchResultPage(
            text: widget.keyword,
            sourceKey: widget.source.key,
          ),
        );
      },
      child: Column(
        children: [
          ListTile(
            mouseCursor: SystemMouseCursors.click,
            title: Text(widget.source.name),
          ),
          if (isLoading)
            SizedBox(
              height: _kComicHeight,
              width: double.infinity,
              child: Shimmer(
                child: LayoutBuilder(builder: (context, constrains) {
                  var itemWidth = _comicWidth + _kLeftPadding;
                  var items = (constrains.maxWidth / itemWidth).ceil();
                  return Stack(
                    children: [
                      Positioned(
                        left: 0,
                        top: 0,
                        bottom: 0,
                        child: Row(
                          children: List.generate(
                            items,
                            (index) => buildPlaceHolder(),
                          ),
                        ),
                      )
                    ],
                  );
                }),
              ),
            )
          else if (error != null || comics == null || comics!.isEmpty)
            SizedBox(
              height: _kComicHeight,
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(Icons.error_outline),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          error ?? "No search results found".tl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      )
                    ],
                  ),
                  const Spacer(),
                ],
              ).paddingHorizontal(16),
            )
          else
            SizedBox(
              height: _kComicHeight,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (var c in comics!) buildComic(c),
                ],
              ),
            ),
        ],
      ).paddingBottom(16),
    );
  }

  @override
  bool get wantKeepAlive => true;
}
