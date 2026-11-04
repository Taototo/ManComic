import 'dart:math';
import 'dart:ui';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';

const double _kBackGestureWidth = 20.0;
const int _kMaxDroppedSwipePageForwardAnimationTime = 800;
const int _kMaxPageBackAnimationTime = 420;
const double _kMinFlingVelocity = 1.0;

class AppPageRoute<T> extends PageRoute<T> with _AppRouteTransitionMixin{
  /// Construct a MaterialPageRoute whose contents are defined by [builder].
  AppPageRoute({
    required this.builder,
    super.settings,
    this.maintainState = true,
    super.fullscreenDialog,
    super.allowSnapshotting = true,
    super.barrierDismissible = false,
    this.enableIOSGesture = true,
    this.preventRebuild = true,
  }) {
    assert(opaque);
  }

  /// Builds the primary contents of the route.
  final WidgetBuilder builder;

  String? label;

  @override
  toString() => "/$label";

  @override
  Widget buildContent(BuildContext context) {
    var widget = builder(context);
    label = widget.runtimeType.toString();
    return widget;
  }

  @override
  final bool maintainState;

  @override
  String get debugLabel => '${super.debugLabel}(${settings.name})';

  @override
  final bool enableIOSGesture;

  @override
  final bool preventRebuild;
}

