import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_view/photo_view.dart';
import 'package:shimmer_animation/shimmer_animation.dart';
import 'package:sliver_tools/sliver_tools.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/rich_comment_content.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_details_cache.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/foundation/source_binding.dart';
import 'package:venera/network/download.dart';
import 'package:venera/network/cache.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/pages/source_match_sheet.dart';
import 'package:venera/utils/comic_update_time.dart';
import 'package:venera/utils/file_type.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';
import 'dart:math' as math;

part 'comments_page.dart';

part 'chapters.dart';

part 'thumbnails.dart';

part 'favorite.dart';

part 'comments_preview.dart';

part 'actions.dart';

part 'cover_viewer.dart';

class ComicPage extends StatefulWidget {
  const ComicPage({
    super.key,
    required this.id,
    required this.sourceKey,
    this.cover,
    this.title,
    this.heroID,
    this.autoFallback = true,
    this.alignEp,
  });

  final String id;

  final String sourceKey;

  final String? cover;

  final String? title;

  final int? heroID;

  /// 加载失败时是否自动跳到已绑定的备用源
  final bool autoFallback;

  /// 从备用源跳转过来时，按原源章节序号对齐
  final int? alignEp;

  @override
  State<ComicPage> createState() => _ComicPageState();
}

class _ComicPageState extends LoadingState<ComicPage, ComicDetails>
    with _ComicPageActions {
  @override
  History? history;

  bool showAppbarTitle = false;

  var scrollController = ScrollController();

  /// 滚动进度（0~1，前 220px）。用 ValueNotifier 而不是 setState，
  /// 让封面视差逐像素跟随滚动，又不会整页重建。
  final ValueNotifier<double> _scrollProgress = ValueNotifier(0);

  bool isDownloaded = false;

  bool showFAB = false;

  bool _fallbackHandled = false;

  /// 当前页面是用本地详情快照渲染的（还没拿到在线数据）。
  ///
  /// 用来挡住 [onDataLoaded] 里的网络请求——断网时那一步会把缓存秒开拖成
  /// 几十秒骨架屏。只有首次加载走 onDataLoaded，后台刷新不会重置它。
  bool _showingCache = false;

  /// 故障转移后按章节序号对齐的目标话数
  int? _pendingAlignEp;

  @override
  void onReadEnd() {
    history ??= HistoryManager().find(
      widget.id,
      ComicType(widget.sourceKey.hashCode),
    );
    update();
  }

  @override
  Widget buildLoading() {
    return _ComicPageLoadingPlaceHolder(
      cover: widget.cover,
      title: widget.title,
      sourceKey: widget.sourceKey,
      cid: widget.id,
      heroID: widget.heroID,
    );
  }

  @override
  Widget buildError() {
    final isDownloaded = LocalManager().isDownloaded(
      widget.id,
      ComicType.fromKey(widget.sourceKey),
    );
    Widget? action;
    if (isDownloaded) {
      action = FilledButton.tonal(
        child: Text("Read".tl),
        onPressed: () {
          final localComic = LocalManager().find(
            widget.id,
            ComicType.fromKey(widget.sourceKey),
          );
          if (localComic == null) {
            context.showMessage(message: "Local comic not found".tl);
            return;
          }
          localComic.read();
        },
      );
    }
    final title = widget.title;
    Widget? extra;
    if (title != null && title.trim().isNotEmpty) {
      extra = OutlinedButton.icon(
        icon: const Icon(Icons.travel_explore, size: 18),
        label: Text("Search in other sources".tl),
        onPressed: () {
          showSourceMatchSheet(
            context,
            keyword: title,
            currentSourceKey: widget.sourceKey,
            ownerSourceKey: widget.sourceKey,
            ownerId: widget.id,
          );
        },
      );
    }
    return NetworkError(
      message: error!,
      retry: retry,
      action: action,
      extra: extra,
    );
  }

  @override
  void initState() {
    scrollController.addListener(onScroll);
    super.initState();
  }

  @override
  void dispose() {
    scrollController.removeListener(onScroll);
    _scrollProgress.dispose();
    super.dispose();
  }

  @override
  void update() {
    setState(() {});
  }

  @override
  ComicDetails get comic => data!;

  void onScroll() {
    var offset =
        scrollController.position.pixels -
        scrollController.position.minScrollExtent;
    _scrollProgress.value = (offset / 220).clamp(0.0, 1.0);
    var showFAB = offset > 0;
    if (showFAB != this.showFAB) {
      setState(() {
        this.showFAB = showFAB;
      });
    }
    if (offset > 100) {
      if (!showAppbarTitle) {
        setState(() {
          showAppbarTitle = true;
        });
      }
    } else {
      if (showAppbarTitle) {
        setState(() {
          showAppbarTitle = false;
        });
      }
    }
  }

  var isFirst = true;

  @override
  Widget buildContent(BuildContext context, ComicDetails data) {
    return Scaffold(
      floatingActionButton: showFAB
          ? FloatingActionButton(
              onPressed: () {
                scrollController.animateTo(
                  0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.ease,
                );
              },
              child: const Icon(Icons.arrow_upward),
            )
          : null,
      body: SmoothCustomScrollView(
        controller: scrollController,
        slivers: [
          ...buildTitle(),
          buildActions(),
          buildDescription(),
          buildInfo(),
          buildChapters(),
          buildComments(),
          buildThumbnails(),
          buildRecommend(),
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: context.padding.bottom + 80,
            ), // Add additional padding for FAB
          ),
        ],
      ),
    );
  }

  @override
  Future<Res<ComicDetails>> loadData() async {
    if (widget.sourceKey == 'local') {
      var localComic = LocalManager().find(widget.id, ComicType.local);
      if (localComic == null) {
        return const Res.error('Local comic not found');
      }
      var history = HistoryManager().find(widget.id, ComicType.local);
      if (isFirst) {
        Future.microtask(() {
          App.rootContext.to(() {
            return Reader(
              type: ComicType.local,
              cid: widget.id,
              name: localComic.title,
              chapters: localComic.chapters,
              initialPage: history?.page,
              initialChapter: history?.ep,
              initialChapterGroup: history?.group,
              history:
                  history ??
                  History.fromModel(model: localComic, ep: 0, page: 0),
              author: localComic.subTitle ?? '',
              tags: localComic.tags,
            );
          });
          App.mainNavigatorKey!.currentContext!.pop();
        });
        isFirst = false;
      }
      await Future.delayed(const Duration(milliseconds: 200));
      return const Res.error('Local comic');
    }
    var comicSource = ComicSource.find(widget.sourceKey);
    if (comicSource == null) {
      return const Res.error('Comic source not found');
    }
    final type = ComicType(widget.sourceKey.hashCode);
    isAddToLocalFav = LocalFavoritesManager().isExist(widget.id, type);
    history = HistoryManager().find(widget.id, type);

    // 已下载的漫画：目录里有一份下载时写下的详情快照，先拿它渲染，再在后台
    // 静默刷新。
    //
    // 之前这里一律先请求源站，断网就只剩一张错误页——整本漫画都在手机里，
    // 却连章节列表都看不到，只能退出去另找「阅读」。缓存优先之后，离线打开
    // 是即时的，联网时新旧章节会在几百毫秒内悄悄补上。
    final cached = ComicDetailsCache.load(widget.id, type);
    if (cached != null) {
      _showingCache = true;
      _refreshInBackground(comicSource);
      return Res<ComicDetails>(cached);
    }

    final load = comicSource.loadComicInfo;
    if (load == null) {
      return const Res.error('Comic source not supported');
    }
    final res = await load(widget.id);
    if (!res.error) {
      _rememberComic(res.data);
    } else {
      _handleFallback();
    }
    return res;
  }

  /// 记下更新时间（发现页角标用）并把详情写成本地快照。
  ///
  /// save 只在确实有本地漫画目录时才落盘，所以未下载的漫画不会占用空间。
  void _rememberComic(ComicDetails details) {
    final updateTime = details.findUpdateTime();
    if (updateTime != null) {
      ComicUpdateTimeCache.instance.put(
        widget.sourceKey,
        widget.id,
        updateTime,
      );
    }
    ComicDetailsCache.save(details, ComicType(widget.sourceKey.hashCode));
  }

  /// 用缓存渲染之后，在后台安静地拉一次最新详情。
  ///
  /// 失败就维持缓存内容——离线时这里必然失败，不该弹错、也不该跳备用源。
  void _refreshInBackground(ComicSource source) {
    final load = source.loadComicInfo;
    if (load == null) {
      return;
    }
    Future.microtask(() async {
      final res = await load(widget.id);
      if (!mounted || res.error) {
        return;
      }
      final fresh = res.data;
      _rememberComic(fresh);
      // 只换 data，不再跑一遍 onDataLoaded：那里会按源站返回重写收藏/点赞
      // 状态，而用户这会儿可能已经在页面上动过手了。
      if (!_chaptersOrCoverChanged(fresh)) {
        return;
      }
      setState(() {
        data = fresh;
      });
    });
  }

  /// 章节表、封面、简介有变化才值得重建整页；只更新了点赞数之类的就没必要，
  /// 那会让正在滚动的列表跳一下。
  bool _chaptersOrCoverChanged(ComicDetails fresh) {
    final old = data;
    if (old == null) {
      return true;
    }
    return old.comicId != fresh.comicId ||
        old.title != fresh.title ||
        old.cover != fresh.cover ||
        old.description != fresh.description ||
        old.updateTime != fresh.updateTime ||
        old.chapters?.length != fresh.chapters?.length ||
        old.chapters?.isGrouped != fresh.chapters?.isGrouped;
  }

  /// 主源加载失败时，自动切到已绑定的第一个备用源。
  void _handleFallback() {
    if (!widget.autoFallback || _fallbackHandled) {
      return;
    }
    _fallbackHandled = true;
    final list = SourceBindingManager.alternatives(widget.sourceKey, widget.id);
    if (list.isEmpty) {
      return;
    }
    final target = list.first;
    final source = ComicSource.find(target.sourceKey);
    if (source == null || source.loadComicInfo == null) {
      return;
    }
    final ep = history?.ep;
    Future.microtask(() {
      if (!mounted) {
        return;
      }
      context.toReplacement(
        () => ComicPage(
          id: target.comicId,
          sourceKey: target.sourceKey,
          title: target.title,
          cover: target.cover,
          autoFallback: false,
          alignEp: ep,
        ),
      );
      App.rootContext.showMessage(
        message: "Source unavailable, switched to @s".tlParams({
          "s": source.name,
        }),
      );
    });
  }

  @override
  void continueRead() {
    final align = _pendingAlignEp;
    if (align == null) {
      super.continueRead();
      return;
    }
    read(align, 1, history?.group ?? 1);
  }

  @override
  Future<void> onDataLoaded() async {
    isLiked = comic.isLiked ?? false;
    isFavorite = comic.isFavorite ?? false;
    // For sources with multi-folder favorites, prefer querying folders to get accurate favorite status
    // Some sources may not set isFavorite reliably when multi-folder is enabled
    //
    // 用缓存渲染时跳过这一步：这里是一次真实网络请求，而 onDataLoaded 是
    // await 在首帧之前的，断网时它会把「缓存秒开」硬生生拖成几十秒的骨架屏。
    // 收藏状态先用快照里的值，后台刷新成功（说明网络确实通了）再补查。
    if (!_showingCache &&
        comicSource.favoriteData?.loadFolders != null &&
        comicSource.isLogged) {
      var res = await comicSource.favoriteData!.loadFolders!(comic.id);
      if (!res.error) {
        if (res.subData is List) {
          var list = List<String>.from(res.subData);
          isFavorite = list.isNotEmpty;
          update();
        }
      }
    }
    if (comic.chapters == null) {
      isDownloaded = LocalManager().isDownloaded(comic.id, comic.comicType, 0);
    }
    final align = widget.alignEp;
    final chapters = comic.chapters;
    if (align != null && chapters != null) {
      final total = chapters.length;
      if (total > 0) {
        _pendingAlignEp = align.clamp(1, total);
        update();
        Future.microtask(() {
          if (!mounted) return;
          context.showMessage(
            message: "Switched source, aligned to chapter @n".tlParams({
              "n": "$_pendingAlignEp",
            }),
          );
        });
      }
    }
  }

  Iterable<Widget> buildTitle() sync* {
    yield SliverAppbar(
      title: AnimatedOpacity(
        opacity: showAppbarTitle ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        child: Text(comic.title),
      ),
      actions: [
        IconButton(
          onPressed: showMoreActions,
          icon: const Icon(Icons.more_horiz),
        ),
      ],
    );

    yield const SliverPadding(padding: EdgeInsets.only(top: 8));

    yield SliverLazyToBoxAdapter(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 16),
          GestureDetector(
            onTap: () => _viewCover(context),
            onLongPress: () => _saveCover(context),
            child: Hero(
              tag: "cover${widget.heroID}",
              // 视差：封面比页面滚得慢一点、同时轻微缩小，
              // 滚动时像贴在背景上，而不是和文字一起硬邦邦地移走。
              child: AnimatedBuilder(
                animation: _scrollProgress,
                builder: (context, child) {
                  final t = _scrollProgress.value;
                  return Transform.translate(
                    offset: Offset(0, 18 * t),
                    child: Transform.scale(
                      alignment: Alignment.topCenter,
                      scale: 1 - 0.05 * t,
                      child: child,
                    ),
                  );
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: context.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: [
                      BoxShadow(
                        color: context.colorScheme.outlineVariant,
                        blurRadius: 1,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                  height: 144,
                  width: 144 * 0.72,
                  clipBehavior: Clip.antiAlias,
                  child: AnimatedImage(
                    image: CachedImageProvider(
                      widget.cover ?? comic.cover,
                      sourceKey: comic.sourceKey,
                      cid: comic.id,
                      // 断网时退回下载时存在漫画目录里的封面。既然详情内容
                      // 都能从快照出来，封面不该是唯一一块空白。
                      fallbackToLocalCover: true,
                    ),
                    // 与列表封面同一解码尺寸，Hero 飞行时直接命中缓存
                    cacheWidth: kCoverDecodeWidth,
                    width: double.infinity,
                    height: double.infinity,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(comic.title, style: ts.s18),
                if (comic.subTitle != null)
                  SelectableText(
                    comic.subTitle!,
                    style: ts.s14,
                  ).paddingVertical(4),
                Text(
                  (ComicSource.find(comic.sourceKey)?.name) ?? '',
                  style: ts.s12,
                ),
                // 收藏位置：跟在来源名下面，作为一行轻量元信息；
                // 未收藏时整行不渲染，不占高度。
                ListenableBuilder(
                  listenable: LocalFavoritesManager(),
                  builder: (context, _) {
                    var favFolders = LocalFavoritesManager().getComicFolders(
                      comic.id,
                      comic.comicType,
                    );
                    if (favFolders.isEmpty) {
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
                              color: context.colorScheme.primary.toOpacity(
                                0.85,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              "${"Favorited in".tl} ${favFolders.join(" · ")}",
                              style: ts.s12.copyWith(
                                color: context.colorScheme.onSurfaceVariant,
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
        ],
      ),
    );
  }

  Widget buildActions() {
    bool isMobile = context.width < changePoint;
    bool hasHistory = history != null && (history!.ep > 1 || history!.page > 1);
    return SliverLazyToBoxAdapter(
      child: Column(
        children: [
          ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              if (hasHistory && !isMobile)
                _ActionButton(
                  icon: const Icon(Icons.menu_book),
                  text: 'Continue'.tl,
                  onPressed: continueRead,
                  iconColor: context.useTextColor(Colors.yellow),
                ),
              if (!isMobile || hasHistory)
                _ActionButton(
                  icon: const Icon(Icons.play_circle_outline),
                  text: 'Start'.tl,
                  onPressed: read,
                  iconColor: context.useTextColor(Colors.orange),
                ),
              if (!isMobile && !isDownloaded)
                _ActionButton(
                  icon: const Icon(Icons.download),
                  text: 'Download'.tl,
                  onPressed: download,
                  iconColor: context.useTextColor(Colors.cyan),
                ),
              if (data!.isLiked != null)
                _ActionButton(
                  icon: const Icon(Icons.favorite_border),
                  activeIcon: const Icon(Icons.favorite),
                  isActive: isLiked,
                  text:
                      ((data!.likesCount != null)
                              ? (data!.likesCount! + (isLiked ? 1 : 0))
                              : (isLiked ? 'Liked'.tl : 'Like'.tl))
                          .toString(),
                  isLoading: isLiking,
                  onPressed: likeOrUnlike,
                  iconColor: context.useTextColor(Colors.red),
                ),
              _ActionButton(
                icon: const Icon(Icons.bookmark_outline_outlined),
                activeIcon: const Icon(Icons.bookmark),
                isActive: isFavorite || isAddToLocalFav,
                text: 'Favorite'.tl,
                onPressed: favoriteAction,
                onLongPressed: quickFavorite,
                iconColor: context.useTextColor(Colors.purple),
              ),
              if (comicSource.commentsLoader != null)
                _ActionButton(
                  icon: const Icon(Icons.comment),
                  text: (comic.commentCount ?? 'Comments'.tl).toString(),
                  onPressed: showComments,
                  iconColor: context.useTextColor(Colors.green),
                ),
              _ActionButton(
                icon: const Icon(Icons.share),
                text: 'Share'.tl,
                onPressed: share,
                iconColor: context.useTextColor(Colors.blue),
              ),
            ],
          ).fixHeight(48),
          if (isMobile)
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonal(
                    onPressed: download,
                    child: Text("Download".tl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: hasHistory
                      ? FilledButton(
                          onPressed: continueRead,
                          child: Text("Continue".tl),
                        )
                      : FilledButton(onPressed: read, child: Text("Read".tl)),
                ),
              ],
            ).paddingHorizontal(16).paddingVertical(8),
          if (history != null)
            Container(
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
                  Builder(
                    builder: (context) {
                      bool haveChapter = comic.chapters != null;
                      var page = history!.page;
                      var ep = history!.ep;
                      var group = history!.group;
                      String text;
                      if (haveChapter) {
                        var epName = "E$ep";
                        String? groupName;
                        try {
                          if (group == null) {
                            epName = comic.chapters!.titles.elementAt(
                              math.min(ep - 1, comic.chapters!.length - 1),
                            );
                          } else {
                            groupName = comic.chapters!.groups.elementAt(
                              group - 1,
                            );
                            epName = comic.chapters!
                                .getGroupByIndex(group - 1)
                                .values
                                .elementAt(ep - 1);
                          }
                        } catch (e) {
                          // ignore
                        }
                        text = groupName == null
                            ? "${"Last Reading".tl}: $epName P$page"
                            : "${"Last Reading".tl}: $groupName $epName P$page";
                      } else {
                        text = "${"Last Reading".tl}: P$page";
                      }
                      return Text(text);
                    },
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ).toAlign(Alignment.centerLeft),
          const Divider(),
        ],
      ).paddingTop(16),
    );
  }

  Widget buildDescription() {
    if (comic.description == null || comic.description!.trim().isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return SliverLazyToBoxAdapter(
      child: Column(
        children: [
          ListTile(title: Text("Description".tl)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SelectableText(comic.description!).fixWidth(double.infinity),
          ),
          const SizedBox(height: 16),
          const Divider(),
        ],
      ),
    );
  }

  Widget buildInfo() {
    if (comic.tags.isEmpty &&
        comic.uploader == null &&
        comic.uploadTime == null &&
        comic.uploadTime == null &&
        comic.maxPage == null) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }

    int i = 0;

    Widget buildTag({
      required String text,
      VoidCallback? onTap,
      bool isTitle = false,
    }) {
      Color color;
      if (isTitle) {
        const colors = [
          Colors.blue,
          Colors.cyan,
          Colors.red,
          Colors.pink,
          Colors.purple,
          Colors.indigo,
          Colors.teal,
          Colors.green,
          Colors.lime,
          Colors.yellow,
        ];
        color = context.useBackgroundColor(colors[(i++) % (colors.length)]);
      } else {
        color = context.colorScheme.surfaceContainerLow;
      }

      final borderRadius = BorderRadius.circular(12);

      const padding = EdgeInsets.symmetric(horizontal: 16, vertical: 6);

      if (onTap != null) {
        return Material(
          color: color,
          borderRadius: borderRadius,
          child: InkWell(
            borderRadius: borderRadius,
            onTap: onTap,
            onLongPress: () {
              Clipboard.setData(ClipboardData(text: text));
              context.showMessage(message: "Copied".tl);
            },
            onSecondaryTapDown: (details) {
              showMenuX(context, details.globalPosition, [
                MenuEntry(
                  icon: Icons.remove_red_eye,
                  text: "View".tl,
                  onClick: onTap,
                ),
                MenuEntry(
                  icon: Icons.copy,
                  text: "Copy".tl,
                  onClick: () {
                    Clipboard.setData(ClipboardData(text: text));
                    context.showMessage(message: "Copied".tl);
                  },
                ),
              ]);
            },
            child: Text(text).padding(padding),
          ),
        );
      } else {
        return Container(
          decoration: BoxDecoration(color: color, borderRadius: borderRadius),
          child: Text(text).padding(padding),
        );
      }
    }

    String formatTime(String time) {
      if (int.tryParse(time) != null) {
        var t = int.tryParse(time);
        if (t! > 1000000000000) {
          return DateTime.fromMillisecondsSinceEpoch(
            t,
          ).toString().substring(0, 19);
        } else {
          return DateTime.fromMillisecondsSinceEpoch(
            t * 1000,
          ).toString().substring(0, 19);
        }
      }
      if (time.contains('T') || time.contains('Z')) {
        var t = DateTime.parse(time);
        return t.toString().substring(0, 19);
      }
      return time;
    }

    Widget buildWrap({required List<Widget> children}) {
      return Wrap(
        runSpacing: 8,
        spacing: 8,
        children: children,
      ).paddingHorizontal(16).paddingBottom(8);
    }

    bool enableTranslation =
        App.locale.languageCode == 'zh' && comicSource.enableTagsTranslate;

    return SliverLazyToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(title: Text("Information".tl)),
          if (comic.stars != null)
            Row(
              children: [
                StarRating(value: comic.stars!, size: 24, onTap: starRating),
                const SizedBox(width: 8),
                Text(comic.stars!.toStringAsFixed(2)),
              ],
            ).paddingLeft(16).paddingVertical(8),
          for (var e in comic.tags.entries)
            buildWrap(
              children: [
                if (e.value.isNotEmpty)
                  buildTag(text: e.key.ts(comicSource.key), isTitle: true),
                for (var tag in e.value)
                  buildTag(
                    text: enableTranslation
                        ? TagsTranslation.translationTagWithNamespace(
                            tag,
                            e.key.toLowerCase(),
                          )
                        : tag,
                    onTap: () => onTapTag(tag, e.key),
                  ),
              ],
            ),
          if (comic.uploader != null)
            buildWrap(
              children: [
                buildTag(text: 'Uploader'.tl, isTitle: true),
                buildTag(text: comic.uploader!),
              ],
            ),
          if (comic.uploadTime != null)
            buildWrap(
              children: [
                buildTag(text: 'Upload Time'.tl, isTitle: true),
                buildTag(text: formatTime(comic.uploadTime!)),
              ],
            ),
          if (comic.updateTime != null)
            buildWrap(
              children: [
                buildTag(text: 'Update Time'.tl, isTitle: true),
                buildTag(text: formatTime(comic.updateTime!)),
              ],
            ),
          if (comic.maxPage != null)
            buildWrap(
              children: [
                buildTag(text: 'Pages'.tl, isTitle: true),
                buildTag(text: comic.maxPage.toString()),
              ],
            ),
          const SizedBox(height: 12),
          const Divider(),
        ],
      ),
    );
  }

  Widget buildChapters() {
    if (comic.chapters == null) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return _ComicChapters(
      history: history,
      groupedMode: comic.chapters!.isGrouped,
    );
  }

  Widget buildThumbnails() {
    if (comic.thumbnails == null && comicSource.loadComicThumbnail == null) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return const _ComicThumbnails();
  }

  Widget buildRecommend() {
    if (comic.recommend == null || comic.recommend!.isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: ListTile(title: Text("Related".tl))),
        SliverGridComics(comics: comic.recommend!),
      ],
    );
  }

  Widget buildComments() {
    if (comic.comments == null || comic.comments!.isEmpty) {
      return const SliverPadding(padding: EdgeInsets.zero);
    }
    return _CommentsPart(comments: comic.comments!, showMore: showComments);
  }

  void _viewCover(BuildContext context) {
    final imageProvider = CachedImageProvider(
      widget.cover ?? comic.cover,
      sourceKey: comic.sourceKey,
      cid: comic.id,
    );

    context.to(
      () => _CoverViewer(
        imageProvider: imageProvider,
        title: comic.title,
        heroTag: "cover${widget.heroID}",
      ),
    );
  }

  void _saveCover(BuildContext context) async {
    try {
      final imageProvider = CachedImageProvider(
        widget.cover ?? comic.cover,
        sourceKey: comic.sourceKey,
        cid: comic.id,
      );

      final imageStream = imageProvider.resolve(const ImageConfiguration());
      final completer = Completer<Uint8List>();

      imageStream.addListener(
        ImageStreamListener((ImageInfo info, bool _) async {
          final byteData = await info.image.toByteData(
            format: ImageByteFormat.png,
          );
          if (byteData != null) {
            completer.complete(byteData.buffer.asUint8List());
          }
        }),
      );

      final data = await completer.future;
      final fileType = detectFileType(data);
      await saveFile(filename: "cover${fileType.ext}", data: data);
    } catch (e) {
      if (context.mounted) {
        context.showMessage(message: "Error".tl);
      }
    }
  }
}

class _ActionButton extends StatefulWidget {
  const _ActionButton({
    required this.icon,
    required this.text,
    required this.onPressed,
    this.onLongPressed,
    this.activeIcon,
    this.isActive,
    this.isLoading,
    this.iconColor,
  });

  final Widget icon;

  final Widget? activeIcon;

  final bool? isActive;

  final String text;

  final void Function() onPressed;

  final bool? isLoading;

  final Color? iconColor;

  final void Function()? onLongPressed;

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  /// 手指按住时为 true。收藏按钮点开的是面板、图标状态不会立刻变，
  /// 靠这一下按压回缩给「点到了」的回执。
  bool _pressed = false;

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
        onTap: () {
          if (!(widget.isLoading ?? false)) {
            widget.onPressed();
          }
        },
        onLongPress: widget.onLongPressed,
        onHighlightChanged: (v) {
          if (_pressed != v) {
            setState(() {
              _pressed = v;
            });
          }
        },
        borderRadius: BorderRadius.circular(18),
        child: IconTheme.merge(
          data: IconThemeData(size: 20, color: widget.iconColor),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 加载中的 spinner 也必须放在 _BouncyActiveIcon 内部。
              // 之前用 if/else 在外层切分支，请求开始会把图标整个卸载，
              // 请求结束时再新建一个 State —— didUpdateWidget 不会触发，
              // 于是「点赞成功」这一下的弹跳永远不会播。
              _BouncyActiveIcon(
                active: widget.isActive ?? false,
                pressed: _pressed,
                child: (widget.isLoading ?? false)
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 1.8),
                      )
                    : ((widget.isActive ?? false)
                          ? (widget.activeIcon ?? widget.icon)
                          : widget.icon),
              ),
              const SizedBox(width: 8),
              Text(widget.text),
            ],
          ).paddingHorizontal(16),
        ),
      ),
    );
  }
}

