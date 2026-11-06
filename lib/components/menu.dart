part of "components.dart";

void showMenuX(BuildContext context, Offset location, List<MenuEntry> entries) {
  Navigator.of(
    context,
    rootNavigator: true,
  ).push(_MenuRoute(entries, location));
}

class _MenuRoute<T> extends PopupRoute<T> {
  final List<MenuEntry> entries;

  final Offset location;

  _MenuRoute(this.entries, this.location);

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => "menu";

  double get entryHeight => App.isMobile ? 42 : 36;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    var width = entries.first.icon == null ? 216.0 : 242.0;
    final size = MediaQuery.of(context).size;
    var left = location.dx;
    if (left < 10) {
      left = 10;
    }
    if (left + width > size.width - 10) {
      left = size.width - width - 10;
    }
    var top = location.dy;
    // 危险动作（删除等）之前插入一条淡分隔线，把它和常规动作隔开，
    // 顺带让长菜单有分组感。
    final dividerCount = _dividerCount();
    var height = 16 + entryHeight * entries.length + dividerCount * 11;
    if (top + height > size.height - 15) {
      top = size.height - height - 15;
    }
    if (top < 15) {
      top = 15;
    }
    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          child: LiquidGlass(
            borderRadius: BorderRadius.circular(16),
            // 菜单是压在内容上的浮层，读的是字：透太多会让背后的封面和菜单
            // 文字叠在一起，看起来像重影。0.88 还能看出是高光玻璃，但背后
            // 的内容只剩一层雾。
            opacity: 0.88,
            child: Material(
              type: MaterialType.transparency,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                width: width,
                padding: const EdgeInsets.symmetric(
                  vertical: 10,
                  horizontal: 6,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: _buildEntries(context),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  int _dividerCount() {
    var count = 0;
    for (var i = 1; i < entries.length; i++) {
      if (entries[i].isDanger && !entries[i - 1].isDanger) {
        count++;
      }
    }
    return count;
  }

  List<Widget> _buildEntries(BuildContext context) {
    final children = <Widget>[];
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry.isDanger && i > 0 && !entries[i - 1].isDanger) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Divider(
              height: 1,
              thickness: 0.5,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        );
      }
      children.add(buildEntry(entry, context));
    }
    return children;
  }

  Widget buildEntry(MenuEntry entry, BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          Navigator.of(context).pop();
          entry.onClick();
        },
        child: SizedBox(
          height: entryHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                if (entry.icon != null)
                  Icon(entry.icon, size: 18, color: entry.color),
                const SizedBox(width: 12),
                Text(entry.text, style: TextStyle(color: entry.color)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curve = animation.drive(
      Tween<double>(
        begin: 0,
        end: 1,
      ).chain(CurveTween(curve: Curves.easeOutCubic)),
    );
    return FadeTransition(
      opacity: curve,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.94, end: 1.0).animate(curve),
        alignment: Alignment.topLeft,
        child: child,
      ),
    );
  }
}

class MenuEntry {
  final String text;
  final IconData? icon;
  final Color? color;
  final void Function() onClick;

  /// 破坏性动作（删除之类）：在菜单里单独成组，与常规动作之间加分隔线
  final bool isDanger;

  MenuEntry({
    required this.text,
    this.icon,
    this.color,
    this.isDanger = false,
    required this.onClick,
  });
}