mixin _AppRouteTransitionMixin<T> on PageRoute<T> {
  /// Builds the primary contents of the route.
  @protected
  Widget buildContent(BuildContext context);

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  /// 返回比进入更缓一点。
  ///
  /// 进入动画要跟手、要利落，300ms 刚好；返回时页面是「退场」，同样的
  /// 时长会显得一闪而过，所以单独拉长到 380ms。两者互不影响：
  /// [reverseTransitionDuration] 只在 pop / 侧滑松手后生效。
  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 380);

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool canTransitionTo(TransitionRoute<dynamic> nextRoute) {
    // Don't perform outgoing animation if the next route is a fullscreen dialog.
    return nextRoute is PageRoute && !nextRoute.fullscreenDialog;
  }

  /// 侧滑松手后补完退场的时长。
  ///
  /// [AnimationController.reverse] 会把时长按「剩余位移占全程的比例」缩放：
  /// 划走七成再松手，只剩三成位移，380ms × 0.3 ≈ 114ms 就滑完了，观感就是
  /// 「唰」一下闪走。这里给剩余位移补一个下限——短距离也至少两百多毫秒，
  /// 同时保留划得越少、走得越快的手感。
  static Duration _reverseDurationFor(double remaining) {
    final ms = 210 + 260 * remaining.clamp(0.0, 1.0);
    return Duration(milliseconds: ms.round());
  }

  @override
  bool didPop(T? result) {
    final controller = this.controller;
    final remaining = controller?.value ?? 1.0;
    final popped = super.didPop(result);
    // 正常返回时 remaining 已经是 1，用 reverseTransitionDuration 即可；
    // 只有「滑到一半松手」（预测性返回提交、iOS 边缘手势）才会带着未走完的
    // 进度退场，这时接管动画时长。
    if (controller != null && remaining > 0.0 && remaining < 1.0) {
      controller.animateBack(
        0.0,
        duration: _reverseDurationFor(remaining),
        // 转场层在手势期间锁定为线性，曲线交给控制器，收尾才有缓出去的感觉。
        curve: Curves.easeOutCubic,
      );
    }
    return popped;
  }

  /// 侧滑取消（松手退回）的回弹。
  ///
  /// 框架默认是 `forward()`：时长按「剩余比例」缩放，只拖了一半的话
  /// 150ms 就弹回去了，显得仓促。这里固定给一段更从容的缓出回弹；
  /// 与框架实现一样，在动画结束时复位导航器的手势状态。
  @override
  void handleCancelBackGesture() {
    final controller = this.controller;
    final navigator = this.navigator;
    if (controller == null || navigator == null || controller.isCompleted) {
      navigator?.didStopUserGesture();
      return;
    }
    controller.animateTo(
      1.0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
    late final AnimationStatusListener statusCallback;
    statusCallback = (status) {
      controller.removeStatusListener(statusCallback);
      navigator.didStopUserGesture();
    };
    controller.addStatusListener(statusCallback);
  }

  bool get enableIOSGesture;

  bool get preventRebuild;

  /// 本页是否被「别的栈」上的东西盖住。
  ///
  /// 页面可能被两类东西遮住：
  /// * 祖先导航器里的弹层——收藏面板、漫画源列表弹窗、阅读器、图片查看器…
  ///   （根导航器在主 Tab 之上，弹窗内部又有自己的导航器，层层嵌套）；
  /// * 没有自己路由的浮层——长按封面预览（`ComicPeek`）。
  ///
  /// 路由自带的返回手势只知道「自己这条导航栈的栈顶是谁」，看不到外面盖着
  /// 什么。而 `isCurrent` 是按导航器判断的，里外两条栈的栈顶会同时被认定为
  /// 「当前页」，于是同一次返回被两边一起消费：弹层关了，被盖住的页面也被
  /// 划走——看起来就是「一次返回跳过了一级」。
  ///
  /// 所以只要外面还盖着东西，本页就把这次返回让出去。没人接管时系统会补发
  /// 一次普通返回（handlePopRoute），由根路由上的 PopScope 交给
  /// [App.handleBack] 一层一层地退。
  bool get _coveredByOverlay {
    if (App.nonRouteOverlayDismisser != null) {
      return true;
    }
    final nav = navigator;
    if (nav == null) {
      return false;
    }
    // 本导航器挂在某条祖先路由里（主 Tab 挂在根路由里、弹窗内部的导航器
    // 挂在弹窗路由里…）。那条祖先路由如果已经不是栈顶，说明它上面还压着
    // 别的东西，本页就不该接管这次返回。
    final container = ModalRoute.of(nav.context);
    return container != null && !container.isCurrent;
  }

  @override
  bool get popGestureEnabled {
    if (_coveredByOverlay) {
      return false;
    }
    return super.popGestureEnabled;
  }

  Widget? _child;

  @override
  Widget buildPage(
      BuildContext context,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
      ) {
    Widget result;

    if(preventRebuild){
      result = _child ?? (_child = buildContent(context));
    } else {
      result = buildContent(context);
    }

    return Semantics(
      scopesRoute: true,
      explicitChildNodes: true,
      child: result,
    );
  }

  static bool _isPopGestureEnabled<T>(PageRoute<T> route) {
    if (route.isFirst ||
        route.willHandlePopInternally ||
        route.popDisposition == RoutePopDisposition.doNotPop ||
        route.fullscreenDialog ||
        route.animation!.status != AnimationStatus.completed ||
        route.secondaryAnimation!.status != AnimationStatus.dismissed ||
        !route.popGestureEnabled ||
        route.navigator!.userGestureInProgress) {
      return false;
    }

    return true;
  }

  @override
  Widget buildTransitions(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    // 统一用「水平滑动」转场，Android 也不用 zoom 那套。
    //
    // zoom 转场（Material 默认）是**两页同时缩放 + 淡化**：进/出页面在
    // 300ms 内都是半透明的，而本 App 的页面背景是透明的（只有卡片自己带
    // 底色），两页一叠就会互相透出——上层页的卡片看起来"盖住"了下层页的
    // 内容，边框还错开十几像素。侧滑返回走到一半松手时最明显。
    //
    // 纯滑动转场里，上层页始终不透明地把下层页推走/拉回，不存在两页同时
    // 可见的瞬间，也就没有这种穿透。
    Widget result = const SlidePageTransitionBuilder().buildTransitions(
      this,
      context,
      animation,
      secondaryAnimation,
      child,
    );

    if (enableIOSGesture && App.isIOS) {
      // iOS：左边缘拖拽返回，自带跟手进度。
      return IOSBackGestureDetector(
        gestureWidth: _kBackGestureWidth,
        enabledCallback: () => _isPopGestureEnabled<T>(this),
        onStartPopGesture: () => _startPopGesture(this),
        child: result,
      );
    }

    if (App.isAndroid) {
      // Android：系统手势返回（预测性返回）是全局的，没有「左边缘拖拽」
      // 这种局部识别器，只能挂到 WidgetsBinding 的观察者上。
      return PredictiveBackGestureDetector(route: this, child: result);
    }

    return result;
  }

  IOSBackGestureController _startPopGesture(PageRoute<T> route) {
    return IOSBackGestureController(route.controller!, route.navigator!);
  }
}

