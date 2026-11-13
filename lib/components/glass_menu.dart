part of 'components.dart';

/// 玻璃浮层菜单里的一行。
class GlassMenuEntry<T> {
  const GlassMenuEntry(this.label, this.value);

  final String label;

  final T value;
}

/// 磨砂玻璃浮层菜单。
///
/// 原来所有下拉都是 Material 的 `showMenu`：底色在两处被写死成一档
/// 接近纯白的灰（浅色），在主界面里就是**一块白板**——分类页那两个
/// 「全部 / 完结」下拉尤其明显，压在瀑布流上像没做完。
///
/// 这里不复用 `showMenu` 只改 color：`_PopupMenuRoute` 把底色画在自己的
/// Material 上，玻璃需要一块**独立表面**垫在所有 item 下面，只有自己起
/// 一个路由才做得到。参数与收藏分类抽屉同一档（blur 44、tint 0.5），
/// 菜单浮在封面上时背后是一团看不出轮廓的雾。
///
/// 返回被点中的那一行的值，点外部关闭返回 null。
Future<T?> showGlassMenu<T>({
  required BuildContext context,
  required List<GlassMenuEntry<T>> entries,
  required Rect anchor,
  double? minWidth,
  int? selectedIndex,
}) {
  if (entries.isEmpty) {
    return Future.value(null);
  }
  final screen = MediaQuery.sizeOf(context);
  final padding = MediaQuery.paddingOf(context);
  final isDark = Theme.of(context).brightness == Brightness.dark;
  final itemHeight = App.isMobile ? 46.0 : 40.0;
  const verticalPadding = 8.0;

  final width = math.min(
    math.max(anchor.width, minWidth ?? 160),
    screen.width - 16,
  );
  final wantedHeight = entries.length * itemHeight + verticalPadding * 2;
  // 选项可能有几十个（题材列表），超出屏幕就让列表自己滚。
  final height = math.min(wantedHeight, screen.height * 0.6);

  var left = anchor.left;
  if (left + width > screen.width - 8) {
    left = screen.width - width - 8;
  }
  left = math.max(left, 8.0);

  // 默认贴着按钮下沿展开；下方放不下就翻到上方，两边都不够时才贴边，
  // 绝不能像 showMenu 那样直接越过屏幕边缘。
  var top = anchor.bottom + 2;
  if (top + height > screen.height - padding.bottom - 8) {
    top = anchor.top - height - 2;
  }
  if (top < padding.top + 8) {
    top = padding.top + 8;
  }

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    // 菜单不该把背后的页面压暗——它压暗了，玻璃就只剩一块灰板。
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (dialogContext, animation, secondary) {
      return Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            width: width,
            child: LiquidGlassPanel(
              borderRadius: BorderRadius.circular(14),
              // minimal = 纯 BackdropFilter 磨砂（ClipPath + 模糊 + 底色），
              // 不带任何着色器采样。浮层菜单必须走这条：
              //
              // standard 那套自己要**抓一张背景纹理**再按面板矩形去采样。
              // 菜单是独立路由、面板又小又窄，抓到的纹理和面板矩形对不上，
              // 上半截采到的是弹窗（一块灰玻璃），下半截采到一片纯白——于是
              // 一块菜单上下两种颜色，中间一道硬接缝（1.4.67 的真机截图）。
              // BackdropFilter 直接吃「已经画好的东西」，没有坐标可错。
              //
              // 菜单弹出后不再移动，也不会每帧变尺寸，正是 minimal 适用的
              // 静态表面（appbar/bottomBar 同理）。
              quality: lg.GlassQuality.minimal,
              blur: 44,
              tintAlpha: isDark ? 0.62 : 0.5,
              child: DecoratedBox(
                // 玻璃自带的高光只在边缘一条，压在同色弹窗上几乎看不见；
                // 补一圈 hairline，面板才有「浮在上面」的边界。
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.12)
                        : Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.08),
                  ),
                ),
                child: Material(
                  type: MaterialType.transparency,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: height),
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(
                        vertical: verticalPadding,
                      ),
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final selected = index == selectedIndex;
                        return InkWell(
                          onTap: () =>
                              Navigator.of(dialogContext).pop(entry.value),
                          child: SizedBox(
                            height: itemHeight,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      entry.label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: selected
                                          ? TextStyle(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                              fontWeight: FontWeight.w500,
                                            )
                                          : null,
                                    ),
                                  ),
                                  if (selected)
                                    Icon(
                                      Icons.check,
                                      size: 18,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.primary,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
    transitionBuilder: (context, animation, secondary, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      );
    },
  );
}
