import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/source_binding.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/utils/translations.dart';

/// 以漫画名称在全部漫画源中搜索，弹出「漫画源 + 书名」的匹配列表，
/// 点击其中一条直接跳转到对应漫画的详情页。
///
/// [currentSourceKey] 为当前失败的源，其搜索结果会标注为「当前源」并排在后面。
Future<void> showSourceMatchSheet(
  BuildContext context, {
  required String keyword,
  String? currentSourceKey,
  String? ownerSourceKey,
  String? ownerId,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (_) => _SourceMatchSheet(
      keyword: keyword,
      currentSourceKey: currentSourceKey,
      ownerSourceKey: ownerSourceKey,
      ownerId: ownerId,
    ),
  );
}

class _SourceMatch {
  _SourceMatch(this.comic, this.source, this.score);

  final Comic comic;
  final ComicSource source;
  final int score;
}

class _SourceMatchSheet extends StatefulWidget {
  const _SourceMatchSheet({
    required this.keyword,
    this.currentSourceKey,
    this.ownerSourceKey,
    this.ownerId,
  });

  final String keyword;

  final String? currentSourceKey;

  /// 当前正在浏览的作品（用于把搜索结果绑定成它的备用源）
  final String? ownerSourceKey;

  final String? ownerId;

  @override
  State<_SourceMatchSheet> createState() => _SourceMatchSheetState();
}

class _SourceMatchSheetState extends State<_SourceMatchSheet> {
  /// 搜索词可以现场改：不同源给同一本书起的名千差万别（加汉化组、完本、
  /// DL版，或者干脆是另一个译名），拿原书名一把搜不到是常态。与其上模糊
  /// 匹配那一套，不如把搜索框交回用户手里——他知道这本书在别的站叫什么。
  late final TextEditingController _controller;

  late final List<ComicSource> _sources;

  final List<_SourceMatch> _matches = [];

  var _finished = 0;

  var _running = true;