class IOSBackGestureController {
  final AnimationController controller;

  final NavigatorState navigator;

  IOSBackGestureController(this.controller, this.navigator) {
    navigator.didStartUserGesture();
  }

  void dragEnd(double velocity) {
    const Curve animationCurve = Curves.fastLinearToSlowEaseIn;
    final bool animateForward;

    if (velocity.abs() >= _kMinFlingVelocity) {
      animateForward = velocity <= 0;
    } else {
      animateForward = controller.value > 0.5;
    }

    if (animateForward) {
      final droppedPageForwardAnimationTime = min(
        lerpDouble(
                _kMaxDroppedSwipePageForwardAnimationTime, 0, controller.value)!
            .floor(),
        _kMaxPageBackAnimationTime,
      );
      controller.animateTo(1.0,
          duration: Duration(milliseconds: droppedPageForwardAnimationTime),
          curve: animationCurve);
    } else {
      navigator.pop();
      if (controller.isAnimating) {
        // 同样给剩余位移留出时间：从 210ms 起，划得越少走得越快，
        // 但不会出现「只剩一小段却瞬间消失」的观感。
        final droppedPageBackAnimationTime =
            lerpDouble(210, _kMaxPageBackAnimationTime, controller.value)!
                .floor();
        controller.animateBack(0.0,
            duration: Duration(milliseconds: droppedPageBackAnimationTime),
            curve: animationCurve);
      }
    }

    if (controller.isAnimating) {
      late AnimationStatusListener animationStatusCallback;
      animationStatusCallback = (status) {
        navigator.didStopUserGesture();
        controller.removeStatusListener(animationStatusCallback);
      };
      controller.addStatusListener(animationStatusCallback);
    } else {
      navigator.didStopUserGesture();
    }
  }

  void dragUpdate(double delta) {
    controller.value -= delta;
  }
}

class IOSBackGestureDetector extends StatefulWidget {
  const IOSBackGestureDetector({
    required this.enabledCallback,
    required this.child,
    required this.gestureWidth,
    required this.onStartPopGesture,
    super.key,
  });

  final double gestureWidth;
  final bool Function() enabledCallback;
  final IOSBackGestureController Function() onStartPopGesture;
  final Widget child;

  @override
  State<IOSBackGestureDetector> createState() => _IOSBackGestureDetectorState();
}

class _IOSBackGestureDetectorState extends State<IOSBackGestureDetector> {
  IOSBackGestureController? _backGestureController;
  late _BackSwipeRecognizer _recognizer;


  @override
  void initState() {
    super.initState();
    _recognizer = _BackSwipeRecognizer(
      debugOwner: this,
      gestureWidth: widget.gestureWidth,
      isPointerInHorizontal: _isPointerInHorizontalScrollable,
      onStart: _handleDragStart,
      onUpdate: _handleDragUpdate,
      onEnd: _handleDragEnd,
      onCancel: _handleDragCancel,
    );
  }

