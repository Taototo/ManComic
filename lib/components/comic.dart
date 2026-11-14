part of 'components.dart';

ImageProvider? findImageProvider(Comic comic) {
  ImageProvider image;
  if (comic is LocalComic) {
    image = LocalComicImageProvider(comic);
  } else if (comic is History) {
    image = HistoryImageProvider(comic);
  } else if (comic.sourceKey == 'local') {
    var localComic = LocalManager().find(comic.id, ComicType.local);
    if (localComic == null) {
      return null;
    }
    image = FileImage(localComic.coverFile);
  } else {
    image = CachedImageProvider(
      comic.cover,
      sourceKey: comic.sourceKey,
      cid: comic.id,
      fallbackToLocalCover: comic is FavoriteItem,
    );
  }
  return image;
}

/// [ComicTile] 长按菜单里由组件自己提供的通用动作。
///
/// 各页面需要的项并不相同：收藏页的书本来就在收藏夹里，「加入收藏」是死项；
/// 「详情」在长按预览卡上已经是一个按钮，菜单里再出现一次就是同义重复。
/// 调用方可以按需裁剪，避免同一个动作在一屏里出现两次。
enum ComicMenuAction { details, copyTitle, addToFavorites, block }

const Set<ComicMenuAction> kComicMenuActionsAll = {
  ComicMenuAction.details,
  ComicMenuAction.copyTitle,
  ComicMenuAction.addToFavorites,
  ComicMenuAction.block,
};

/// 收藏类页面用：书已在收藏夹，「详情 / 加收藏」由预览卡与列表承担。
const Set<ComicMenuAction> kComicMenuActionsFavorite = {
  ComicMenuAction.copyTitle,
  ComicMenuAction.block,
};

/// 网络收藏夹用：详情与换源已由预览卡承担，但「加入收藏」仍有意义
/// （源站收藏夹里的书未必已经收进本地收藏）。
const Set<ComicMenuAction> kComicMenuActionsNetworkFavorite = {
  ComicMenuAction.copyTitle,
  ComicMenuAction.addToFavorites,
  ComicMenuAction.block,
};

class ComicTile extends StatelessWidget {
  const ComicTile({
    super.key,
    required this.comic,
    this.enableLongPressed = true,
    this.badge,
    this.menuOptions,
    this.builtInMenuActions = kComicMenuActionsAll,
    this.onTap,
    this.onLongPressed,
    this.heroID,
    this.showUpdateTime = false,
  });

  final Comic comic;

  final bool enableLongPressed;

  /// 长按菜单里保留哪些通用动作，默认全部保留
  final Set<ComicMenuAction> builtInMenuActions;

  /// 在缩略图右上角显示最近更新时间（数据不可知时不显示）
  final bool showUpdateTime;

  final String? badge;

  final List<MenuEntry>? menuOptions;

  final VoidCallback? onTap;

  final VoidCallback? onLongPressed;

  final int? heroID;

  void _onTap() {
    if (onTap != null) {
      onTap!();
      return;
    }
    App.mainNavigatorKey?.currentContext?.to(
      () => ComicPage(
        id: comic.id,
        sourceKey: comic.sourceKey,
        cover: comic.cover,
        title: comic.title,
        heroID: heroID,
      ),
    );
  }

  void _onLongPressed(BuildContext context) {
    if (onLongPressed != null) {
      onLongPressed!();
      return;
    }
    HapticFeedback.selectionClick();
    ComicPeek.show(
      context,
      comic,
      // 菜单锚点由预览卡上的「更多」按钮给出：面板收起、菜单在原地展开。
      onMenu: (anchor) => showMenu(anchor, context, fromPeek: true),
    );
  }

  void onLongPress(BuildContext context) {
    var renderBox = context.findRenderObject() as RenderBox;
    var size = renderBox.size;
    var location = renderBox.localToGlobal(
      Offset((size.width - 242) / 2, size.height / 2),
    );
    showMenu(location, context, fromPeek: true);
  }

  void onSecondaryTap(TapDownDetails details, BuildContext context) {
    showMenu(details.globalPosition, context);
  }

