part of 'components.dart';

class PaneItemEntry {
  String label;

  IconData icon;

  IconData activeIcon;

  PaneItemEntry({
    required this.label,
    required this.icon,
    required this.activeIcon,
  });
}

class PaneActionEntry {
  String label;

  IconData icon;

  VoidCallback onTap;

  PaneActionEntry({
    required this.label,
    required this.icon,
    required this.onTap,
  });
}

/// 判断这次返回是不是「再按一次」的那一次。
///
/// 拆成纯函数是因为它直接决定 App 退不退出，写错方向很难察觉：
/// 太宽松会在提示消失后仍然一滑就退，太严格则永远退不出去。
bool isSecondExitAttempt(
  DateTime? lastAttempt,
  DateTime now,
  Duration window,
) {
  if (lastAttempt == null) return false;
  final delta = now.difference(lastAttempt);
  // 系统时间被调整时会算出负数，按「不退出」处理更安全。
  if (delta.isNegative) return false;
  return delta <= window;
}

class NaviPane extends StatefulWidget {
  const NaviPane({
    required this.paneItems,
    required this.paneActions,
    required this.pageBuilder,
    this.initialPage = 0,
    this.onPageChanged,
    required this.observer,
    required this.navigatorKey,
    super.key,
  });

  final List<PaneItemEntry> paneItems;

  final List<PaneActionEntry> paneActions;

  final Widget Function(int page) pageBuilder;

  final void Function(int index)? onPageChanged;

  final int initialPage;

  final NaviObserver observer;

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<NaviPane> createState() => NaviPaneState();

  static NaviPaneState of(BuildContext context) {
    return context.findAncestorStateOfType<NaviPaneState>()!;
  }
}

typedef NaviItemTapListener = void Function(int);