  @override
  void dispose() {
    _recognizer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: {
        _BackSwipeRecognizer: GestureRecognizerFactoryWithHandlers<_BackSwipeRecognizer>(
          () => _recognizer,
          (instance) {
            instance.gestureWidth = widget.gestureWidth;
          },
        ),
      },
      child: widget.child,
    );
  }

  bool _isPointerInHorizontalScrollable(Offset globalPosition) {
    final HitTestResult result = HitTestResult();
    final binding = WidgetsBinding.instance;
    binding.hitTestInView(result, globalPosition, binding.platformDispatcher.implicitView!.viewId);

    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderViewport) {
        if (target.axisDirection == AxisDirection.left || 
            target.axisDirection == AxisDirection.right) {
          return true;
        }
      } 
      else if (target is RenderSliver) {
         if (target.constraints.axisDirection == AxisDirection.left || 
             target.constraints.axisDirection == AxisDirection.right) {
          return true;
        }
      }
      else if (target.runtimeType.toString() == '_RenderSingleChildViewport') {
        try {
          final dynamic renderObject = target;
          if (renderObject.axis == Axis.horizontal) {
            return true;
          }
        } catch (e) {
          // protected
        }
      }
      else if (target is RenderEditable) {
         return true;
      }
    }
    return false;
  }

  void _handleDragStart(DragStartDetails details) {
    if (!widget.enabledCallback()) return;
    if (mounted && _backGestureController == null) {
      _backGestureController = widget.onStartPopGesture();
    }
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (mounted && _backGestureController != null) {
      _backGestureController!.dragUpdate(
          _convertToLogical(details.primaryDelta! / context.size!.width));
    }
  }

  void _handleDragEnd(DragEndDetails details) {
    if (mounted && _backGestureController != null) {
      _backGestureController!.dragEnd(_convertToLogical(
          details.velocity.pixelsPerSecond.dx / context.size!.width));
      _backGestureController = null;
    }
  }

  void _handleDragCancel() {
    if (mounted && _backGestureController != null) {
      _backGestureController?.dragEnd(0.0);
      _backGestureController = null;
    }
  }

  double _convertToLogical(double value) {
    switch (Directionality.of(context)) {
      case TextDirection.rtl: return -value;
      case TextDirection.ltr: return value;
    }
  }
}

class _BackSwipeRecognizer extends OneSequenceGestureRecognizer {
  _BackSwipeRecognizer({
    required this.isPointerInHorizontal,
    required this.gestureWidth,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.onCancel,
    super.debugOwner,
  });

  final bool Function(Offset globalPosition) isPointerInHorizontal;
  double gestureWidth;
  final ValueSetter<DragStartDetails> onStart;
  final ValueSetter<DragUpdateDetails> onUpdate;
  final ValueSetter<DragEndDetails> onEnd;
  final VoidCallback onCancel;

  Offset? _startGlobal;
  bool _accepted = false;
  bool _startedInHorizontal = false;
  bool _startedNearLeftEdge = false; 

  VelocityTracker? _velocityTracker;

  static const double _minDistance = 5.0; 

  @override
  void addPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer);
    _startGlobal = event.position;
    _accepted = false;
    
    _startedInHorizontal = isPointerInHorizontal(event.position);
    _startedNearLeftEdge = event.position.dx <= gestureWidth;

    _velocityTracker = VelocityTracker.withKind(event.kind);
    _velocityTracker?.addPosition(event.timeStamp, event.position);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent || event is PointerUpEvent) {
      _velocityTracker?.addPosition(event.timeStamp, event.position);
    }

    if (event is PointerMoveEvent) {
      if (_startGlobal == null) return;
      final delta = event.position - _startGlobal!;
      final dx = delta.dx;
      final dy = delta.dy.abs();

      if (!_accepted) {
        if (delta.distance < _minDistance) return;

        final isRight = dx > 0;
        final isHorizontal = dx.abs() > dy * 1.5;
        final bool eligible = _startedNearLeftEdge || (!_startedInHorizontal);

        if (isRight && isHorizontal && eligible) {
          _accepted = true;
          resolve(GestureDisposition.accepted);
          onStart(DragStartDetails(
            globalPosition: _startGlobal!, 
            localPosition: event.localPosition
          ));
        } else {
          resolve(GestureDisposition.rejected);
          stopTrackingPointer(event.pointer);
          _startGlobal = null;
          _velocityTracker = null;
        }
      }

      if (_accepted) {
        onUpdate(DragUpdateDetails(
          globalPosition: event.position,
          localPosition: event.localPosition,
          primaryDelta: event.delta.dx,
          delta: Offset(event.delta.dx, 0),
        ));
      }
    } else if (event is PointerUpEvent) {
      if (_accepted) {
        final Velocity velocity = _velocityTracker?.getVelocity() ?? Velocity.zero;
        
        onEnd(DragEndDetails(
          velocity: velocity,
          primaryVelocity: velocity.pixelsPerSecond.dx
        ));
      }
      _reset();
    } else if (event is PointerCancelEvent) {
      if (_accepted) {
        onCancel();
      }
      _reset();
    }
  }

  void _reset() {
    stopTrackingPointer(0);
    _accepted = false;
    _startGlobal = null;
    _startedInHorizontal = false;
    _startedNearLeftEdge = false;
    _velocityTracker = null;
  }

  @override
  String get debugDescription => 'IOSBackSwipe';

  @override
  void didStopTrackingLastPointer(int pointer) {}
}

