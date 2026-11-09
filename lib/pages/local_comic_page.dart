import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_details_cache.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/pages/favorites/favorites_page.dart' show addFavorite;
import 'package:venera/pages/local_comics_page.dart'
    show exportLocalComics, openComicFolder;
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/epub.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/pdf.dart';
import 'package:venera/utils/translations.dart';

/// 本地漫画的详情页。
///
/// 以前在本地列表点封面是**直接进阅读器**：想看一眼简介、标签、章节列表
/// 再决定从哪一话开始，得先退出阅读器。这里给本地漫画补一个和在线详情页
/// 同构的页面，区别只有三点：
///
/// - 来源标成「本地」，一眼能看出这本书在手机里而不是在线；
/// - 复制 URL / 打开网页仍然指向它**原来的网络地址**——地址藏在下载时写进
///   漫画目录的 [ComicDetailsCache] 快照里，本地库里没有；
/// - 不提供下载、点赞、评论这些只对在线源有意义的按钮。
class LocalComicPage extends StatefulWidget {
  const LocalComicPage({
    super.key,
    required this.id,
    required this.comicType,
    this.heroID,
  });

  final String id;

  final ComicType comicType;

  final int? heroID;

  static void open(BuildContext context, LocalComic comic, {int? heroID}) {
    context.to(
      () => LocalComicPage(
        id: comic.id,
        comicType: comic.comicType,
        heroID: heroID,
      ),
    );
  }

  @override
  State<LocalComicPage> createState() => _LocalComicPageState();
}

class _LocalComicPageState extends State<LocalComicPage> {
  LocalComic? _comic;

  /// 下载时写进漫画目录的在线详情快照。可能没有（手工导入的漫画、或者
  /// 下载时还没人打开过详情页），所以处处按可空处理。
  ComicDetails? _details;

  final _scrollController = ScrollController();

  bool _showAppbarTitle = false;