/// 收藏 / 点赞图标的状态反馈：从「未激活」变成「激活」时弹一下。
///
/// 图标本身是硬切（描边 → 实心），加上这一下缩放和轻触感，
/// 收藏这种高频操作才有「点到了」的回执。
class _BouncyActiveIcon extends StatefulWidget {
  const _BouncyActiveIcon({
    required this.active,
    required this.child,
    this.pressed = false,
  });

  final bool active;

  /// 手指按住时轻微回缩，松手弹回。
  final bool pressed;

  final Widget child;

  @override
  State<_BouncyActiveIcon> createState() => _BouncyActiveIconState();
}

class _BouncyActiveIconState extends State<_BouncyActiveIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 280),
  );

  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 1.0,
        end: 1.3,
      ).chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.3,
        end: 0.94,
      ).chain(CurveTween(curve: Curves.easeInOut)),
      weight: 35,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: 0.94,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.easeOutCubic)),
      weight: 30,
    ),
  ]).animate(_controller);

  @override
  void didUpdateWidget(_BouncyActiveIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.active && widget.active) {
      HapticFeedback.lightImpact();
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: widget.pressed ? 0.86 : 1.0,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOut,
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}

class _SelectDownloadChapter extends StatefulWidget {
  const _SelectDownloadChapter(this.eps, this.finishSelect, this.downloadedEps);