/// Android 预测性返回（侧滑返回）的接管者。
///
/// Flutter 只在自带的 [PredictiveBackPageTransitionsBuilder] 里监听系统手势，
/// 本 App 用的是自己的水平滑动转场，不接管这些事件的话，手指划动时页面
/// **完全不动**，松手后才整页滑走——观感就是「划到一半突然跳一下」。
///
/// 这里把系统手势的 start / update / cancel / commit 转给 [PageRoute] 的进度
/// 接口，转场动画就跟着手指走，松手时由路由自己补完或回弹。
///
/// 只有 Android 会收到这些事件；Android 13 及以下、以及按返回键触发时，
/// 系统不会发送手势事件，仍然走原来的 popRoute 流程。
///
/// 公开出来是为了单测能直接驱动它（`Platform.isAndroid` 在 flutter_tester
/// 里恒为 false，走不到 `buildTransitions` 里挂载它的分支）。
class PredictiveBackGestureDetector extends StatefulWidget {
  const PredictiveBackGestureDetector({
    required this.route,
    required this.child,
    super.key,
  });

  final PageRoute<dynamic> route;

  final Widget child;

  @override
  State<PredictiveBackGestureDetector> createState() =>
      PredictiveBackGestureDetectorState();
}

class PredictiveBackGestureDetectorState extends State<PredictiveBackGestureDetector>
    with WidgetsBindingObserver {
  /// 本次手势是否由自己接管，避免同栈里多个路由同时响应。
  bool _active = false;

  /// 只有「本页是栈顶、且真的能退」时才接管。
  ///
  /// `popGestureEnabled` 里还包含「本页是否被弹层盖住」的判断，弹层自身的
  /// 返回由它自己的路由处理；`popDisposition` 则覆盖了收藏页多选这类用
  /// PopScope 表达的内部状态——那时的返回要交给 PopScope，不能直接弹栈。
  bool get _enabled =>
      widget.route.isCurrent &&
      widget.route.popDisposition != RoutePopDisposition.doNotPop &&
      widget.route.popGestureEnabled &&
      !widget.route.isFirst;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 系统手势进度 → 页面位移的减速系数。
  ///
  /// 系统给的 progress 按「触发返回的距离」归一化，而这段距离只有屏幕宽度的
  /// 一小段——直接用 `1 - progress` 的话，手指拖一点点页面就整页滑走，观感
  /// 就是「按住一拖页面一下就缩进去了」。乘上系数让页面每拖一段只走一半，
  /// 手指的移动与页面的位移大致成比例；松手后剩余的距离由补完动画顺出去。
  static const double _kDragRatio = 0.5;

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    // 按键返回没有触摸位置，交给系统走原来的 popRoute 流程。
    if (backEvent.isButtonEvent || !_enabled) {
      return false;
    }
    _active = true;
    // 系统给的 progress 是「离起点多远」，路由要的是「还剩多少」。
    widget.route.handleStartBackGesture(
      progress: 1 - _kDragRatio * backEvent.progress,
    );
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (!_active) {
      return;
    }
    widget.route.handleUpdateBackGestureProgress(
      progress: 1 - _kDragRatio * backEvent.progress,
    );
  }

  @override
  void handleCancelBackGesture() {
    if (!_active) {
      return;
    }
    _active = false;
    widget.route.handleCancelBackGesture();
    _ensureGestureStopped();
  }

  @override
  void handleCommitBackGesture() {
    if (!_active) {
      return;
    }
    _active = false;

    final navigator = widget.route.navigator;
    if (navigator == null) {
      return;
    }
    if (!widget.route.isCurrent) {
      // 手势途中栈顶变了：不能再 pop（会退掉别的页面）。
      _ensureGestureStopped();
      return;
    }

    // 不能调用 route.handleCommitBackGesture()：它内部是
    // `navigator.pop()` 之后 `controller.reverse(from: upperBound)`，
    // 会先把动画值硬拉回 1.0（页面整页弹回原位）再滑走。手指划到 70%
    // 松手时，观感就是「返回前先闪一下当前页」。
    //
    // 直接 pop：路由的 didPop 会对控制器调用 reverse()，从当前值开始
    // 回退——页面从手指停下的位置继续滑出，位置连续、没有跳变。
    //
    // 手势状态必须在 pop 之前复位：路由退场后会被立刻销毁，销毁时清掉
    // 动画的状态监听，任何「等动画结束再复位」的回调都不会被调用，导航器
    // 会永久停在手势状态（后续侧滑全部失灵）。复位会让转场曲线由线性切回
    // 缓动，这一点由 _SlidePageTransition 的「跟过手就一直线性」抵消。
    if (navigator.userGestureInProgress) {
      navigator.didStopUserGesture();
    }
    navigator.pop();
  }

  /// 手势结束后确保导航器退出「手势进行中」状态。
  ///
  /// 正常情况下路由会自己在补完动画结束时复位；但如果手势途中本页已经被
  /// 别的操作弹掉，路由会因为「不是栈顶」而跳过复位，导航器就永久卡在
  /// 手势状态里，之后的侧滑返回全部失灵。
  ///
  /// 动画还在跑的时候不能动：`userGestureInProgress` 一变，转场曲线就会
  /// 从线性切回缓动，正在播的回退动画会突然变速。
  void _ensureGestureStopped() {
    final navigator = widget.route.navigator;
    if (navigator == null || !navigator.userGestureInProgress) {
      return;
    }
    if (widget.route.animation?.isAnimating ?? false) {
      return;
    }
    navigator.didStopUserGesture();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 水平滑动转场：上层页从右侧滑入，下层页同时左移给出一段距离。
class SlidePageTransitionBuilder extends PageTransitionsBuilder {
  const SlidePageTransitionBuilder();

  /// 下层页被推开的比例，取屏幕宽度的一部分。
  static const double _secondaryOffset = -0.4;

  /// 上层页左边缘的投影，用来把「压在下面」的层次感做出来。
  ///
  /// 原来这里用的是 `PhysicalModel(elevation: 6)`：它为了画阴影会强制整页
  /// 走一次 `saveLayer`，滑动期间每一帧都要重做，在漫画页这种满屏图片的
  /// 场景下就是明显的掉帧。换成普通的 BoxShadow 后，阴影只在页面重绘时
  /// 画一次（配合外面的 RepaintBoundary），滑动只是移动图层。
  static const BoxDecoration _shadow = BoxDecoration(
    boxShadow: [
      BoxShadow(
        color: Color(0x1F000000),
        offset: Offset(-2, 0),
        blurRadius: 6,
      ),
    ],
  );

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // 手指拖着走的时候必须线性：手指移动多少，页面就走多少。
    return _SlidePageTransition(
      primaryAnimation: animation,
      secondaryAnimation: secondaryAnimation,
      dragging: route.popGestureInProgress,
      child: child,
    );
  }
}