  /// 每发起一次新搜索 +1。旧搜索的回包靠它作废，否则改完标题后上一次的
  /// 结果会一条条补进来，看着像「改了也没效果」。
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.keyword);
    _sources = ComicSource.all()
        .where((e) => e.searchPageData != null)
        .toList(growable: false);
    _searchAll(_cleanKeyword(widget.keyword));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _searchAgain([String? value]) {
    final keyword = _cleanKeyword((value ?? _controller.text).trim());
    if (keyword.isEmpty) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _matches.clear();
      _finished = 0;
      _running = true;
      _generation++;
    });
    _searchAll(keyword);
  }

  Future<void> _searchAll(String keyword) async {
    final generation = _generation;
    if (_sources.isEmpty) {
      setState(() {
        _running = false;
      });
      return;
    }
    var next = 0;
    Future<void> worker() async {
      while (next < _sources.length) {
        if (generation != _generation) return;
        final source = _sources[next++];
        try {
          final comics = await _searchSource(
            source,
            keyword,
          ).timeout(const Duration(seconds: 25), onTimeout: () => const []);
          final found = <_SourceMatch>[];
          for (var comic in comics) {
            final score = _score(comic.title, keyword);
            if (score > 0) {
              found.add(_SourceMatch(comic, source, score));
            }
          }
          if (!mounted || generation != _generation) return;
          if (found.isNotEmpty) {
            setState(() {
              _matches.addAll(found);
            });
          }
        } catch (_) {
          // 单个源失败不影响其它源
        }
        if (!mounted || generation != _generation) return;
        setState(() {
          _finished++;
        });
      }
    }

    // 限制并发，避免同时启动过多 JS 引擎。
    await Future.wait(
      List.generate(_sources.length < 3 ? _sources.length : 3, (_) => worker()),
    );
    if (mounted && generation == _generation) {
      setState(() {
        _running = false;
      });
    }
  }

  Future<List<Comic>> _searchSource(ComicSource source, String keyword) async {
    final data = source.searchPageData!;
    final options = (data.searchOptions ?? [])
        .map((e) => e.defaultValue)
        .toList();
    Res<List<Comic>>? res;
    if (data.loadPage != null) {
      res = await data.loadPage!(keyword, 1, options);
    } else if (data.loadNext != null) {
      res = await data.loadNext!(keyword, null, options);
    }
    if (res == null || res.error) {
      return const [];
    }
    return res.data;
  }

  /// 去掉常见的汉化组/作者标注与分隔符，提高搜索命中率。
  static String _cleanKeyword(String raw) {
    var text = raw;
    text = text.replaceAll(RegExp(r'[\[【(（][^\]】)）]*[\]】)）]'), ' ');
    text = text.replaceAll(RegExp(r'[\s\-_|/\\·,，。.]+'), ' ').trim();
    if (text.isEmpty) {
      text = raw.trim();
    }
    return text;
  }

  static String _normalize(String text) {
    return text.toLowerCase().replaceAll(
      RegExp(r'[\s\p{P}\p{S}]', unicode: true),
      '',
    );
  }

  static int _score(String title, String keyword) {
    final t = _normalize(title);
    final k = _normalize(keyword);
    if (k.isEmpty || t.isEmpty) return -1;
    if (t == k) return 100;
    if (t.startsWith(k)) return 80;
    if (t.contains(k)) return 60;
    if (t.length >= 4 && k.contains(t)) return 40;
    return -1;
  }

  List<_SourceMatch> get _sorted {
    final list = List<_SourceMatch>.from(_matches);
    list.sort((a, b) {
      final ap = a.source.key == widget.currentSourceKey ? 1 : 0;
      final bp = b.source.key == widget.currentSourceKey ? 1 : 0;
      if (ap != bp) return ap - bp;
      if (a.score != b.score) return b.score - a.score;
      return a.comic.title.compareTo(b.comic.title);
    });
    return list;
  }

  void _openComic(_SourceMatch match) {
    final navContext = App.mainNavigatorKey?.currentContext ?? context;
    Navigator.of(context).pop();
    navContext.to(
      () => ComicPage(
        id: match.comic.id,
        sourceKey: match.comic.sourceKey,
        title: match.comic.title,
        cover: match.comic.cover,
      ),
    );
  }

  bool _isSelf(_SourceMatch match) {
    return match.source.key == widget.ownerSourceKey &&
        match.comic.id == widget.ownerId;
  }

  Widget _buildBindButton(_SourceMatch match) {
    if (_isSelf(match)) {
      return const SizedBox(width: 40);
    }
    final ownerSource = widget.ownerSourceKey!;
    final ownerId = widget.ownerId!;
    final bound = SourceBindingManager.isBound(
      ownerSource,
      ownerId,
      match.comic.sourceKey,
      match.comic.id,
    );
    return IconButton(
      tooltip: bound ? "Unbind backup source".tl : "Bind as backup source".tl,
      iconSize: 20,
      icon: Icon(
        bound ? Icons.bookmark_added : Icons.bookmark_add_outlined,
        color: bound ? context.colorScheme.primary : null,
      ),
      onPressed: () {
        if (bound) {
          SourceBindingManager.unbind(
            ownerSource: ownerSource,
            ownerId: ownerId,
            sourceKey: match.comic.sourceKey,
            comicId: match.comic.id,
          );
        } else {
          SourceBindingManager.bind(
            ownerSource: ownerSource,
            ownerId: ownerId,
            sourceKey: match.comic.sourceKey,
            comicId: match.comic.id,
            title: match.comic.title,
            cover: match.comic.cover,
          );
        }
        setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final matches = _sorted;
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final available = MediaQuery.of(context).size.height - viewInsets.bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SizedBox(
        height: available * 0.72,
        // 底板必须是 Material：ListTile 把底色和水波纹画在最近的 Material 上，
        // 用带颜色的 Container 垫着会把这层效果盖掉（debug 里还会直接断言）。
        child: Material(
          color: context.colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: context.colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.travel_explore,
                      size: 20,
                      color: context.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Search in other sources".tl,
                        style: ts.s16.bold,
                      ),
                    ),
                    Text(
                      _running
                          ? "$_finished/${_sources.length}"
                          : "${matches.length}",
                      style: ts.s12,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: TextField(
                  controller: _controller,
                  textInputAction: TextInputAction.search,
                  onSubmitted: _searchAgain,
                  style: ts.s14,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: "Search".tl,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 38,
                      minHeight: 38,
                    ),
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.arrow_forward, size: 18),
                      tooltip: "Search".tl,
                      visualDensity: VisualDensity.compact,
                      onPressed: _searchAgain,
                    ),
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 38,
                      minHeight: 38,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              if (_running)
                const LinearProgressIndicator(minHeight: 2)
              else
                const SizedBox(height: 2),
              Expanded(
                child: matches.isEmpty
                    ? _buildEmpty()
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        itemCount: matches.length,
                        separatorBuilder: (_, __) => Divider(
                          height: 1,
                          color: context.colorScheme.outlineVariant.withValues(
                            alpha: 0.4,
                          ),
                        ),
                        itemBuilder: (context, index) {
                          final match = matches[index];
                          final isCurrent =
                              match.source.key == widget.currentSourceKey;
                          return ListTile(
                            dense: true,
                            title: Text(
                              match.comic.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: context
                                          .colorScheme
                                          .secondaryContainer
                                          .withValues(alpha: 0.7),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      match.source.name,
                                      style: ts.s10,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (isCurrent) ...[
                                    const SizedBox(width: 6),
                                    Text("Current source".tl, style: ts.s10),
                                  ],
                                ],
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (widget.ownerSourceKey != null &&
                                    widget.ownerId != null)
                                  _buildBindButton(match),
                                const Icon(Icons.chevron_right, size: 20),
                              ],
                            ),
                            onTap: () => _openComic(match),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    if (_running) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const FiveDotLoadingAnimation(),
            const SizedBox(height: 12),
            Text("Searching all comic sources...".tl, style: ts.s12),
          ],
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search_off, size: 36, color: context.colorScheme.outline),
          const SizedBox(height: 8),
          Text(
            "No matching comics found in other sources".tl,
            textAlign: TextAlign.center,
            style: ts.s12,
          ),
          const SizedBox(height: 4),
          Text(
            "Can't find it? Edit the title above and search again".tl,
            textAlign: TextAlign.center,
            style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
