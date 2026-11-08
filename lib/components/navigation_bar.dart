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

  VoidCallback? onTap;

  /// 需要「贴着按钮弹菜单」的操作（收藏页的「更多」）。
  ///
  /// [onTap] 拿不到按钮自己的位置，而 `showMenuX` 要的正是那个矩形：菜单
  /// 必须挂在被点的那个图标下面。回调把按钮在屏幕上的矩形交出去，页面再
  /// 自己决定弹什么。
  void Function(BuildContext context, Rect anchor)? onTapWithAnchor;

  /// 图标颜色。`null` 表示用默认的前景色。
  ///
  /// 有些图标本身带状态（收藏页的「排序 / 筛选」被改过就是高亮的），
  /// 光换个图标表达不出来。
  Color? color;

  PaneActionEntry({
    required this.label,
    required this.icon,
    this.onTap,
    this.onTapWithAnchor,
    this.color,
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
    this.titleBuilder,
    this.initialPage = 0,
    this.onPageChanged,
    required this.observer,
    required this.navigatorKey,
    this.headerBuilder,
    this.headerHeight,
    super.key,
  });

  final List<PaneItemEntry> paneItems;

  final List<PaneActionEntry> paneActions;

  final Widget Function(int page) pageBuilder;

  /// 替换标题位的内容，返回 null 时回落到 [paneItems] 里的文字标题。
  ///
  /// 推荐页要把「推荐 / 分类」分段控件放在标题的位置。分段控件的状态住在
  /// 页面里，顶栏和页面又是两棵子树，所以只能由上层把「造控件」这件事
  /// 交给顶栏，而不是反过来让页面往顶栏里塞 widget。
  final Widget? Function(int index, BuildContext context)? titleBuilder;

  /// 标题行**下方**再长一行内容，和标题共用同一块玻璃。
  ///
  /// 推荐页的「源页签」原来是自己压在页面顶部的一层独立磨砂条：和顶栏
  /// 那块玻璃挨着，参数却不一样，中间还有一道边缘高光，看起来就是两条
  /// 各管各的带子。现在把它交给顶栏，两行一起铺在同一块玻璃上。
  ///
  /// 返回 null 表示该页没有附加行。
  final Widget? Function(int index, BuildContext context)? headerBuilder;

  /// 附加行的高度（只在 [headerBuilder] 返回了东西时生效）。
  ///
  /// 高度必须由上层直接给出而不是测量：页面内容的顶部留白要靠它算，
  /// 量出来的话第一帧就先按 0 排一次版。
  final double Function(int index)? headerHeight;

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

  /// 当前是否显示顶栏。
  ///
  /// 宽屏（侧栏模式）没有顶栏，页面拿到的 [MediaQuery.padding.top] 就是真实
  /// 状态栏高度，页面自己那一行标题/控件得自己画。推荐页的分段控件就靠这个
  /// 决定是长在顶栏里，还是退回页面顶部。
  bool get hasTopBar => controller.value < 2;

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

  /// 顶栏下方附加行（推荐页的源页签）的高度；没有附加行时是 0。
  double get headerExtent {
    if (widget.headerBuilder == null) {
      return 0;
    }
    return widget.headerHeight?.call(currentPage) ?? 0;
  }

  Widget buildTop() {
    // 顶栏通栏贴着状态栏，用直角玻璃。它会盖在页面内容之上，
    // 列表滚上来时从玻璃后面经过。
    //
    // 边缘高光要压到很低：顶栏只有下沿露在屏幕里，那圈高光正好沿着
    // 「玻璃和内容的交界」画一条亮线，看起来就是给顶栏描了个白边。
    // 折射（thickness/refractiveIndex）不跟着变，厚玻璃的弯折还在。
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return LiquidGlassBar(
      lightIntensity: isDark ? 0.16 : 0.45,
      fresnelStrength: 0.35,
      // 底色和底栏同一档。
      //
      // 默认那档（opacity×0.35 ≈ 0.2）是给「玻璃本身才是主体」的卡片配的：
      // 顶栏下面压的是漫画封面，一旦碰上浅色封面，18pt 的标题字就直接糊进
      // 封面里了。底栏因为压在任意内容上早就调到了这条线，顶栏没理由比它
      // 更清透——那正是「同一种玻璃，两种观感」的来源。
      tintAlpha: LiquidGlassEngine.barTintAlpha,
      // 这里必须用 Builder 而不是直接算：附加行（源页签）的构造器是页面在
      // 自己的 initState 里注册的，而 buildTop 在父级 build 期间就被调用了，
      // 那时候页面子树还没建起来。Builder 的 build 排在 Stack 里更靠前的
      // 页面之后，拿到的才是注册好的构造器。
      child: Builder(builder: _buildTopContent),
    );
  }

  Widget _buildTopContent(BuildContext context) {
    // 玻璃要连状态栏一起盖住。只盖 48 的话，页面内容滚上来会从状态栏
    // 那条缝里露出来，看起来像顶栏被切成两半。
    final topInset = MediaQuery.of(context).padding.top;
    final header = widget.headerBuilder?.call(currentPage, context);
    final extra = header == null ? 0.0 : headerExtent;
    return Container(
      padding: EdgeInsets.only(top: topInset),
      height: _kTopBarHeight + topInset + extra,
      width: double.infinity,
      child: Column(
        children: [
          SizedBox(
            height: _kTopBarHeight,
            child: Padding(
              padding: const EdgeInsets.only(left: 16, right: 8),
              child: Row(
                children: [
                  // 标题位要能被压缩：收藏页把「排序 / 多选 / 搜索 / 更多」
                  // 一起提到了这一行，图标一多，原来那种「标题按自身宽度铺
                  // 开 + Spacer」的排法会直接把 Row 挤爆（图标并不会缩）。
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: AnimatedSwitcher(
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
                        child: KeyedSubtree(
                          key: ValueKey(currentPage),
                          child:
                              widget.titleBuilder?.call(currentPage, context) ??
                                  Text(
                                    widget.paneItems[currentPage].label,
                                    style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                        ),
                      ),
                    ),
                  ),
                  for (var action in widget.paneActions)
                    _GlassActionButton(
                      icon: action.icon,
                      label: action.label,
                      color: action.color,
                      onTap: action.onTap,
                      onTapWithAnchor: action.onTapWithAnchor,
                    ),
                ],
              ),
            ),
          ),
          if (header != null && extra > 0)
            SizedBox(
              height: extra,
              width: double.infinity,
              child: header,
            ),
        ],
      ),
    );
  }

  Widget buildBottom() {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final outer =
        EdgeInsets.fromLTRB(14, 0, 14, bottomInset + _kBottomBarMargin);
    // 液态开启时用包里完整的底栏：玻璃胶囊 + 会折射下方图标的果冻滑块。
    // 切换时滑块按弹簧曲线滑过去，途中横向拉伸、到站回弹——这正是
    // iOS 26 标签栏的那个动效，自绘的渐变色药丸做不出折射。
    if (LiquidGlassEngine.enabled) {
      final colors = context.colorScheme;
      return Padding(
        padding: outer,
        child: lg.GlassTabBar.bottom(
          tabs: [
            for (var e in widget.paneItems)
              lg.GlassTab(
                icon: Icon(e.icon),
                activeIcon: Icon(e.activeIcon),
                label: e.label,
              ),
          ],
          selectedIndex: currentPage,
          onTabSelected: (i) {
            // 系统那一下（CLOCK_TICK）在国内 ROM 上偏重，换成自己发的定振幅
            // 短震；见 utils/haptics.dart。
            Haptics.tap();
            updatePage(i);
          },
          barHeight: _kBottomBarHeight,
          // 外层 Padding 已负责与屏幕边缘的距离，内部别再留一圈。
          horizontalPadding: 0,
          verticalPadding: 0,
          // premium：底栏的「液态」感全在这一档上。
          //
          // standard 走的是 2D 磨砂着色器（LightweightLiquidGlass），没有
          // 厚度、没有折射、没有边缘高光 —— 看起来就是一块半透明的白胶片，
          // 和顶栏那块玻璃完全不是一回事。之前为了压掉切页闪黑把它降到
          // standard，代价就是把液态效果也一起丢了。
          //
          // 闪黑的真凶不是 premium 本身，是外面那层 GlassBackdropGroup：
          // 它让顶栏和底栏共用一次背景读取，页签切换时页面整棵子树被替换，
          // 这次「共享读取」还停在旧的画面/空画面上，玻璃就照着它画成了
          // 黑底；路由切换（进一遍设置再退回来）会把 group 重建一次，所以
          // 那样「碰一下」就恢复正常。现在两条栏各自读各自的背景，不再共享。
          quality: lg.GlassQuality.premium,
          // 关掉「形状融合」那一趟 pass（默认开）。
          //
          // premium 档在 Impeller 上会把整个底栏包进 LiquidGlassBlendGroup：
          // 它要多渲染一趟，把底栏和滑块两个形状的轮廓融成一片。切页那一帧
          // 页面整棵子树被换掉，这趟融合渲染拿到的几何/背景是新的、还没画完的，
          // 结果就是整块底栏先画成纯黑，而且会一直挂着，直到别的重建把它顶掉
          // （所以「进一遍设置再退回来」能恢复）。
          //
          // 证据：1.4.38 用 standard 时没有这一趟（standard 不进 full renderer），
          // 也就没黑；回到 premium 就带回来了。滑块本身的折射不依赖融合，关掉
          // 只是少了「药丸和底栏融成一张皮」那点过渡，省一趟全屏 pass。
          //
          // 补丁见 third_party/liquid_glass_widgets/PATCHES.md：
          // blendAmount 为 0 时不再包这层 group。
          enableBlend: false,
          // 底栏压在任意内容上（漫画封面经常是深色大块），玻璃底色必须
          // 比浮层默认值实一截，图标和文字才不会陷进背景里。
          settings: LiquidGlassEngine.settings(
            context,
            tintAlpha: LiquidGlassEngine.barTintAlpha,
          ),
          // 弹簧放慢：默认 snappy(350ms) 快到看不出滑行，果冻感没展开
          // 就到站了。bouncy(550ms) 才有 iOS 26 那种滑过去再弹一下的节奏。
          springDescription: LiquidGlassEngine.indicatorSpring,
          // 显式给色：不依赖着色器自动判亮，深色封面上也保证可读。
          selectedIconColor: colors.primary,
          selectedLabelColor: colors.primary,
          unselectedIconColor: colors.onSurface.toOpacity(0.78),
          unselectedLabelColor: colors.onSurface.toOpacity(0.78),
          // 选中项放大：包里默认是 iOS 27 实测的 1.25，配合 27.5 的图标那是
          // 一次很明显的「跳」。收窄到 1.12——还看得出哪个被选中，但不再抢
          // 眼球的注意力。滑块滑过去时邻格也会按距离渐变放大（区间写死在
          // 包的 _tabProximityScale 里），同一倍率一起收敛。
          magnification: 1.12,
          // 滑块自身的挤压拉伸（squash & stretch）收敛一档。
          //
          // 包里的默认值 0.4 是按「按压时药丸鼓一下」调的，实际观感是
          // 点下去的瞬间按钮先晃了一下才切过去。0.2 只留滑动途中那点形变，
          // 手感是「滑过去」而不是「弹一下」。
          indicatorPinchStrength: 0.2,
          // 按压缩放（默认 1.04 鼓一下再弹回）关掉，只留触摸光晕：
          // glowOnly 让玻璃在手指位置亮一下，本体不鼓，位置关系更稳定。
          interactionBehavior: lg.GlassInteractionBehavior.glowOnly,
        ),
      );
    }
    // 回退：自研玻璃 + 自绘药丸，观感与接入第三方包之前一致。
    return Padding(
      padding: outer,
      child: LiquidGlassBar(
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
                      Haptics.tap();
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
    this.color,
    this.onTap,
    this.onTapWithAnchor,
  });

  final IconData icon;

  final String label;

  final Color? color;

  final VoidCallback? onTap;

  /// 需要按位置弹菜单时用这个，见 [PaneActionEntry.onTapWithAnchor]。
  final void Function(BuildContext context, Rect anchor)? onTapWithAnchor;

  @override
  State<_GlassActionButton> createState() => _GlassActionButtonState();
}