  void showMenu(
    Offset location,
    BuildContext context, {
    bool fromPeek = false,
  }) {
    final actions = builtInMenuActions;
    // 桌面右键不经过预览卡，「详情」在那里是唯一入口，必须保留；
    // 只有从预览卡进来时才允许按调用方的裁剪规则去掉它。
    final showDetails = actions.contains(ComicMenuAction.details) || !fromPeek;
    showMenuX(App.rootContext, location, [
      if (showDetails)
        MenuEntry(
          icon: Icons.chrome_reader_mode_outlined,
          text: 'Details'.tl,
          onClick: () {
            App.mainNavigatorKey?.currentContext?.to(
              () => ComicPage(
                id: comic.id,
                sourceKey: comic.sourceKey,
                cover: comic.cover,
                title: comic.title,
              ),
            );
          },
        ),
      if (actions.contains(ComicMenuAction.copyTitle))
        MenuEntry(
          icon: Icons.copy,
          text: 'Copy Title'.tl,
          onClick: () {
            Clipboard.setData(ClipboardData(text: comic.title));
            App.rootContext.showMessage(message: 'Title copied'.tl);
          },
        ),
      if (actions.contains(ComicMenuAction.addToFavorites))
        MenuEntry(
          icon: Icons.stars_outlined,
          text: 'Add to favorites'.tl,
          onClick: () {
            addFavorite([comic]);
          },
        ),
      if (actions.contains(ComicMenuAction.block))
        MenuEntry(
          icon: Icons.block,
          text: 'Block'.tl,
          onClick: () => block(context),
        ),
      ...?menuOptions,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    var type = appdata.settings['comicDisplayMode'];
    var layoutMode = appdata.settings['comicLayoutMode'] ?? 'grid';

    Widget child;
    // 在流式布局中，即使是详细模式也使用垂直布局
    if (layoutMode == 'staggered') {
      child = _buildBriefMode(context);
    } else {
      child = type == 'detailed'
          ? _buildDetailedMode(context)
          : _buildBriefMode(context);
    }

    var isFavorite = appdata.settings['showFavoriteStatusOnTile']
        ? LocalFavoritesManager().isExist(
            comic.id,
            ComicType(comic.sourceKey.hashCode),
          )
        : false;
    var history = appdata.settings['showHistoryStatusOnTile']
        ? HistoryManager().find(comic.id, ComicType(comic.sourceKey.hashCode))
        : null;
    if (history?.page == 0) {
      history!.page = 1;
    }

    if (!isFavorite && history == null) {
      return child;
    }

    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          left: type == 'detailed' ? 16 : 6,
          top: 8,
          child: Container(
            height: 24,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(4)),
            clipBehavior: Clip.antiAlias,
            child: Row(
              children: [
                if (isFavorite)
                  Container(
                    height: 24,
                    width: 24,
                    color: Colors.green,
                    child: const Icon(
                      Icons.bookmark_rounded,
                      size: 16,
                      color: Colors.white,
                    ),
                  ),
                if (history != null)
                  Container(
                    height: 24,
                    color: Colors.blue.toOpacity(0.9),
                    constraints: const BoxConstraints(minWidth: 24),
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: CustomPaint(
                      painter: _ReadingHistoryPainter(
                        history.page,
                        history.maxPage,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget buildImage(BuildContext context) {
    var image = findImageProvider(comic);
    if (image == null) {
      return const SizedBox();
    }
    return AnimatedImage(
      image: image,
      // 按显示尺寸解码，别再按封面原图（常见 1500×2000）整张解进内存
      cacheWidth: kCoverDecodeWidth,
      fit: BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
    );
  }

  /// 封面底部阅读进度条 + 追更未读小圆点
  Widget buildImageWithStatus(BuildContext context) {
    final child = buildImage(context);
    History? history;
    if (comic is History) {
      history = comic as History;
    } else if (appdata.settings['showHistoryStatusOnTile'] == true) {
      history = HistoryManager().find(
        comic.id,
        ComicType(comic.sourceKey.hashCode),
      );
    }
    final maxPage = history?.maxPage ?? 0;
    final progress = (history != null && maxPage > 0)
        ? (history.page / maxPage).clamp(0.0, 1.0)
        : null;
    final c = comic;
    final hasUpdate = c is FavoriteItemWithUpdateInfo && c.hasNewUpdate;
    final updateText = showUpdateTime
        ? formatComicUpdateBadge(findComicUpdateTime(comic))
        : null;

    if (progress == null && !hasUpdate && updateText == null) {
      return child;
    }

    return Stack(
      children: [
        Positioned.fill(child: child),
        if (progress != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              height: 3,
              color: Colors.black.withValues(alpha: 0.32),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: progress,
                child: Container(color: context.colorScheme.primary),
              ),
            ),
          ),
        // 更新时间 + 追更红点，一起放在右上角。
        //
        // 这块角标换过三次位置：最早在左上（被「已收藏／阅读进度」那组盖死），
        // 后来挪到左下（又和瀑布流模式的描述浮层打架）。右上角原本是追更红点
        // 独占的，而红点只是个 9px 的圆点，和更新时间并排放在同一行就好——两者
        // 本来就是同一件事的两面：「有新章节」和「上次什么时候更新」。
        if (hasUpdate || updateText != null)
          Positioned(
            right: 5,
            top: 5,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasUpdate)
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: Colors.redAccent,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 3,
                        ),
                      ],
                    ),
                  ),
                if (hasUpdate && updateText != null) const SizedBox(width: 3),
                if (updateText != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      updateText,
                      style: const TextStyle(
                        fontSize: 9,
                        height: 1.25,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildDetailedMode(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constrains) {
        final height = constrains.maxHeight - 16;

        Widget image = Container(
          width: height * 0.68,
          height: double.infinity,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: context.colorScheme.outlineVariant,
                blurRadius: 1,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: buildImageWithStatus(context),
        );

        if (heroID != null) {
          image = Hero(tag: "cover$heroID", child: image);
        }

        return InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: _onTap,
          onLongPress: enableLongPressed ? () => _onLongPressed(context) : null,
          onSecondaryTapDown: (detail) => onSecondaryTap(detail, context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 24, 8),
            child: Row(
              children: [
                image,
                SizedBox.fromSize(size: const Size(16, 5)),
                Expanded(
                  child: _ComicDescription(
                    title: comic.maxPage == null
                        ? comic.title.replaceAll("\n", "")
                        : "[${comic.maxPage}P]${comic.title.replaceAll("\n", "")}",
                    subtitle: comic.subtitle ?? '',
                    description: comic.description,
                    badge: badge ?? comic.language,
                    tags: comic.tags,
                    maxLines: 2,
                    enableTranslate:
                        ComicSource.find(
                          comic.sourceKey,
                        )?.enableTagsTranslate ??
                        false,
                    rating: comic.stars,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBriefMode(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 检查是否为流式布局模式
        var layoutMode = appdata.settings['comicLayoutMode'] ?? 'grid';
        var isStaggeredLayout = layoutMode == 'staggered';
        Widget image = Container(
          decoration: BoxDecoration(
            color: context.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(isStaggeredLayout ? 12 : 8),
            boxShadow: isStaggeredLayout
                ? [
                    // 主阴影 - 更深的阴影营造立体感
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                      spreadRadius: 0,
                    ),
                    // 环境光阴影 - 柔和的整体阴影
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.08),
                      blurRadius: 16,
                      offset: const Offset(0, 2),
                      spreadRadius: 0,
                    ),
                  ]
                : [
                    BoxShadow(
                      color: Colors.black.toOpacity(0.2),
                      blurRadius: 2,
                      offset: const Offset(0, 2),
                    ),
                  ],
          ),
          clipBehavior: Clip.antiAlias,
          child: buildImageWithStatus(context),
        );

        if (heroID != null) {
          image = Hero(tag: "cover$heroID", child: image);
        }

        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _onTap,
          onLongPress: enableLongPressed ? () => _onLongPressed(context) : null,
          onSecondaryTapDown: (detail) => onSecondaryTap(detail, context),
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: image),
                    Align(
                      alignment: Alignment.bottomRight,
                      child: (() {
                        final subtitle = comic.subtitle
                            ?.replaceAll('\n', '')
                            .trim();
                        final text = comic.description.isNotEmpty
                            ? comic.description.split('|').join('\n')
                            : (subtitle?.isNotEmpty == true ? subtitle : null);
                        final fortSize = constraints.maxWidth < 80
                            ? 8.0
                            : constraints.maxWidth < 150
                            ? 10.0
                            : 12.0;

                        if (text == null) {
                          return const SizedBox();
                        }

                        var children = <Widget>[];
                        var lines = text.split('\n');
                        lines.removeWhere((e) => e.trim().isEmpty);
                        if (lines.length > 3) {
                          lines = lines.sublist(0, 3);
                        }
                        for (var line in lines) {
                          children.add(
                            Container(
                              margin: const EdgeInsets.fromLTRB(2, 0, 2, 2),
                              padding: constraints.maxWidth < 80
                                  ? const EdgeInsets.fromLTRB(3, 1, 3, 1)
                                  : constraints.maxWidth < 150
                                  ? const EdgeInsets.fromLTRB(4, 2, 4, 2)
                                  : const EdgeInsets.fromLTRB(5, 2, 5, 2),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                color: Colors.black.toOpacity(0.5),
                              ),
                              constraints: BoxConstraints(
                                maxWidth: constraints.maxWidth,
                              ),
                              child: Text(
                                line,
                                style: TextStyle(
                                  fontWeight: FontWeight.w500,
                                  fontSize: fortSize,
                                  color: Colors.white,
                                ),
                                textAlign: TextAlign.right,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          );
                        }
                        return Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: children,
                        );
                      })(),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                child: Text(
                  comic.title.replaceAll('\n', ''),
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ).paddingHorizontal(6).paddingVertical(8),
        );
      },
    );
  }

  List<String> _splitText(String text) {
    // split text by comma, brackets
    var words = <String>[];
    var buffer = StringBuffer();
    var inBracket = false;
    String? prevBracket;
    for (var i = 0; i < text.length; i++) {
      var c = text[i];
      if (c == '[' || c == '(') {
        if (inBracket) {
          buffer.write(c);
        } else {
          if (buffer.isNotEmpty) {
            words.add(buffer.toString().trim());
            buffer.clear();
          }
          inBracket = true;
          prevBracket = c;
        }
      } else if (c == ']' || c == ')') {
        if (prevBracket == '[' && c == ']' || prevBracket == '(' && c == ')') {
          if (buffer.isNotEmpty) {
            words.add(buffer.toString().trim());
            buffer.clear();
          }
          inBracket = false;
        } else {
          buffer.write(c);
        }
      } else if (c == ',') {
        if (inBracket) {
          buffer.write(c);
        } else {
          words.add(buffer.toString().trim());
          buffer.clear();
        }
      } else {
        buffer.write(c);
      }
    }
    if (buffer.isNotEmpty) {
      words.add(buffer.toString().trim());
    }
    words.removeWhere((element) => element == "");
    words = words.toSet().toList();
    return words;
  }

  void block(BuildContext comicTileContext) {
    showDialog(
      context: App.rootContext,
      builder: (context) {
        var words = <String>[];
        var all = <String>[];
        all.addAll(_splitText(comic.title));
        if (comic.subtitle != null && comic.subtitle != "") {
          all.add(comic.subtitle!);
        }
        all.addAll(comic.tags ?? []);
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: 'Block'.tl,
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: math.min(400, context.height - 136),
                ),
                child: SingleChildScrollView(
                  child: Wrap(
                    runSpacing: 8,
                    spacing: 8,
                    children: [
                      for (var word in all)
                        OptionChip(
                          text: (comic.tags?.contains(word) ?? false)
                              ? word.translateTagIfNeed
                              : word,
                          isSelected: words.contains(word),
                          onTap: () {
                            setState(() {
                              if (!words.contains(word)) {
                                words.add(word);
                              } else {
                                words.remove(word);
                              }
                            });
                          },
                        ),
                    ],
                  ),
                ).paddingHorizontal(16),
              ),
              actions: [
                Button.filled(
                  onPressed: () {
                    context.pop();
                    for (var word in words) {
                      appdata.settings['blockedWords'].add(word);
                    }
                    appdata.saveData();
                    context.showMessage(message: 'Blocked'.tl);
                    comicTileContext
                        .findAncestorStateOfType<_SliverGridComicsState>()!
                        .update();
                  },
                  child: Text('Block'.tl),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _ComicDescription extends StatelessWidget {
  const _ComicDescription({
    required this.title,
    required this.subtitle,
    required this.description,
    required this.enableTranslate,
    this.badge,
    this.maxLines = 2,
    this.tags,
    this.rating,
  });

  final String title;
  final String subtitle;
  final String description;
  final String? badge;
  final List<String>? tags;
  final int maxLines;
  final bool enableTranslate;
  final double? rating;

  @override
  Widget build(BuildContext context) {
    if (tags != null) {
      tags!.removeWhere((element) => element.removeAllBlank == "");
      for (var s in tags!) {
        s = s.replaceAll("\n", " ");
      }
    }
    var enableTranslate =
        App.locale.languageCode == 'zh' && this.enableTranslate;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title.trim(),
          style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14.0),
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          softWrap: true,
        ),
        if (subtitle != "")
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 10.0,
              color: context.colorScheme.onSurface.toOpacity(0.7),
            ),
            maxLines: 1,
            softWrap: true,
            overflow: TextOverflow.ellipsis,
          ),
        const SizedBox(height: 4),
        if (tags != null && tags!.isNotEmpty)
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxHeight < 22) {
                  return Container();
                }
                int cnt = (constraints.maxHeight - 22).toInt() ~/ 25;
                return Container(
                  clipBehavior: Clip.antiAlias,
                  height: 21 + cnt * 24,
                  width: double.infinity,
                  decoration: const BoxDecoration(),
                  child: Wrap(
                    runAlignment: WrapAlignment.start,
                    clipBehavior: Clip.antiAlias,
                    crossAxisAlignment: WrapCrossAlignment.end,
                    spacing: 4,
                    runSpacing: 3,
                    children: [
                      for (var s in tags!)
                        Container(
                          height: 21,
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth * 0.45,
                          ),
                          decoration: BoxDecoration(
                            color: s == "Unavailable"
                                ? context.colorScheme.errorContainer
                                : context.colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Center(
                            widthFactor: 1,
                            child: Text(
                              enableTranslate
                                  ? TagsTranslation.translateTag(s)
                                  : s.split(':').last,
                              style: const TextStyle(fontSize: 12),
                              softWrap: true,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                        ),
                    ],
                  ),
                ).toAlign(Alignment.topCenter);
              },
            ),
          )
        else
          const Spacer(),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (rating != null) StarRating(value: rating!, size: 18),
                  Text(
                    description,
                    style: const TextStyle(fontSize: 12.0),
                    maxLines: (tags == null || tags!.isEmpty) ? 3 : 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (badge != null)
              Container(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
                ),
                child: Center(
                  child: Text(
                    "${badge![0].toUpperCase()}${badge!.substring(1).toLowerCase()}",
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _ReadingHistoryPainter extends CustomPainter {
  final int page;
  final int? maxPage;

  const _ReadingHistoryPainter(this.page, this.maxPage);

  @override
  void paint(Canvas canvas, Size size) {
    if (maxPage == null) {
      // 在中央绘制page
      final textPainter = TextPainter(
        text: TextSpan(
          text: "$page",
          style: TextStyle(fontSize: size.width * 0.8, color: Colors.white),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(
          (size.width - textPainter.width) / 2,
          (size.height - textPainter.height) / 2,
        ),
      );
    } else if (page == maxPage) {
      // 在中央绘制勾
      final paint = Paint()
        ..color = Colors.white
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      canvas.drawLine(
        Offset(size.width * 0.2, size.height * 0.5),
        Offset(size.width * 0.45, size.height * 0.75),
        paint,
      );
      canvas.drawLine(
        Offset(size.width * 0.45, size.height * 0.75),
        Offset(size.width * 0.85, size.height * 0.3),
        paint,
      );
    } else {
      // 在左上角绘制page, 在右下角绘制maxPage
      final textPainter = TextPainter(
        text: TextSpan(
          text: "$page",
          style: TextStyle(fontSize: size.width * 0.8, color: Colors.white),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, const Offset(0, 0));
      final textPainter2 = TextPainter(
        text: TextSpan(
          text: "/$maxPage",
          style: TextStyle(fontSize: size.width * 0.5, color: Colors.white),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter2.layout();
      textPainter2.paint(
        canvas,
        Offset(
          size.width - textPainter2.width,
          size.height - textPainter2.height,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is! _ReadingHistoryPainter ||
        oldDelegate.page != page ||
        oldDelegate.maxPage != maxPage;
  }
}

class SliverGridComics extends StatefulWidget {
  const SliverGridComics({
    super.key,
    required this.comics,
    this.onLastItemBuild,
    this.badgeBuilder,
    this.menuBuilder,
    this.builtInMenuActions = kComicMenuActionsAll,
    this.onTap,
    this.onLongPressed,
    this.showUpdateTime = false,
    this.selections,
  });

  final List<Comic> comics;

  final bool showUpdateTime;

  final Map<Comic, bool>? selections;

  /// 长按菜单里保留哪些通用动作
  final Set<ComicMenuAction> builtInMenuActions;

  final void Function()? onLastItemBuild;

  final String? Function(Comic)? badgeBuilder;

  final List<MenuEntry> Function(Comic)? menuBuilder;

  final void Function(Comic, int heroID)? onTap;

  final void Function(Comic, int heroID)? onLongPressed;

  @override
  State<SliverGridComics> createState() => _SliverGridComicsState();
}

class _SliverGridComicsState extends State<SliverGridComics> {
  List<Comic> comics = [];
  List<int> heroIDs = [];

  /// 本次数据加载的时刻，用于限定首屏入场动画的播放窗口。
  /// 滚动回来重建的格子早已超过窗口，不会再放一遍动画。
  DateTime _epoch = DateTime.now();

  static int _nextHeroID = 0;

  void generateHeroID() {
    heroIDs.clear();
    for (var i = 0; i < comics.length; i++) {
      heroIDs.add(_nextHeroID++);
    }
  }

  @override
  void didUpdateWidget(covariant SliverGridComics oldWidget) {
    if (!comics.isEqualTo(widget.comics)) {
      comics.clear();
      for (var comic in widget.comics) {
        if (isBlocked(comic) == null) {
          comics.add(comic);
        }
      }
      generateHeroID();
      _epoch = DateTime.now();
    }
    super.didUpdateWidget(oldWidget);
  }

  @override
  void initState() {
    for (var comic in widget.comics) {
      if (isBlocked(comic) == null) {
        comics.add(comic);
      }
    }
    generateHeroID();
    HistoryManager().addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    HistoryManager().removeListener(update);
    super.dispose();
  }

  void update() {
    setState(() {
      comics.clear();
      for (var comic in widget.comics) {
        if (isBlocked(comic) == null) {
          comics.add(comic);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return _SliverGridComics(
      comics: comics,
      heroIDs: heroIDs,
      epoch: _epoch,
      selection: widget.selections,
      onLastItemBuild: widget.onLastItemBuild,
      badgeBuilder: widget.badgeBuilder,
      menuBuilder: widget.menuBuilder,
      builtInMenuActions: widget.builtInMenuActions,
      onTap: widget.onTap,
      onLongPressed: widget.onLongPressed,
      showUpdateTime: widget.showUpdateTime,
    );
  }
}

class _SliverGridComics extends StatelessWidget {
  const _SliverGridComics({
    required this.comics,
    required this.heroIDs,
    required this.epoch,
    this.onLastItemBuild,
    this.badgeBuilder,
    this.menuBuilder,
    this.builtInMenuActions = kComicMenuActionsAll,
    this.onTap,
    this.onLongPressed,
    this.showUpdateTime = false,
    this.selection,
  });

  final List<Comic> comics;

  final List<int> heroIDs;

  /// 数据加载时刻，用于限定首屏交错入场动画的播放窗口
  final DateTime epoch;

  final bool showUpdateTime;

  final Set<ComicMenuAction> builtInMenuActions;

  final Map<Comic, bool>? selection;

  final void Function()? onLastItemBuild;

  final String? Function(Comic)? badgeBuilder;

  final List<MenuEntry> Function(Comic)? menuBuilder;

  final void Function(Comic, int heroID)? onTap;

  final void Function(Comic, int heroID)? onLongPressed;

  @override
  Widget build(BuildContext context) {
    return SliverGrid(
      delegate: SliverChildBuilderDelegate((context, index) {
        if (index == comics.length - 1) {
          onLastItemBuild?.call();
        }
        var badge = badgeBuilder?.call(comics[index]);
        var isSelected = selection == null
            ? false
            : selection![comics[index]] ?? false;
        var comic = ComicTile(
          comic: comics[index],
          badge: badge,
          menuOptions: menuBuilder?.call(comics[index]),
          builtInMenuActions: builtInMenuActions,
          onTap: onTap != null
              ? () => onTap!(comics[index], heroIDs[index])
              : null,
          onLongPressed: onLongPressed != null
              ? () => onLongPressed!(comics[index], heroIDs[index])
              : null,
          heroID: heroIDs[index],
          showUpdateTime: showUpdateTime,
        );
        if (selection == null) {
          return StaggerIn(
            index: index,
            enabled:
                DateTime.now().difference(epoch) <
                const Duration(milliseconds: 700),
            child: comic,
          );
        }
        return StaggerIn(
          index: index,
          enabled:
              DateTime.now().difference(epoch) <
              const Duration(milliseconds: 700),
          child: AnimatedContainer(
            key: ValueKey(comics[index].id),
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: isSelected
                  ? Theme.of(
                      context,
                    ).colorScheme.secondaryContainer.toOpacity(0.72)
                  : null,
              borderRadius: BorderRadius.circular(12),
            ),
            margin: const EdgeInsets.all(4),
            child: comic,
          ),
        );
      }, childCount: comics.length),
      gridDelegate:
          (appdata.settings['comicLayoutMode'] ?? 'grid') == 'staggered'
          ? SliverStaggeredGridDelegateWithComics()
          : SliverGridDelegateWithComics(),
    );
  }
}

/// return the first blocked keyword, or null if not blocked
String? isBlocked(Comic item) {
  for (var word in appdata.settings['blockedWords']) {
    if (item.title.contains(word)) {
      return word;
    }
    if (item.subtitle?.contains(word) ?? false) {
      return word;
    }
    if (item.description.contains(word)) {
      return word;
    }
    for (var tag in item.tags ?? <String>[]) {
      if (tag == word) {
        return word;
      }
      if (tag.contains(':')) {
        tag = tag.split(':')[1];
        if (tag == word) {
          return word;
        }
      }
    }
  }
  return null;
}

class ComicList extends StatefulWidget {
  const ComicList({
    super.key,
    this.loadPage,
    this.loadNext,
    this.leadingSliver,
    this.trailingSliver,
    this.errorLeading,
    this.menuBuilder,
    this.builtInMenuActions = kComicMenuActionsAll,
    this.controller,
    this.refreshHandlerCallback,
    this.enablePageStorage = false,
    this.showUpdateTime = false,
  });

  final bool showUpdateTime;

  final Future<Res<List<Comic>>> Function(int page)? loadPage;

  final Future<Res<List<Comic>>> Function(String? next)? loadNext;

  final Widget? leadingSliver;

  final Widget? trailingSliver;

  final Widget? errorLeading;

  final List<MenuEntry> Function(Comic)? menuBuilder;

  /// 长按菜单里保留哪些通用动作
  final Set<ComicMenuAction> builtInMenuActions;

  final ScrollController? controller;

  final void Function(VoidCallback c)? refreshHandlerCallback;

  final bool enablePageStorage;

  @override
  State<ComicList> createState() => ComicListState();
}

class ComicListState extends State<ComicList> {
  int? _maxPage;

  final Map<int, List<Comic>> _data = {};

  int _page = 1;

  String? _error;

  final Map<int, bool> _loading = {};

  String? _nextUrl;

  late bool enablePageStorage = widget.enablePageStorage;

  Map<String, dynamic> get state => {
    'maxPage': _maxPage,
    'data': _data,
    'page': _page,
    'error': _error,
    'loading': _loading,
    'nextUrl': _nextUrl,
  };

  void restoreState(Map<String, dynamic>? state) {
    if (state == null || !enablePageStorage) {
      return;
    }
    _maxPage = state['maxPage'];
    _data.clear();
    _data.addAll(state['data']);
    _page = state['page'];
    _error = state['error'];
    _loading.clear();
    _loading.addAll(state['loading']);
    _nextUrl = state['nextUrl'];
  }

  void storeState() {
    if (enablePageStorage) {
      PageStorage.of(context).writeState(context, state);
    }
  }

  void refresh() {
    _data.clear();
    _page = 1;
    _maxPage = null;
    _error = null;
    _nextUrl = null;
    _loading.clear();
    storeState();
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    restoreState(PageStorage.of(context).readState(context));
    widget.refreshHandlerCallback?.call(refresh);
  }

  void remove(Comic c) {
    if (_data[_page] == null || !_data[_page]!.remove(c)) {
      for (var page in _data.values) {
        if (page.remove(c)) {
          break;
        }
      }
    }
    setState(() {});
  }

  Widget _buildPageSelector() {
    return Row(
      children: [
        FilledButton(
          onPressed: _page > 1
              ? () {
                  setState(() {
                    _error = null;
                    _page--;
                  });
                }
              : null,
          child: Text("Back".tl),
        ).fixWidth(84),
        Expanded(
          child: Center(
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainer,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  String value = '';
                  showDialog(
                    context: App.rootContext,
                    builder: (context) {
                      return ContentDialog(
                        title: "Jump to page".tl,
                        content: TextField(
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(labelText: "Page".tl),
                          inputFormatters: <TextInputFormatter>[
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          onChanged: (v) {
                            value = v;
                          },
                        ).paddingHorizontal(16),
                        actions: [
                          Button.filled(
                            onPressed: () {
                              Navigator.of(context).pop();
                              var page = int.tryParse(value);
                              if (page == null) {
                                context.showMessage(message: "Invalid page".tl);
                              } else {
                                if (page > 0 &&
                                    (_maxPage == null || page <= _maxPage!)) {
                                  setState(() {
                                    _error = null;
                                    _page = page;
                                  });
                                } else {
                                  context.showMessage(
                                    message: "Invalid page".tl,
                                  );
                                }
                              }
                            },
                            child: Text("Jump".tl),
                          ),
                        ],
                      );
                    },
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: Text("第 $_page / ${_maxPage ?? '?'} 页"),
                ),
              ),
            ),
          ),
        ),
        FilledButton(
          // 总页数未知（第一页就没加载出来）时不能给「前进」：原来的兜底
          // `_maxPage ?? (_page + 1)` 让它恒为真，错误页上的前进永远点得动，
          // 点了只是把 _page 加一然后再失败一次。
          onPressed: _maxPage != null && _page < _maxPage!
              ? () {
                  setState(() {
                    _error = null;
                    _page++;
                  });
                }
              : null,
          child: Text("Next".tl),
        ).fixWidth(84),
      ],
    ).paddingVertical(8).paddingHorizontal(16);
  }

  Widget _buildSliverPageSelector() {
    return SliverToBoxAdapter(child: _buildPageSelector());
  }

  Future<void> _loadPage(int page) async {
    if (widget.loadPage == null && widget.loadNext == null) {
      _error = "loadPage and loadNext can't be null at the same time";
      Future.microtask(() {
        setState(() {});
      });
    }
    if (_data[page] != null || _loading[page] == true) {
      return;
    }
    _loading[page] = true;
    try {
      if (widget.loadPage != null) {
        var res = await widget.loadPage!(page);
        if (!mounted) return;
        if (res.success) {
          if (res.data.isEmpty) {
            setState(() {
              _data[page] = const [];
              _maxPage ??= page;
            });
          } else {
            setState(() {
              _data[page] = res.data;
              if (res.subData != null && res.subData is int) {
                _maxPage = res.subData;
              }
            });
          }
        } else {
          setState(() {
            _error = res.errorMessage ?? "Unknown error".tl;
          });
        }
      } else {
        try {
          while (_data[page] == null) {
            await _fetchNext();
          }
          if (mounted) {
            setState(() {});
          }
        } catch (e) {
          if (mounted) {
            setState(() {
              _error = e.toString();
            });
          }
        }
      }
    } finally {
      _loading[page] = false;
      storeState();
    }
  }

  Future<void> _fetchNext() async {
    var res = await widget.loadNext!(_nextUrl);
    _data[_data.length + 1] = res.data;
    if (res.subData == null) {
      _maxPage = _data.length;
    } else {
      _nextUrl = res.subData;
    }
  }

  @override
  Widget build(BuildContext context) {
    var type = appdata.settings['comicListDisplayMode'];
    return type == 'paging' ? buildPagingMode() : buildContinuousMode();
  }

  Widget buildPagingMode() {
    if (_error != null) {
      // 错误态没有可翻的页：一页都没成功过，那个「后退 / 第 1 / ? 页 / 前进」
      // 条只会挡住错误信息和「重试」。它原来还压在状态栏上——正常态有
      // SliverAppbar 消费顶部留白，这条错误分支是个裸 Column，没人付
      // padding.top，于是整条跑到时间和信号图标上面去了。
      return Column(
        children: [
          if (widget.errorLeading != null)
            widget.errorLeading!
          else
            SizedBox(height: context.padding.top),
          // 翻页模式下如果是从第 3 页掉下来的，仍然要能退回去。
          if (_data.isNotEmpty) _buildPageSelector(),
          Expanded(
            child: NetworkError(
              withAppbar: false,
              message: _error!,
              retry: () {
                setState(() {
                  _error = null;
                });
              },
            ),
          ),
        ],
      );
    }
    if (_data[_page] == null) {
      _loadPage(_page);
      return Column(
        children: [
          if (widget.errorLeading != null) widget.errorLeading!,
          const Expanded(child: Center(child: FiveDotLoadingAnimation())),
        ],
      );
    }
    return SmoothCustomScrollView(
      key: enablePageStorage ? PageStorageKey('scroll$_page') : null,
      controller: widget.controller,
      slivers: [
        if (widget.leadingSliver != null) widget.leadingSliver!,
        if (_maxPage != 1) _buildSliverPageSelector(),
        SliverGridComics(
          comics: _data[_page] ?? const [],
          menuBuilder: widget.menuBuilder,
          builtInMenuActions: widget.builtInMenuActions,
          showUpdateTime: widget.showUpdateTime,
        ),
        if (_data[_page]!.length > 6 && _maxPage != 1)
          _buildSliverPageSelector(),
        if (widget.trailingSliver != null) widget.trailingSliver!,
      ],
    );
  }

  Widget buildContinuousMode() {
    if (_error != null && _data.isEmpty) {
      // 同上：连读模式下第一页就失败时，没有页可翻。
      return Column(
        children: [
          if (widget.errorLeading != null)
            widget.errorLeading!
          else
            SizedBox(height: context.padding.top),
          Expanded(
            child: NetworkError(
              withAppbar: false,
              message: _error!,
              retry: () {
                setState(() {
                  _error = null;
                });
              },
            ),
          ),
        ],
      );
    }
    if (_data[1] == null) {
      _loadPage(1);
      return Column(
        children: [
          if (widget.errorLeading != null) widget.errorLeading!,
          const Expanded(child: Center(child: FiveDotLoadingAnimation())),
        ],
      );
    }
    return SmoothCustomScrollView(
      key: enablePageStorage ? PageStorageKey('scroll$_page') : null,
      controller: widget.controller,
      slivers: [
        if (widget.leadingSliver != null) widget.leadingSliver!,
        SliverGridComics(
          comics: _data.values.expand((element) => element).toList(),
          menuBuilder: widget.menuBuilder,
          builtInMenuActions: widget.builtInMenuActions,
          showUpdateTime: widget.showUpdateTime,
          onLastItemBuild: () {
            if (_error == null &&
                (_maxPage == null || _data.length < _maxPage!)) {
              _loadPage(_data.length + 1);
            }
          },
        ),
        if (_error != null)
          SliverToBoxAdapter(
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.error_outline),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_error!, maxLines: 3)),
                  ],
                ),
                const SizedBox(height: 8),
                Center(
                  child: OutlinedButton(
                    onPressed: () {
                      setState(() {
                        _error = null;
                      });
                    },
                    child: Text("Retry".tl),
                  ),
                ),
              ],
            ).paddingHorizontal(16).paddingVertical(8),
          )
        else if (_maxPage == null || _data.length < _maxPage!)
          const SliverListLoadingIndicator(),
        if (widget.trailingSliver != null) widget.trailingSliver!,
      ],
    );
  }
}

class StarRating extends StatelessWidget {
  const StarRating({
    super.key,
    required this.value,
    this.onTap,
    this.size = 20,
  });

  final double value; // 0-5

  final VoidCallback? onTap;

  final double size;

  @override
  Widget build(BuildContext context) {
    var interval = size * 0.1;
    var value = this.value;
    if (value.isNaN) {
      value = 0;
    }
    var child = SizedBox(
      height: size,
      width: size * 5 + interval * 4,
      child: Row(
        children: [
          for (var i = 0; i < 5; i++)
            _Star(
              value: (value - i).clamp(0.0, 1.0),
              size: size,
            ).paddingRight(i == 4 ? 0 : interval),
        ],
      ),
    );
    return onTap == null ? child : GestureDetector(onTap: onTap, child: child);
  }
}

class _Star extends StatelessWidget {
  const _Star({required this.value, required this.size});

  final double value; // 0-1

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Icon(
            Icons.star_outline,
            size: size,
            color: context.colorScheme.secondary,
          ),
          ClipRect(
            clipper: _StarClipper(value),
            child: Icon(
              Icons.star,
              size: size,
              color: context.colorScheme.secondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _StarClipper extends CustomClipper<Rect> {
  final double value;

  _StarClipper(this.value);

  @override
  Rect getClip(Size size) {
    return Rect.fromLTWH(0, 0, size.width * value, size.height);
  }

  @override
  bool shouldReclip(covariant CustomClipper<Rect> oldClipper) {
    return oldClipper is! _StarClipper || oldClipper.value != value;
  }
}

class RatingWidget extends StatefulWidget {
  /// star number
  final int count;

  /// Max score
  final double maxRating;

  /// Current score value
  final double value;

  /// Star size
  final double size;

  /// Space between the stars
  final double padding;

  /// Whether the score can be modified by sliding
  final bool selectable;

  /// Callbacks when ratings change
  final ValueChanged<double> onRatingUpdate;

  const RatingWidget({
    super.key,
    this.maxRating = 10.0,
    this.count = 5,
    this.value = 10.0,
    this.size = 20,
    required this.padding,
    this.selectable = false,
    required this.onRatingUpdate,
  });

  @override
  State<RatingWidget> createState() => _RatingWidgetState();
}

class _RatingWidgetState extends State<RatingWidget> {
  double value = 10;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (PointerDownEvent event) {
        double x = event.localPosition.dx;
        if (x < 0) x = 0;
        pointValue(x);
      },
      onPointerMove: (PointerMoveEvent event) {
        double x = event.localPosition.dx;
        if (x < 0) x = 0;
        pointValue(x);
      },
      onPointerUp: (_) {},
      behavior: HitTestBehavior.deferToChild,
      child: buildRowRating(),
    );
  }

  pointValue(double dx) {
    if (!widget.selectable) {
      return;
    }
    if (dx >=
        widget.size * widget.count + widget.padding * (widget.count - 1)) {
      value = widget.maxRating;
    } else {
      for (double i = 1; i < widget.count + 1; i++) {
        if (dx > widget.size * i + widget.padding * (i - 1) &&
            dx < widget.size * i + widget.padding * i) {
          value = i * (widget.maxRating / widget.count);
          break;
        } else if (dx > widget.size * (i - 1) + widget.padding * (i - 1) &&
            dx < widget.size * i + widget.padding * i) {
          value =
              (dx - widget.padding * (i - 1)) /
              (widget.size * widget.count) *
              widget.maxRating;
          break;
        }
      }
    }
    if (value % 1 >= 0.5) {
      value = value ~/ 1 + 1;
    } else {
      value = (value ~/ 1).toDouble();
    }
    if (value < 0) {
      value = 0;
    } else if (value > 10) {
      value = 10;
    }
    setState(() {
      widget.onRatingUpdate(value);
    });
  }

  int fullStars() {
    return (value / (widget.maxRating / widget.count)).floor();
  }

  double star() {
    if (widget.count / fullStars() == widget.maxRating / value) {
      return 0;
    }
    return (value % (widget.maxRating / widget.count)) /
        (widget.maxRating / widget.count);
  }

  List<Widget> buildRow() {
    int full = fullStars();
    List<Widget> children = [];
    for (int i = 0; i < full; i++) {
      children.add(
        Icon(
          Icons.star,
          size: widget.size,
          color: context.colorScheme.secondary,
        ),
      );
      if (i < widget.count - 1) {
        children.add(SizedBox(width: widget.padding));
      }
    }
    if (full < widget.count) {
      children.add(
        ClipRect(
          clipper: _SMClipper(rating: star() * widget.size),
          child: Icon(
            Icons.star,
            size: widget.size,
            color: context.colorScheme.secondary,
          ),
        ),
      );
    }

    return children;
  }

  List<Widget> buildNormalRow() {
    List<Widget> children = [];
    for (int i = 0; i < widget.count; i++) {
      children.add(
        Icon(
          Icons.star_border,
          size: widget.size,
          color: context.colorScheme.secondary,
        ),
      );
      if (i < widget.count - 1) {
        children.add(SizedBox(width: widget.padding));
      }
    }
    return children;
  }

  Widget buildRowRating() {
    return Stack(
      children: <Widget>[
        Row(children: buildNormalRow()),
        Row(children: buildRow()),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    value = widget.value;
  }
}

class _SMClipper extends CustomClipper<Rect> {
  final double rating;

  _SMClipper({required this.rating});

  @override
  Rect getClip(Size size) {
    return Rect.fromLTRB(0.0, 0.0, rating, size.height);
  }

  @override
  bool shouldReclip(_SMClipper oldClipper) {
    return rating != oldClipper.rating;
  }
}

class SimpleComicTile extends StatelessWidget {
  const SimpleComicTile({
    super.key,
    required this.comic,
    this.onTap,
    this.withTitle = false,
    this.heroID,
  });

  final Comic comic;

  final void Function()? onTap;

  final bool withTitle;

  final int? heroID;

  @override
  Widget build(BuildContext context) {
    var image = findImageProvider(comic);

    Widget child = image == null
        ? const SizedBox()
        : AnimatedImage(
            image: image,
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
          );

    child = Container(
      width: 98,
      height: 136,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Theme.of(context).colorScheme.secondaryContainer,
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );

    if (heroID != null) {
      child = Hero(tag: "cover$heroID", child: child);
    }

    child = AnimatedTapRegion(
      borderRadius: 8,
      onTap:
          onTap ??
          () {
            context.to(
              () => ComicPage(
                id: comic.id,
                sourceKey: comic.sourceKey,
                cover: comic.cover,
                title: comic.title,
                heroID: heroID,
              ),
            );
          },
      child: child,
    );

    if (withTitle) {
      child = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          child,
          const SizedBox(height: 4),
          SizedBox(
            width: 92,
            child: Center(
              child: Text(
                comic.title.replaceAll('\n', ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      );
    }

    return child;
  }
}