  @override
  void initState() {
    super.initState();
    _load();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _load() {
    _comic = LocalManager().find(widget.id, widget.comicType);
    _details = ComicDetailsCache.load(widget.id, widget.comicType);
  }

  void _onScroll() {
    if (!_scrollController.hasClients) {
      return;
    }
    final offset = _scrollController.position.pixels;
    final shouldShow = offset > 100;
    if (shouldShow != _showAppbarTitle) {
      setState(() {
        _showAppbarTitle = shouldShow;
      });
    }
  }

  /// 网络源地址。只在有详情快照时才有，导入的本地漫画没有。
  String? get _url => _details?.url;

  /// 原始网络源的名字（下载来的漫画才有）。
  String? get _originSourceName {
    final source = widget.comicType.comicSource;
    return source?.name;
  }

  ImageProvider get _coverImage {
    final comic = _comic!;
    return CachedImageProvider("file://${comic.coverFile.path}");
  }

  void _read({int? ep, int? group, int? page}) {
    final comic = _comic!;
    final history = HistoryManager().find(comic.id, comic.comicType);
    App.rootContext.to(
      () => Reader(
        type: comic.comicType,
        cid: comic.id,
        name: comic.title,
        chapters: comic.chapters,
        initialChapter: ep ?? history?.ep,
        initialPage: page ?? (ep != null ? 1 : history?.page),
        initialChapterGroup: group ?? history?.group,
        history: history ?? History.fromModel(model: comic, ep: 0, page: 0),
        author: comic.subtitle,
        tags: comic.tags,
      ),
    );
  }

  void _readChapter(String chapterId) {
    final chapters = _comic!.chapters;
    if (chapters == null) {
      _read();
      return;
    }
    if (chapters.isGrouped) {
      for (var i = 0; i < chapters.groupCount; i++) {
        final group = chapters.getGroupByIndex(i);
        final index = group.keys.toList().indexOf(chapterId);
        if (index >= 0) {
          _read(ep: index + 1, group: i + 1, page: 1);
          return;
        }
      }
    } else {
      final index = chapters.allChapters.keys.toList().indexOf(chapterId);
      if (index >= 0) {
        _read(ep: index + 1, page: 1);
        return;
      }
    }
    _read(page: 1);
  }

  void _showMoreActions() {
    final context = App.rootContext;
    final comic = _comic!;
    final url = _url;
    showMenuX(context, Offset(context.width - 16, context.padding.top), [
      MenuEntry(
        icon: Icons.copy,
        text: "Copy Title".tl,
        onClick: () {
          Clipboard.setData(ClipboardData(text: comic.title));
          context.showMessage(message: "Copied".tl);
        },
      ),
      MenuEntry(
        icon: Icons.copy_rounded,
        text: "Copy ID".tl,
        onClick: () {
          Clipboard.setData(ClipboardData(text: comic.id));
          context.showMessage(message: "Copied".tl);
        },
      ),
      // 这两个指向的仍然是网络源上的原始地址，而不是手机里的目录：
      // 分享给别人的时候，「本地路径」对谁都没用。
      if (url != null)
        MenuEntry(
          icon: Icons.link,
          text: "Copy URL".tl,
          onClick: () {
            Clipboard.setData(ClipboardData(text: url));
            context.showMessage(message: "Copied".tl);
          },
        ),
      if (url != null)
        MenuEntry(
          icon: Icons.open_in_browser,
          text: "Open in Browser".tl,
          onClick: () {
            launchUrlString(url);
          },
        ),
      MenuEntry(
        icon: Icons.folder_open,
        text: "Open Folder".tl,
        onClick: () {
          openComicFolder(comic);
        },
      ),
      MenuEntry(
        icon: Icons.outbox_outlined,
        text: "Export as cbz".tl,
        onClick: () {
          exportLocalComics(context, [comic], CBZ.export, ".cbz");
        },
      ),
      MenuEntry(
        icon: Icons.picture_as_pdf_outlined,
        text: "Export as pdf".tl,
        onClick: () {
          exportLocalComics(context, [comic], createPdfFromComicIsolate, ".pdf");
        },
      ),
      MenuEntry(
        icon: Icons.import_contacts_outlined,
        text: "Export as epub".tl,
        onClick: () {
          exportLocalComics(
            context,
            [comic],
            createEpubWithLocalComic,
            ".epub",
          );
        },
      ),
    ]);
  }

  bool get _isFavorite =>
      LocalFavoritesManager().isExist(widget.id, widget.comicType);

  void _toggleFavorite() {
    final comic = _comic!;
    if (_isFavorite) {
      LocalFavoritesManager().unfavorite(comic.id, comic.comicType);
      setState(() {});
      App.rootContext.showMessage(message: "Removed".tl);
      return;
    }
    addFavorite([comic]);
    // addFavorite 是弹窗流程，回来时刷新一下按钮状态。
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final comic = _comic;
    if (comic == null) {
      return Scaffold(
        appBar: Appbar(title: Text("Local".tl)),
        body: NetworkError(
          message: "Local comic not found".tl,
          retry: () {
            setState(_load);
          },
        ),
      );
    }
    final history = HistoryManager().find(comic.id, comic.comicType);
    final hasHistory = history != null && (history.ep > 1 || history.page > 1);
    final isMobile = context.width < changePoint;
    return Scaffold(
      body: SmoothCustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverAppbar(
            title: AnimatedOpacity(
              opacity: _showAppbarTitle ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Text(comic.title),
            ),
            actions: [
              IconButton(
                onPressed: _showMoreActions,
                icon: const Icon(Icons.more_horiz),
              ),
            ],
          ),
          const SliverPadding(padding: EdgeInsets.only(top: 8)),
          _buildHeader(context, comic),
          SliverToBoxAdapter(
            child: Column(
              children: [
                ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    if (hasHistory)
                      _LocalActionButton(
                        icon: const Icon(Icons.menu_book),
                        text: 'Continue'.tl,
                        onPressed: () => _read(),
                        color: context.useTextColor(Colors.yellow),
                      ),
                    _LocalActionButton(
                      icon: const Icon(Icons.play_circle_outline),
                      text: 'Start'.tl,
                      onPressed: () => _read(page: 1),
                      color: context.useTextColor(Colors.orange),
                    ),
                    _LocalActionButton(
                      icon: const Icon(Icons.bookmark_outline_outlined),
                      activeIcon: const Icon(Icons.bookmark),
                      isActive: _isFavorite,
                      text: 'Favorite'.tl,
                      onPressed: _toggleFavorite,
                      color: context.useTextColor(Colors.purple),
                    ),
                    _LocalActionButton(
                      icon: const Icon(Icons.share),
                      text: 'Share'.tl,
                      onPressed: () {
                        final url = _url;
                        Share.shareText(
                          url == null ? comic.title : "${comic.title}\n$url",
                        );
                      },
                      color: context.useTextColor(Colors.blue),
                    ),
                  ],
                ).fixHeight(48),
                if (isMobile)
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: _toggleFavorite,
                          child: Text(
                            _isFavorite ? "Unfavorite".tl : "Favorite".tl,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: hasHistory
                            ? FilledButton(
                                onPressed: () => _read(),
                                child: Text("Continue".tl),
                              )
                            : FilledButton(
                                onPressed: () => _read(page: 1),
                                child: Text("Read".tl),
                              ),
                      ),
                    ],
                  ).paddingHorizontal(16).paddingVertical(8),
                if (history != null) _buildHistoryChip(context, comic, history),
                const Divider(),
              ],
            ).paddingTop(16),
          ),
          ..._buildDescription(comic),
          ..._buildTags(comic),
          ..._buildChapters(comic),
          SliverPadding(padding: EdgeInsets.only(bottom: context.padding.bottom + 40)),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, LocalComic comic) {
    final colors = context.colorScheme;
    return SliverToBoxAdapter(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 16),
          Hero(
            tag: "cover${widget.heroID}",
            child: Container(
              height: 144,
              width: 144 * 0.72,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: AnimatedImage(
                image: _coverImage,
                cacheWidth: kCoverDecodeWidth,
                width: double.infinity,
                height: double.infinity,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(comic.title, style: ts.s18),
                if (comic.subtitle.isNotEmpty)
                  SelectableText(comic.subtitle, style: ts.s14)
                      .paddingVertical(4),
                const SizedBox(height: 2),
                // 「来源：本地」——本页最要紧的一行。下载来的漫画再补一句
                // 原来的网络源名字，方便回去找。
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.smartphone_rounded,
                            size: 12,
                            color: colors.primary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            "Local".tl,
                            style: ts.s12.withColor(colors.primary),
                          ),
                        ],
                      ),
                    ),
                    if (_originSourceName != null)
                      Text(
                        _originSourceName!,
                        style: ts.s12.withColor(colors.onSurfaceVariant),
                      ),
                  ],
                ),
                ListenableBuilder(
                  listenable: LocalFavoritesManager(),
                  builder: (context, _) {
                    final folders = LocalFavoritesManager().getComicFolders(
                      comic.id,
                      comic.comicType,
                    );
                    if (folders.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 1),
                            child: Icon(
                              Icons.bookmark_rounded,
                              size: 13,
                              color: colors.primary.toOpacity(0.85),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              "${"Favorited in".tl} ${folders.join(" · ")}",
                              style: ts.s12.copyWith(
                                color: colors.onSurfaceVariant,
                                height: 1.3,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
    );
  }

  Widget _buildHistoryChip(
    BuildContext context,
    LocalComic comic,
    History history,
  ) {
    String text;
    final chapters = comic.chapters;
    if (chapters != null && chapters.length > 0) {
      var epName = "E${history.ep}";
      try {
        final index = (history.ep - 1).clamp(0, chapters.length - 1);
        epName = chapters.titles.elementAt(index);
      } catch (_) {
        // 章节表变了（重下/改名），保留 E<n> 兜底
      }
      text = "${"Last Reading".tl}: $epName P${history.page}";
    } else {
      text = "${"Last Reading".tl}: P${history.page}";
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.history, color: context.useTextColor(Colors.teal)),
          const SizedBox(width: 8),
          Text(text),
        ],
      ),
    ).toAlign(Alignment.centerLeft);
  }

  Iterable<Widget> _buildDescription(LocalComic comic) sync* {
    final description = _details?.description;
    if (description == null || description.trim().isEmpty) {
      return;
    }
    yield SliverToBoxAdapter(
      child: Column(
        children: [
          ListTile(title: Text("Description".tl)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SelectableText(description).fixWidth(double.infinity),
          ),
          const SizedBox(height: 16),
          const Divider(),
        ],
      ),
    );
  }

  Iterable<Widget> _buildTags(LocalComic comic) sync* {
    // 优先级：详情快照里的分类标签 > 本地库记下的扁平标签。
    final tags = <String>[];
    final detailTags = _details?.tags;
    if (detailTags != null && detailTags.isNotEmpty) {
      for (final entry in detailTags.entries) {
        for (final tag in entry.value) {
          tags.add(entry.key.isEmpty ? tag : "${entry.key}:$tag");
        }
      }
    } else {
      tags.addAll(comic.tags);
    }
    if (tags.isEmpty) {
      return;
    }
    yield SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(title: Text("Information".tl)),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tag in tags)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: context.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(tag),
                ),
            ],
          ).paddingHorizontal(16).paddingBottom(8),
          const SizedBox(height: 12),
          const Divider(),
        ],
      ),
    );
  }

  Iterable<Widget> _buildChapters(LocalComic comic) sync* {
    final chapters = comic.chapters;
    if (chapters == null || chapters.length == 0) {
      return;
    }
    final entries = chapters.allChapters.entries.toList();
    yield SliverToBoxAdapter(
      child: ListTile(
        title: Text("Chapters".tl),
        trailing: Text(
          "${entries.length}",
          style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
        ),
      ),
    );
    yield SliverList.builder(
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        final read = HistoryManager().find(comic.id, comic.comicType);
        final isCurrent = read != null &&
            comic.chapters != null &&
            _epIndexOf(comic.chapters!, entry.key) == read.ep;
        return ListTile(
          title: Text(entry.value),
          leading: SizedBox(
            width: 24,
            child: Center(
              child: Text(
                "${index + 1}",
                style: ts.s12.withColor(
                  context.colorScheme.onSurfaceVariant.toOpacity(0.7),
                ),
              ),
            ),
          ),
          trailing: isCurrent
              ? Icon(
                  Icons.play_arrow_rounded,
                  size: 18,
                  color: context.colorScheme.primary,
                )
              : null,
          onTap: () => _readChapter(entry.key),
        );
      },
    );
  }

  static int _epIndexOf(ComicChapters chapters, String chapterId) {
    if (chapters.isGrouped) {
      for (var i = 0; i < chapters.groupCount; i++) {
        final group = chapters.getGroupByIndex(i);
        final index = group.keys.toList().indexOf(chapterId);
        if (index >= 0) {
          return index + 1;
        }
      }
      return 0;
    }
    return chapters.allChapters.keys.toList().indexOf(chapterId) + 1;
  }
}

class _LocalActionButton extends StatelessWidget {
  const _LocalActionButton({
    required this.icon,
    required this.text,
    required this.onPressed,
    this.activeIcon,
    this.isActive = false,
    this.color,
  });

  final Widget icon;

  final Widget? activeIcon;

  final bool isActive;

  final String text;

  final VoidCallback onPressed;

  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: context.colorScheme.outlineVariant,
          width: 0.6,
        ),
      ),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(18),
        child: IconTheme.merge(
          data: IconThemeData(size: 20, color: color),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              isActive ? (activeIcon ?? icon) : icon,
              const SizedBox(width: 8),
              Text(text),
            ],
          ).paddingHorizontal(16),
        ),
      ),
    );
  }
}