class NaviPaneState extends State<NaviPane>
    with SingleTickerProviderStateMixin {
  late int _currentPage = widget.initialPage;

  int get currentPage => _currentPage;

  set currentPage(int value) {
    if (value == _currentPage) return;
    _currentPage = value;
    widget.onPageChanged?.call(value);
  }

  void Function()? mainViewUpdateHandler;

  late AnimationController controller;

  final _naviItemTapListeners = <NaviItemTapListener>[];

  void addNaviItemTapListener(NaviItemTapListener listener) {
    _naviItemTapListeners.add(listener);
  }

  void removeNaviItemTapListener(NaviItemTapListener listener) {
    _naviItemTapListeners.remove(listener);
  }

  static const _kBottomBarHeight = 64.0;

  static const _kBottomBarMargin = 10.0;

  static const _kFoldedSideBarWidth = 72.0;

  static const _kSideBarWidth = 224.0;

  static const _kTopBarHeight = 48.0;

  double get bottomBarHeight =>
      _kBottomBarHeight + _kBottomBarMargin + MediaQuery.of(context).padding.bottom;

  void onNavigatorStateChange() {
    onRebuild(context);
  }

  void updatePage(int index) {
    for (var listener in _naviItemTapListeners) {
      listener(index);
    }
    if (widget.observer.routes.length > 1) {
      widget.navigatorKey.currentState!.popUntil((route) => route.isFirst);
    }
    if (currentPage == index) {
      return;
    }
    setState(() {
      currentPage = index;
    });
    mainViewUpdateHandler?.call();
  }

  @override
  void initState() {
    controller = AnimationController(
      duration: const Duration(milliseconds: 250),
      lowerBound: 0,
      upperBound: 3,
      vsync: this,
    );
    widget.observer.addListener(onNavigatorStateChange);
    super.initState();
  }

  @override
  void dispose() {
    controller.dispose();
    widget.observer.removeListener(onNavigatorStateChange);
    super.dispose();
  }

  /// 上一次弹出「再按一次退出」的时间戳。
  ///
  /// 侧滑返回在根页面上会直接结束进程，手滑一下就关掉整个 App 太重了，
  /// 所以第一次返回只提示、不退出；提示还亮着的时候再返回一次才真的退出。
  ///
  /// 这里记时间戳而不是「提示是否在显示」：提示由 Overlay 自己管生命周期
  /// （淡出还要 160ms），手势判断只需要一个干净的时间窗口。
  DateTime? _lastExitAttempt;

  static const Duration _kExitConfirmWindow = Duration(seconds: 2);

  void _confirmExit() {
    // 只有 Android 有系统返回手势和返回键，其它平台不会走到这里。
    if (!App.isAndroid) {
      return;
    }
    final now = DateTime.now();
    if (isSecondExitAttempt(_lastExitAttempt, now, _kExitConfirmWindow)) {
      _lastExitAttempt = null;
      SystemNavigator.pop();
      return;
    }
    _lastExitAttempt = now;
    final rootContext = App.rootContext;
    if (!rootContext.mounted) {
      return;
    }
    // 小红书那种：屏幕中间一行字，不铺遮罩、不要按钮。
    showCenterHint(
      rootContext,
      "Press back again to exit".tl,
      duration: _kExitConfirmWindow,
    );
  }

  double targetFormContext(BuildContext context) {
    var width = MediaQuery.of(context).size.width;
    double target = 0;
    if (width > changePoint) {
      target = 2;
    }
    if (width > changePoint2) {
      target = 3;
    }
    return target;
  }

  double? animationTarget;

  void onRebuild(BuildContext context) {
    double target = targetFormContext(context);
    if (controller.value != target || animationTarget != target) {
      if (controller.isAnimating) {
        if (animationTarget == target) {
          return;
        } else {
          controller.stop();
        }
      }
      controller.animateTo(target);
      animationTarget = target;
    }
  }

  @override
  Widget build(BuildContext context) {
    onRebuild(context);
    final mq = MediaQuery.of(context);
    final sideInsets = (App.isMobile && mq.orientation == Orientation.landscape)
        ? EdgeInsets.only(
            left: math.max(mq.viewPadding.left, mq.systemGestureInsets.left),
            right: math.max(mq.viewPadding.right, mq.systemGestureInsets.right),
          )
        : EdgeInsets.zero;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        final value = controller.value;
        Widget content = Stack(
          children: [
            Positioned(
              left: _kFoldedSideBarWidth * ((value - 2.0).clamp(-1.0, 0.0)),
              top: 0,
              bottom: 0,
              child: buildLeft(),
            ),
            Positioned.fill(
              left:
                  _kFoldedSideBarWidth * ((value - 1).clamp(0, 1)) +
                  (_kSideBarWidth - _kFoldedSideBarWidth) *
                      ((value - 2).clamp(0, 1)),
              child: buildMainView(),
            ),
          ],
        );
        if (sideInsets != EdgeInsets.zero) {
          content = Padding(
            padding: sideInsets,
            child: content,
          );
        }
        return content;
      },
    );
  }

  Widget buildMainView() {
    return HeroControllerScope(
      controller: MaterialApp.createMaterialHeroController(),
      // 系统返回（返回键、Android 预测性返回、手势返回）统一交给
      // App.handleBack 处理：先关根导航器上的弹层，再退主导航器里的页面，
      // 都没有才退出应用，保证一次返回只回退一层。
      //
      // 这里必须固定 canPop: false。之前用 NotificationListener 依据子
      // 导航器状态动态设置 canPop，但这个标志只在收到通知时更新，容易
      // 与真实栈状态错位：错成 true 会直接把整个 App 退出，错成 false
      // 会让返回键失灵。
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) async {
          if (didPop) {
            return;
          }
          final handled = await App.handleBack();
          if (!handled && mounted) {
            _confirmExit();
          }
        },
        child: Navigator(
          observers: [widget.observer],
          key: widget.navigatorKey,
          onGenerateRoute: (settings) => AppPageRoute(
            preventRebuild: false,
            builder: (context) {
              return _NaviMainView(state: this);
            },
          ),
        ),
      ),
    );
  }

  Widget buildMainViewContent() {
    return widget.pageBuilder(currentPage);
  }

  Widget buildTop() {
    return Material(
      child: Container(
        padding: const EdgeInsets.only(left: 16, right: 8),
        height: _kTopBarHeight,
        width: double.infinity,
        child: Row(
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.4),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: Text(
                widget.paneItems[currentPage].label,
                key: ValueKey(currentPage),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const Spacer(),
            for (var action in widget.paneActions)
              _GlassActionButton(
                icon: action.icon,
                label: action.label,
                onTap: action.onTap,
              ),
          ],
        ),
      ),
    );
  }

  Widget buildBottom() {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 0, 14, bottomInset + _kBottomBarMargin),
      child: LiquidGlass(
        borderRadius: BorderRadius.circular(_kBottomBarHeight / 2),
        child: SizedBox(
          height: _kBottomBarHeight,
          child: _BottomNavBar(
            entries: widget.paneItems,
            currentIndex: currentPage,
            onTap: (i) => updatePage(i),
          ),
        ),
      ),
    );
  }

  Widget buildLeft() {
    final value = controller.value;
    const paddingHorizontal = 12.0;
    return Material(
      child: Container(
        width:
            _kFoldedSideBarWidth +
            (_kSideBarWidth - _kFoldedSideBarWidth) * ((value - 2).clamp(0, 1)),
        height: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: paddingHorizontal),
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 1.0,
            ),
          ),
        ),
        child: Column(
          children: [
            const SizedBox(height: 16),
            SizedBox(height: MediaQuery.of(context).padding.top),
            ...List<Widget>.generate(
              widget.paneItems.length,
              (index) => _SideNaviWidget(
                enabled: currentPage == index,
                entry: widget.paneItems[index],
                showTitle: value == 3,
                onTap: () {
                  updatePage(index);
                },
                key: ValueKey(index),
              ),
            ),
            const Spacer(),
            ...List<Widget>.generate(
              widget.paneActions.length,
              (index) => _PaneActionWidget(
                entry: widget.paneActions[index],
                showTitle: value == 3,
                key: ValueKey(index + widget.paneItems.length),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _SideNaviWidget extends StatelessWidget {
  const _SideNaviWidget({
    required this.enabled,
    required this.entry,
    required this.onTap,
    required this.showTitle,
    super.key,
  });

  final bool enabled;

  final PaneItemEntry entry;

  final VoidCallback onTap;

  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final icon = Icon(enabled ? entry.activeIcon : entry.icon);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        height: 38,
        decoration: BoxDecoration(
          color: enabled ? colorScheme.primaryContainer : null,
          borderRadius: BorderRadius.circular(12),
        ),
        child: showTitle
            ? Row(
                children: [icon, const SizedBox(width: 12), Text(entry.label)],
              )
            : Align(alignment: Alignment.centerLeft, child: icon),
      ),
    ).paddingVertical(4);
  }
}

class _PaneActionWidget extends StatelessWidget {
  const _PaneActionWidget({
    required this.entry,
    required this.showTitle,
    super.key,
  });

  final PaneActionEntry entry;

  final bool showTitle;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(entry.icon);
    return InkWell(
      onTap: entry.onTap,
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        height: 38,
        child: showTitle
            ? Row(
                children: [icon, const SizedBox(width: 12), Text(entry.label)],
              )
            : Align(alignment: Alignment.centerLeft, child: icon),
      ),
    ).paddingVertical(4);
  }
}