/// 真正承载滑动转场的组件。
///
/// 之所以要单独做成 StatefulWidget，是因为 `buildTransitions` 在转场期间
/// 每帧都会被调用，如果在里面现算 `CurveTween`/`Tween`，就会每帧丢弃并
/// 重建动画对象、让 SlideTransition 反复退订再订阅。把动画缓存在 State 里，
/// 只有动画来源或曲线模式变化时才重建。
class _SlidePageTransition extends StatefulWidget {
  const _SlidePageTransition({
    required this.primaryAnimation,
    required this.secondaryAnimation,
    required this.dragging,
    required this.child,
  });

  /// 本页进入/离开时的进度，1 表示完全就位。
  final Animation<double> primaryAnimation;

  /// 本页被下一页覆盖时的进度，1 表示已被完全盖住。
  final Animation<double> secondaryAnimation;

  /// 是否正在跟着手指走（此时不能用曲线，否则跟手会有拖影感）。
  final bool dragging;

  final Widget child;

  @override
  State<_SlidePageTransition> createState() => _SlidePageTransitionState();
}

class _SlidePageTransitionState extends State<_SlidePageTransition> {
  late Animation<Offset> _primaryPosition;

  late Animation<Offset> _secondaryPosition;

  /// 这一页是否被手指拖过。
  ///
  /// 一旦跟过手就锁定为线性：松手后表示「手势进行中」的标志可能立刻被复位，
  /// 若此时把曲线从线性切回缓动，同一个动画值对应的位移会突变——页面会
  /// 在松手的一瞬间跳一下。锁定后松手前后的位移就严格连贯。
  bool _gestureDriven = false;