  final List<String> eps;
  final void Function(List<int>) finishSelect;
  final List<int> downloadedEps;

  @override
  State<_SelectDownloadChapter> createState() => _SelectDownloadChapterState();
}

class _SelectDownloadChapterState extends State<_SelectDownloadChapter> {
  List<int> selected = [];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text("Download".tl),
        backgroundColor: context.colorScheme.surfaceContainerLow,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: widget.eps.length,
              itemBuilder: (context, i) {
                return CheckboxListTile(
                  title: Text(widget.eps[i]),
                  value:
                      selected.contains(i) || widget.downloadedEps.contains(i),
                  onChanged: widget.downloadedEps.contains(i)
                      ? null
                      : (v) {
                          setState(() {
                            if (selected.contains(i)) {
                              selected.remove(i);
                            } else {
                              selected.add(i);
                            }
                          });
                        },
                );
              },
            ),
          ),
          Container(
            height: 50,
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: context.colorScheme.outlineVariant),
              ),
            ),
            child: Row(
              children: [
                const SizedBox(width: 16),
                Expanded(
                  child: TextButton(
                    onPressed: () {
                      var res = <int>[];
                      for (int i = 0; i < widget.eps.length; i++) {
                        if (!widget.downloadedEps.contains(i)) {
                          res.add(i);
                        }
                      }
                      widget.finishSelect(res);
                      context.pop();
                    },
                    child: Text("Download All".tl),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: FilledButton(
                    onPressed: selected.isEmpty
                        ? null
                        : () {
                            widget.finishSelect(selected);
                            context.pop();
                          },
                    child: Text("Download Selected".tl),
                  ),
                ),
                const SizedBox(width: 16),
              ],
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom),
        ],
      ),
    );
  }
}

