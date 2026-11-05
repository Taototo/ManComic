part of 'components.dart';

/// 长按封面的预览层（Peek）：浮出一张卡片显示封面、标题、标签与简介，
/// 不做跳转。松手后保留，点空白处关闭；点「详情」进入详情页，
/// 点「更多」打开原本的长按菜单。
class ComicPeek {
  ComicPeek._();

  static OverlayEntry? _entry;

  static bool get isShowing => _entry != null;

  static void show(
    BuildContext context,
    Comic comic, {
    VoidCallback? onMenu,
  }) {
    dismiss();
    // 提前把封面送进图像缓存：封面多半刚在列表里显示过、已在内存，
    // 万一被回收也能借这次调用提前解码，弹层首帧就不会闪占位色。
    // 这里必须和列表用同一个解码尺寸，否则缓存键不同、等于白预热。
    final image = _findImageProvider(comic);
    if (image != null) {
      precacheImage(
        ResizeImage.resizeIfNeeded(kCoverDecodeWidth, null, image),
        context,
      ).catchError((_) {});
    }
    final overlay = Overlay.of(context, rootOverlay: true);
    final entry = OverlayEntry(
      builder: (_) => _ComicPeekLayer(
        comic: comic,
        onMenu: onMenu,
        onDismiss: dismiss,
      ),
    );
    _entry = entry;
    // 注册给返回入口：系统返回时先关掉这层预览，而不是把被它盖住的
    // 列表页退掉。
    App.nonRouteOverlayDismisser = dismiss;
    overlay.insert(entry);
  }

  static void dismiss() {
    _entry?.remove();
    _entry = null;
    if (App.nonRouteOverlayDismisser == dismiss) {
      App.nonRouteOverlayDismisser = null;
    }
  }
}

class _ComicPeekLayer extends StatefulWidget {
  const _ComicPeekLayer({
    required this.comic,
    required this.onDismiss,
    this.onMenu,
  });

  final Comic comic;

  final VoidCallback onDismiss;

  final VoidCallback? onMenu;

  @override
  State<_ComicPeekLayer> createState() => _ComicPeekLayerState();
}

class _ComicPeekLayerState extends State<_ComicPeekLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 190),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _openDetails() {
    widget.onDismiss();
    App.mainNavigatorKey?.currentContext?.to(
      () => ComicPage(
        id: widget.comic.id,
        sourceKey: widget.comic.sourceKey,
        cover: widget.comic.cover,
        title: widget.comic.title,
      ),
    );
  }

  void _openMenu() {
    final menu = widget.onMenu;
    widget.onDismiss();
    menu?.call();
  }

  /// 以这本书的书名去所有漫画源里找同名作品。
  ///
  /// 长按恢复成「预览 + 菜单」之后，这里是换源搜索最短的路径：长按 —
  /// 面板上直接点「换源」，两次触达，且不用先勾选再翻菜单。
  void _searchOtherSources() {
    // 先取出导航器自己的 context：onDismiss 会把这个预览层从 Overlay 里
    // 摘掉，之后再用 widget 的 context 找 Navigator 会拿到已失活的元素。
    final navigatorContext = App.mainNavigatorKey?.currentContext;
    final comic = widget.comic;
    widget.onDismiss();
    showSourceMatchSheet(
      navigatorContext ?? App.rootContext,
      keyword: comic.title,
      currentSourceKey: comic.sourceKey,
      ownerSourceKey: comic.sourceKey,
      ownerId: comic.id,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final comic = widget.comic;
    final image = _findImageProvider(comic);
    final tags = <String>[];
    for (final tag in comic.tags ?? const <String>[]) {
      var text = tag.translateTagsToCN;
      if (text.contains(':')) {
        text = text.split(':').last;
      }
      if (text.trim().isEmpty) continue;
      tags.add(text);
      if (tags.length == 4) break;
    }
    final source = ComicSource.find(comic.sourceKey)?.name;

    return Material(
      type: MaterialType.transparency,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final t = Curves.easeOutCubic.transform(_controller.value);
          return Opacity(
            opacity: t,
            child: Transform.scale(
              scale: 0.94 + 0.06 * t,
              child: child,
            ),
          );
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onDismiss,
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.38),
            child: Center(
              child: GestureDetector(
                onTap: () {},
                child: Container(
                  width: math.min(MediaQuery.sizeOf(context).width * 0.84, 340),
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  decoration: BoxDecoration(
                    color: cs.surface,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.22),
                        blurRadius: 28,
                        offset: const Offset(0, 12),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        height: 200,
                        child: image == null
                            ? ColoredBox(color: cs.surfaceContainerHighest)
                            // 注意不要加 cacheWidth：列表里的封面就是用
                            // 同一个 provider 全尺寸解码进缓存的，加
                            // cacheWidth 会换成 ResizeImage 的新缓存键，
                            // 首帧要重新解码，闪一下灰底。
                            : AnimatedImage(
                                image: image,
                                cacheWidth: kCoverDecodeWidth,
                                fit: BoxFit.cover,
                                filterQuality: FilterQuality.medium,
                              ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              comic.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: ts.s16.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (source != null || comic.subtitle != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                [
                                  if (comic.subtitle != null &&
                                      comic.subtitle!.trim().isNotEmpty)
                                    comic.subtitle!,
                                  if (source != null) source,
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    ts.s10.copyWith(fontSize: 11).withColor(cs.onSurfaceVariant),
                              ),
                            ],
                            if (tags.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: tags
                                    .map(
                                      (t) => Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: cs.secondaryContainer
                                              .withValues(alpha: 0.7),
                                          borderRadius:
                                              BorderRadius.circular(20),
                                        ),
                                        child: Text(t, style: ts.s10),
                                      ),
                                    )
                                    .toList(),
                              ),
                            ],
                            if (comic.description.trim().isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(
                                comic.description,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: ts.s10.copyWith(fontSize: 11).withColor(
                                  cs.onSurfaceVariant.withValues(alpha: 0.85),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Button.normal(
                                onPressed: _openDetails,
                                child: Text("Details".tl),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Button.normal(
                                onPressed: _searchOtherSources,
                                child: Text("Sources".tl),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Button.normal(
                                onPressed: _openMenu,
                                child: Text("More".tl),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
