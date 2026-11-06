part of 'components.dart';

class PopUpWidget<T> extends PopupRoute<T> {
  PopUpWidget(this.widget);

  final Widget widget;

  @override
  Color? get barrierColor => Colors.black54;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => "exit";

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    var height = MediaQuery.of(context).size.height * 0.9;
    bool showPopUp = MediaQuery.of(context).size.width > 500;
    final liquid = LiquidTheme.isOn(context);
    // 变量名不能叫 navigator：那会遮蔽 PopupRoute.navigator（NavigatorState），
    // 下面的 iOS 返回手势控制器就拿错了对象。
    //
    // 玻璃必须画在**每个页面自己**身上，不能只画在 Navigator 外面。
    // 只包一层的话，Navigator 里的页面全是透明的（canvasColor 已改透明），
    // 从分类页点进下级设置时，新页滑入的过程中两层内容同时可见——就是用户
    // 说的「重影」。页面各自带着不透明玻璃，滑入才是「新页盖住旧页」。
    Widget pageShell(BuildContext context, Widget child) {
      if (!liquid) return child;
      // 玻璃底下要垫**页面自己的背景**，不能让它去透背后的主页。
      // 之前玻璃直接盖在当前页面上，透出来的是主页的封面和文字（糊掉的版本），
      // 读起来仍然像「两层东西叠着」。垫一层同款色斑之后，透出来的就只是雾。
      return AppPageBackground(
        child: LiquidGlass(
          borderRadius: BorderRadius.zero,
          // 0.94 是个折中：再低就能看穿到背后的内容，再高就完全不像玻璃了。
          // 模糊仍然开着，所以透过来的那 6% 是糊的，看起来是「雾」而不是
          // 「漏出来的另一页」。
          opacity: 0.94,
          blur: GlassConfig.blur,
          borderWidth: 0,
          shadow: false,
          child: child,
        ),
      );
    }

    Widget content = Navigator(
      onGenerateRoute: (settings) => MaterialPageRoute(
        builder: (context) => pageShell(context, widget),
      ),
    );
    Widget body = PopupIndicatorWidget(
      child: Container(
        decoration: showPopUp
            ? BoxDecoration(
                borderRadius: BorderRadius.all(Radius.circular(12)),
                // 液态下浮窗的玻璃边。玻璃本身画在页面里（见 pageShell），
                // 外层只负责这一圈高光描边，不然页面是矩形、外面圆角也白留。
                border: liquid
                    ? Border.all(
                        color: Colors.white.withValues(alpha: 0.16),
                        width: 0.8,
                      )
                    : null,
                boxShadow: context.brightness == ui.Brightness.dark ? [
                  BoxShadow(
                    color: Colors.white.withAlpha(50),
                    blurRadius: 10,
                    offset: Offset(0, 2),
                  ),
                ] : null,
              )
            : null,
        clipBehavior: showPopUp ? Clip.antiAlias : Clip.none,
        width: showPopUp ? 500 : double.infinity,
        height: showPopUp ? height : double.infinity,
        child: ClipRect(child: content),
      ),
    );
    if (App.isIOS) {
      body = IOSBackGestureDetector(
        enabledCallback: () => true,
        gestureWidth: 20.0,
        onStartPopGesture: () =>
            IOSBackGestureController(controller!, navigator!),
        child: body,
      );
    }
    if (showPopUp) {
      return MediaQuery.removePadding(
        removeTop: true,
        context: context,
        child: Center(
          child: body,
        ),
      );
    }
    return body;
  }

  @override
  Duration get transitionDuration => const Duration(milliseconds: 260);

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    // 只有缩放，**不再整体淡入**。
    //
    // 之前是 `FadeTransition + ScaleTransition`：打开和关闭的头几帧面板只有
    // 50% 不透明，底下的主页清清楚楚地透上来；关闭时反过来又透一遍，用户在
    // 两个方向上都看到「两层内容叠着」。玻璃面板的不透明度是它自己的属性，
    // 不该由路由动画再乘一次。
    //
    // 保留缩放：0.94 → 1.0，起点已经是接近完整大小的面板，读起来是「弹出来」，
    // 不是「从背景里长出来」。
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return ScaleTransition(
      scale: Tween<double>(begin: 0.94, end: 1.0).animate(curved),
      child: child,
    );
  }
}

class PopupIndicatorWidget extends InheritedWidget {
  const PopupIndicatorWidget({super.key, required super.child});

  @override
  bool updateShouldNotify(covariant InheritedWidget oldWidget) => false;

  static PopupIndicatorWidget? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<PopupIndicatorWidget>();
  }
}

Future<T> showPopUpWidget<T>(BuildContext context, Widget widget) async {
  return await Navigator.of(context, rootNavigator: true)
      .push(PopUpWidget(widget));
}

class PopUpWidgetScaffold extends StatefulWidget {
  const PopUpWidgetScaffold(
      {required this.title, required this.body, this.tailing, super.key});

  final Widget body;
  final List<Widget>? tailing;
  final String title;

  @override
  State<PopUpWidgetScaffold> createState() => _PopUpWidgetScaffoldState();
}

class _PopUpWidgetScaffoldState extends State<PopUpWidgetScaffold> {
  bool top = true;

  @override
  Widget build(BuildContext context) {
    return Material(
      child: Column(
        children: [
          Container(
            height: 56 + context.padding.top,
            padding: EdgeInsets.only(top: context.padding.top),
            width: double.infinity,
            decoration: BoxDecoration(
              color: top
                  ? null
                  : Theme.of(context).colorScheme.surfaceTint.withAlpha(20),
            ),
            child: Row(
              children: [
                const SizedBox(
                  width: 8,
                ),
                Tooltip(
                  message: "Back".tl,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back_sharp),
                    onPressed: () =>
                        context.canPop() ? context.pop() : App.pop(),
                  ),
                ),
                const SizedBox(
                  width: 16,
                ),
                Text(
                  widget.title,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w500),
                ),
                const Spacer(),
                if (widget.tailing != null) ...widget.tailing!,
                const SizedBox(width: 8),
              ],
            ),
          ),
          NotificationListener<ScrollNotification>(
            onNotification: (notifications) {
              if (notifications.metrics.axisDirection != AxisDirection.down) {
                return false;
              }
              if (notifications.metrics.pixels ==
                      notifications.metrics.minScrollExtent &&
                  !top) {
                setState(() {
                  top = true;
                });
              } else if (notifications.metrics.pixels !=
                      notifications.metrics.minScrollExtent &&
                  top) {
                setState(() {
                  top = false;
                });
              }
              return false;
            },
            child: MediaQuery.removePadding(
              removeTop: true,
              context: context,
              child: Expanded(child: widget.body),
            ),
          ),
          SizedBox(
            height: MediaQuery.of(context).viewInsets.bottom -
                        0.05 * MediaQuery.of(context).size.height >
                    0
                ? MediaQuery.of(context).viewInsets.bottom -
                    0.05 * MediaQuery.of(context).size.height
                : 0,
          )
        ],
      ),
    );
  }
}