/// 液态玻璃底部导航栏。
///
/// 由「玻璃底板 + 会随切换滑动的高光药丸 + 图标文字」组成，
/// 药丸在移动时带一点横向拉伸，滑动结束回弹，模仿液体被推着走的感觉。
class _BottomNavBar extends StatefulWidget {
  const _BottomNavBar({
    required this.entries,
    required this.currentIndex,
    required this.onTap,
  });

  final List<PaneItemEntry> entries;

  final int currentIndex;

  final void Function(int index) onTap;

  @override
  State<_BottomNavBar> createState() => _BottomNavBarState();
}

class _BottomNavBarState extends State<_BottomNavBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _squash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 460),
    value: 1,
  );

  @override
  void didUpdateWidget(covariant _BottomNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      _squash.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _squash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final count = widget.entries.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = constraints.maxWidth / count;
        final blobWidth = (itemWidth - 14).clamp(52.0, 92.0);
        final left = itemWidth * widget.currentIndex +
            (itemWidth - blobWidth) / 2;
        return Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeOutCubic,
              left: left,
              width: blobWidth,
              top: 7,
              bottom: 7,
              child: AnimatedBuilder(
                animation: _squash,
                builder: (context, child) {
                  // 0 -> 1 期间横向拉伸再回弹
                  final t = _squash.value;
                  final stretch = 1 + 0.12 * math.sin(t * math.pi);
                  return Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.diagonal3Values(stretch, 1.0, 1.0),
                    child: child,
                  );
                },
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(blobWidth / 2),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        colors.primary.withValues(alpha: 0.22),
                        colors.primary.withValues(alpha: 0.10),
                      ],
                    ),
                    border: Border.all(
                      color: colors.primary.withValues(alpha: 0.30),
                      width: 0.9,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: colors.primary.withValues(alpha: 0.20),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Row(
              children: List<Widget>.generate(count, (index) {
                return Expanded(
                  child: _BottomNavItem(
                    entry: widget.entries[index],
                    active: widget.currentIndex == index,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      widget.onTap(index);
                    },
                  ),
                );
              }),
            ),
          ],
        );
      },
    );
  }
}