class _ComicPageLoadingPlaceHolder extends StatelessWidget {
  const _ComicPageLoadingPlaceHolder({
    this.cover,
    this.title,
    required this.sourceKey,
    required this.cid,
    this.heroID,
  });

  final String? cover;

  final String? title;

  final String sourceKey;

  final String cid;

  final int? heroID;

  @override
  Widget build(BuildContext context) {
    Widget buildContainer(
      double? width,
      double? height, {
      Color? color,
      double? radius,
    }) {
      return Container(
        height: height,
        width: width,
        decoration: BoxDecoration(
          color: color ?? context.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(radius ?? 4),
        ),
      );
    }

    return Shimmer(
      color: context.isDarkMode ? Colors.grey.shade700 : Colors.white,
      child: Column(
        children: [
          Appbar(title: Text(""), backgroundColor: context.colorScheme.surface),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(width: 16),
              buildImage(context),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title != null)
                      Text(title ?? "", style: ts.s18)
                    else
                      buildContainer(200, 25),
                    const SizedBox(height: 8),
                    buildContainer(80, 20),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (context.width < changePoint)
            Row(
              children: [
                Expanded(child: buildContainer(null, 36, radius: 18)),
                const SizedBox(width: 16),
                Expanded(child: buildContainer(null, 36, radius: 18)),
              ],
            ).paddingHorizontal(16),
          const Divider(),
          const SizedBox(height: 8),
          Center(
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
            ).fixHeight(24).fixWidth(24),
          ),
        ],
      ),
    );
  }

  Widget buildImage(BuildContext context) {
    Widget child;
    if (cover != null) {
      child = AnimatedImage(
        image: CachedImageProvider(cover!, sourceKey: sourceKey, cid: cid),
        width: double.infinity,
        height: double.infinity,
        fit: BoxFit.cover,
      );
    } else {
      child = const SizedBox();
    }

    return Hero(
      tag: "cover$heroID",
      child: Container(
        decoration: BoxDecoration(
          color: context.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: context.colorScheme.outlineVariant,
              blurRadius: 1,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        height: 144,
        width: 144 * 0.72,
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}