  @override
  void initState() {
    super.initState();
    _gestureDriven = widget.dragging;
    widget.primaryAnimation.addStatusListener(_handleAnimationStatus);
    _setupAnimations();
  }

  @override
  void dispose() {
    widget.primaryAnimation.removeStatusListener(_handleAnimationStatus);
    super.dispose();
  }

  /// 动画一结束就解除「跟手线性」锁定。
  ///
  /// 锁定只是为了避免松手瞬间曲线切换造成的位移突变；动画停下来后值不再
  /// 变化，此时恢复默认缓动不会产生任何跳变，却能让这一页之后的进出动画
  /// 回到正常的缓动曲线（否则经历过一次取消回弹的页面会一直匀速）。
  void _handleAnimationStatus(AnimationStatus status) {
    if (_gestureDriven &&
        !widget.dragging &&
        (status == AnimationStatus.completed ||
            status == AnimationStatus.dismissed)) {
      _gestureDriven = false;
      if (mounted) {
        setState(_setupAnimations);
      }
    }
  }

  @override
  void didUpdateWidget(covariant _SlidePageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.dragging && !_gestureDriven) {
      _gestureDriven = true;
    }
    if (oldWidget.primaryAnimation != widget.primaryAnimation) {
      oldWidget.primaryAnimation.removeStatusListener(_handleAnimationStatus);
      widget.primaryAnimation.addStatusListener(_handleAnimationStatus);
    }
    if (oldWidget.primaryAnimation != widget.primaryAnimation ||
        oldWidget.secondaryAnimation != widget.secondaryAnimation ||
        oldWidget.dragging != widget.dragging) {
      _setupAnimations();
    }
  }

  void _setupAnimations() {
    final curve =
        (widget.dragging || _gestureDriven) ? Curves.linear : Curves.fastOutSlowIn;
    _primaryPosition = widget.primaryAnimation
        .drive(CurveTween(curve: curve))
        .drive(Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero));
    _secondaryPosition = widget.secondaryAnimation
        .drive(CurveTween(curve: curve))
        .drive(
          Tween<Offset>(
            begin: Offset.zero,
            end: const Offset(SlidePageTransitionBuilder._secondaryOffset, 0),
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _secondaryPosition,
      transformHitTests: false,
      child: SlideTransition(
        position: _primaryPosition,
        child: RepaintBoundary(
          // RepaintBoundary 把整页内容固化成一层：滑动时只移动图层，
          // 不再逐帧重绘页面里的图片和文字。
          child: DecoratedBox(
            decoration: SlidePageTransitionBuilder._shadow,
            child: Material(child: widget.child),
          ),
        ),
      ),
    );
  }
}