class _GlassActionButtonState extends State<_GlassActionButton> {
  bool _pressed = false;

  bool _hovering = false;

  void _handleTap() {
    final anchor = widget.onTapWithAnchor;
    if (anchor == null) {
      widget.onTap?.call();
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      return;
    }
    anchor(context, box.localToGlobal(Offset.zero) & box.size);
  }

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
          onTap: _handleTap,
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
                    color: widget.color ??
                        colors.onSurface.withValues(alpha: 0.86),
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
    // 顶栏从「占位的一行」改成「盖在内容上面的一层」：留在 Column 里的话，
    // 它背后永远只有 Scaffold 底色，玻璃模糊完还是纯色，等于没做。
    // 页面顶部让出顶栏高度，初始状态和原来一模一样，只有滚动时内容
    // 才会从玻璃后面穿过去。
    final base = showBar ? mq.removePadding(removeTop: true) : mq;
    final pageData = base.copyWith(
      padding: base.padding.copyWith(
        // 让出的高度必须和顶栏实际占用的一致（状态栏 + 48）。只写 48 的话，
        // 页面内容会整体上移一个状态栏的高度，被顶栏压住一条。
        top: showBar
            ? NaviPaneState._kTopBarHeight + mq.padding.top
            : base.padding.top,
        // 底栏同样漂浮在内容之上，这部分高度也要补给页面，
        // 否则列表最后一行会被底栏压住。
        bottom: mq.padding.bottom + (showBar ? state.bottomBarHeight : 0),
      ),
    );
    final page = MediaQuery(
      data: pageData,
      // key 挂在页签序号上：切页时旧页面在这里**立刻**被替换、销毁，
      // 不再像 AnimatedSwitcher 那样让新旧两页共存 260ms。
      child: _TabTransition(
        key: ValueKey(state.currentPage),
        direction: _direction,
        child: state.buildMainViewContent(),
      ),
    );
    if (!showBar) {
      // 宽屏走侧栏模式，没有外层顶栏，页面拿到的就是真实状态栏高度。
      return page;
    }
    // 顶栏和底栏各自读自己的背景，**不共享** GlassBackdropGroup。
    //
    // 共享那次读取看起来省了一次全屏拷贝，但它是在「组里第一块玻璃画的时候」
    // 取一次快照，之后所有成员都按这张快照算折射。切页那一帧页面整棵子树被
    // 换掉，快照还是旧的/空的，两条栏就跟着画成黑底——而且会一直黑着，直到
    // 路由切换把 group 重建（所以「进一遍设置再退回来」就好了）。
    // 代价是每帧多一次背景读取，换的是切页再也不会闪黑。
    return Stack(
      children: [
        // 页面不额外包 RepaintBoundary。
        //
        // 1.4.38 加它是为了「先落层，玻璃再读」，但闪黑并没有因此消失；
        // 反过来它让页面成为独立的合成层，切页那一帧这张图层是新建的，
        // 玻璃的 backdrop 读取一旦排在它栅格化之前，读到的就是空的。
        // 现在让页面直接画进同一趟 pass。
        Positioned.fill(child: page),
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: state.buildTop(),
        ),
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