/// 顶栏图标按钮：按下时轻微缩放 + 液态高光晕开，和底栏的动效语言保持一致。
class _GlassActionButton extends StatefulWidget {
  const _GlassActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;

  final String label;

  final VoidCallback onTap;

  @override
  State<_GlassActionButton> createState() => _GlassActionButtonState();
}

class _GlassActionButtonState extends State<_GlassActionButton> {
  bool _pressed = false;

  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final highlight = _pressed
        ? 0.14
        : _hovering
            ? 0.07
            : 0.0;
    return Tooltip(
      message: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedScale(
            scale: _pressed ? 0.88 : 1.0,
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.onSurface.withValues(alpha: highlight),
                  ),
                  child: Icon(
                    widget.icon,
                    size: 22,
                    color: colors.onSurface.withValues(alpha: 0.86),
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

class _BottomNavItem extends StatefulWidget {
  const _BottomNavItem({
    required this.entry,
    required this.active,
    required this.onTap,
  });

  final PaneItemEntry entry;

  final bool active;

  final VoidCallback onTap;

  @override
  State<_BottomNavItem> createState() => _BottomNavItemState();
}

class _BottomNavItemState extends State<_BottomNavItem> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final active = widget.active;
    final color = active
        ? colors.primary
        : colors.onSurfaceVariant.withValues(alpha: 0.9);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.94 : 1.0,
          duration: const Duration(milliseconds: 120),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 1, end: active ? 1.08 : 1.0),
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutBack,
                builder: (context, scale, child) {
                  return Transform.scale(scale: scale, child: child);
                },
                child: Icon(
                  active ? widget.entry.activeIcon : widget.entry.icon,
                  size: 23,
                  color: color,
                ),
              ),
              const SizedBox(height: 3),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 220),
                style: TextStyle(
                  fontSize: 10,
                  height: 1.1,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: color,
                  letterSpacing: 0.1,
                ),
                child: Text(
                  widget.entry.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class NaviObserver extends NavigatorObserver implements Listenable {
  var routes = Queue<Route>();

  int get pageCount {
    int count = 0;
    for (var route in routes) {
      if (route is AppPageRoute) {
        count++;
      }
    }
    return count;
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    // 必须按路由对象移除。之前用 removeLast()，一旦有 route 被 popUntil
    // 或由根导航器直接关掉，队尾就不一定是被关掉的那一个，队列会和真实
    // 栈错位，导致 updatePage 里的「是否需要先退栈」判断失效。
    routes.remove(route);
    notifyListeners();
  }

  @override
  void didPush(Route route, Route? previousRoute) {
    routes.addLast(route);
    notifyListeners();
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    routes.remove(route);
    notifyListeners();
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    routes.remove(oldRoute);
    if (newRoute != null) {
      routes.add(newRoute);
    }
    notifyListeners();
  }

  List<VoidCallback> listeners = [];

  @override
  void addListener(VoidCallback listener) {
    listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    listeners.remove(listener);
  }

  void notifyListeners() {
    for (var listener in listeners) {
      listener();
    }
  }
}

class _NaviMainView extends StatefulWidget {
  const _NaviMainView({required this.state});

  final NaviPaneState state;

  @override
  State<_NaviMainView> createState() => _NaviMainViewState();
}

class _NaviMainViewState extends State<_NaviMainView> {
  NaviPaneState get state => widget.state;

  /// 上一次显示的 Tab 序号与切换方向，用于让切页有方向的位移感。
  late int _lastIndex = state.currentPage;

  int _direction = 1;

  void _syncDirection() {
    final index = state.currentPage;
    if (index == _lastIndex) return;
    _direction = index > _lastIndex ? 1 : -1;
    _lastIndex = index;
  }

  @override
  void initState() {
    state.mainViewUpdateHandler = () {
      _syncDirection();
      setState(() {});
    };
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final showBar = state.controller.value < 2;
    final mq = MediaQuery.of(context);
    // 顶栏已经处理了状态栏高度，页面内容要拿掉 top padding；
    // 底栏漂浮在内容之上，这里把高度补给页面，避免内容被挡住。
    final base = showBar ? mq.removePadding(removeTop: true) : mq;
    final pageData = base.copyWith(
      padding: base.padding.copyWith(
        bottom: mq.padding.bottom + (showBar ? state.bottomBarHeight : 0),
      ),
    );
    final content = Column(
      children: [
        if (showBar) state.buildTop().paddingTop(mq.padding.top),
        Expanded(
          child: MediaQuery(
            data: pageData,
            // key 挂在页签序号上：切页时旧页面在这里**立刻**被替换、销毁，
            // 不再像 AnimatedSwitcher 那样让新旧两页共存 260ms。
            child: _TabTransition(
              key: ValueKey(state.currentPage),
              direction: _direction,
              child: state.buildMainViewContent(),
            ),
          ),
        ),
      ],
    );
    if (!showBar) {
      return content;
    }
    return Stack(
      children: [
        Positioned.fill(child: content),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: state.buildBottom(),
        ),
      ],
    );
  }
}

