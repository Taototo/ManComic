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
    void Function(Offset anchor)? onMenu,
  }) {
    dismiss();
    // 提前把封面送进图像缓存：封面多半刚在列表里显示过、已在内存，
    // 万一被回收也能借这次调用提前解码，弹层首帧就不会闪占位色。
    // 这里必须和列表用同一个解码尺寸，否则缓存键不同、等于白预热。
    final image = findImageProvider(comic);
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

  final void Function(Offset anchor)? onMenu;

  @override
  State<_ComicPeekLayer> createState() => _ComicPeekLayerState();
}

class _ComicPeekLayerState extends State<_ComicPeekLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 190),
  )..forward();

  /// 「更多」按钮的位置，用来把菜单锚在它下面
  final GlobalKey _moreKey = GlobalKey();

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
    // 菜单锚在「更多」按钮正下方：面板收起后菜单在原地展开，
    // 不会跳回被长按的缩略图那一侧。
    var anchor = MediaQuery.of(context).size.center(Offset.zero);
    final box = _moreKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      final topLeft = box.localToGlobal(Offset.zero);
      anchor = Offset(topLeft.dx, topLeft.dy + box.size.height + 4);
    }
    widget.onDismiss();
    menu?.call(anchor);
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
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final comic = widget.comic;
    final image = findImageProvider(comic);
    final tags = <String>[];
    for (final tag in comic.tags ?? const <String>[]) {
      var text = tag.translateTagsToCN;
      if (text.contains(':')) {
        text = text.split(':').last;
      }
      if (text.trim().isEmpty) continue;
      tags.add(text);
      if (tags.length == 3) break;
    }
    final source = ComicSource.find(comic.sourceKey)?.name;
    final meta = [
      if (comic.subtitle != null && comic.subtitle!.trim().isNotEmpty)
        comic.subtitle!,
      if (source != null) source,
    ].join(' · ');
    final description = comic.description.trim();

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
            // 遮罩要压得住背后的封面墙：太浅时列表里的亮色块会透过玻璃
            // 顶到标题上，文字被「洗」得看不清。
            color: Colors.black.withValues(alpha: 0.36),
            child: Center(
              child: GestureDetector(
                onTap: () {},
                child: Container(
                  width: math.min(MediaQuery.sizeOf(context).width * 0.86, 344),
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  child: LiquidGlass(
                    borderRadius: BorderRadius.circular(28),
                    // 不透明度从 0.72 提上来：玻璃再透，标题和简介就会和
                    // 背后糊成一片的封面抢对比度。浅色主题的 surface 本来
                    // 接近纯白，给到 0.9 就成了一块死白板，所以留一点缝让
                    // 底下的颜色透上来；深色主题不透明一点反而更像磨砂。
                    opacity: isDark ? 0.9 : 0.86,
                    blur: 38,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // 封面回到 3:4 竖版。之前是固定 200 高、铺满整个
                              // 卡片宽度，等于把竖版封面裁成 1.7:1 的横条，
                              // 画面主体经常被切掉。
                              SizedBox(
                                width: 104,
                                child: AspectRatio(
                                  aspectRatio: 3 / 4,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(16),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.26,
                                          ),
                                          blurRadius: 16,
                                          offset: const Offset(0, 6),
                                        ),
                                      ],
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(16),
                                      child: image == null
                                          ? ColoredBox(
                                              color:
                                                  cs.surfaceContainerHighest,
                                            )
                                          // 注意不要加 cacheWidth：列表里的封面就是用
                                          // 同一个 provider 全尺寸解码进缓存的，加
                                          // cacheWidth 会换成 ResizeImage 的新缓存键，
                                          // 首帧要重新解码，闪一下灰底。
                                          : AnimatedImage(
                                              image: image,
                                              cacheWidth: kCoverDecodeWidth,
                                              fit: BoxFit.cover,
                                              filterQuality:
                                                  FilterQuality.medium,
                                            ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
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
                                        height: 1.25,
                                      ),
                                    ),
                                    if (meta.isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        meta,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: ts.s10.copyWith(fontSize: 11.5)
                                            .withColor(
                                              cs.onSurface.withValues(
                                                alpha: 0.72,
                                              ),
                                            ),
                                      ),
                                    ],
                                    if (tags.isNotEmpty) ...[
                                      const SizedBox(height: 10),
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 6,
                                        children: tags
                                            .map((t) => _PeekTag(text: t))
                                            .toList(),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                          if (description.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Text(
                              description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              // 简介原先用 onSurfaceVariant + 11 号，压在
                              // 玻璃上是最先糊掉的一处：提亮到 0.8 的正文色
                              // 并放大一号。
                              style: ts.s10
                                  .copyWith(fontSize: 12, height: 1.45)
                                  .withColor(
                                    cs.onSurface.withValues(alpha: 0.8),
                                  ),
                            ),
                          ],
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              Expanded(
                                child: _PeekAction(
                                  label: "Details".tl,
                                  onPressed: _openDetails,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _PeekAction(
                                  label: "Sources".tl,
                                  onPressed: _searchOtherSources,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: KeyedSubtree(
                                  key: _moreKey,
                                  child: _PeekAction(
                                    label: "More".tl,
                                    onPressed: _openMenu,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
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

/// 玻璃卡片上的小标签：不用实色 secondaryContainer，
/// 半透明 + 细描边才和玻璃底融得进去。
class _PeekTag extends StatelessWidget {
  const _PeekTag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: cs.onSurface.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: cs.onSurface.withValues(alpha: 0.18),
          width: 0.6,
        ),
      ),
      child: Text(
        text,
        style: ts.s10.copyWith(
          fontSize: 10.5,
          color: cs.onSurface.withValues(alpha: 0.9),
        ),
      ),
    );
  }
}

/// 玻璃卡片上的动作按钮：透明底 + 细描边，替换原来实色的 Button.normal。
class _PeekAction extends StatelessWidget {
  const _PeekAction({required this.label, required this.onPressed});

  final String label;

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        splashColor: cs.onSurface.withValues(alpha: 0.06),
        highlightColor: cs.onSurface.withValues(alpha: 0.04),
        onTap: onPressed,
        child: Ink(
          height: 40,
          decoration: BoxDecoration(
            color: cs.onSurface.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: cs.onSurface.withValues(alpha: 0.16),
              width: 0.7,
            ),
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: cs.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