/// 页签切换的入场包装。
///
/// 核心约束：**同一时刻只允许一页存在于树上**。
///
/// 之前这里用 AnimatedSwitcher 做交叉过渡，新旧两页会共存 260ms。而这些页
/// 面的根背景是透明的（只有卡片自己带底色），两页一叠就互相透出——看起来
/// 像「另一页的卡片盖住了当前页的内容」，边框还会错开十几像素。
///
/// 现在 key 跟着页签序号走：切页的那一帧旧页整棵子树就被替换、dispose，
/// 只剩新页做一次「淡入 + 轻微位移」。底下始终垫着 surface 底色，所以淡入
/// 过程中不会闪黑、也不会透出任何别的东西。
class _TabTransition extends StatefulWidget {
  const _TabTransition({
    super.key,
    required this.direction,
    required this.child,
  });

  /// 1 = 往右切（新页从右侧来），-1 = 往左切
  final int direction;

  final Widget child;

  @override
  State<_TabTransition> createState() => _TabTransitionState();
}

class _TabTransitionState extends State<_TabTransition>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..forward();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final t = Curves.easeOutCubic.transform(_controller.value);
          return Opacity(
            opacity: 0.65 + 0.35 * t,
            child: Transform.translate(
              offset: Offset(widget.direction * 16 * (1 - t), 0),
              child: child,
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}
