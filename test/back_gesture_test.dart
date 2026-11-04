import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/app_page_route.dart';

/// 构造一个系统侧滑返回事件（Android 预测性返回）。
///
/// `Platform.isAndroid` 在 flutter_tester 里恒为 false，转场不会挂上检测器，
/// 所以这里直接把事件喂给 [PredictiveBackGestureDetectorState]。
PredictiveBackEvent _backEvent(double progress) =>
    PredictiveBackEvent.fromMap(<String, Object?>{
      'progress': progress,
      'swipeEdge': 0,
      'touchOffset': const <double>[0.0, 300.0],
    });

/// 验证「被外层盖住的路由不接管返回手势」这条规则，以及非路由浮层的接入。
void main() {
  testWidgets('滑动转场可以正常构建并完成进出动画', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: Text('home')),
    ));

    navKey.currentState!.push(AppPageRoute(
      builder: (_) => const Scaffold(body: Text('second')),
    ));
    await tester.pump();
    // 动画中途：两页同时在树上，正是之前 PhysicalModel 每帧 saveLayer 的场景
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('second'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);

    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('second'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('内层导航栈被外层路由盖住时让出返回手势', (tester) async {
    final innerKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.rootNavigatorKey,
      home: Scaffold(
        body: Navigator(
          key: innerKey,
          onGenerateRoute: (settings) => AppPageRoute(
            settings: settings,
            builder: (_) => const Scaffold(body: Text('inner-0')),
          ),
        ),
      ),
    ));

    // 内层再压一页，构成「内层栈顶」
    innerKey.currentState!.push(AppPageRoute(
      builder: (_) => const Scaffold(body: Text('inner-1')),
    ));
    await tester.pumpAndSettle();

    final root = App.rootNavigatorKey.currentState!;
    expect(root.canPop(), isFalse);

    final innerTop = _topRoute(innerKey.currentState!);
    // 外层栈空着：内层栈顶可以自己处理返回手势
    expect(innerTop.popGestureEnabled, isTrue);

    // 外层栈压一条路由（模拟收藏面板 / 弹窗 / 阅读器 / 图片查看器）
    root.push(AppPageRoute(
      builder: (_) => const Scaffold(body: Text('overlay')),
    ));
    await tester.pumpAndSettle();

    // 内层栈顶被盖住 → 必须让出，否则一次返回会把里外两层一起关掉
    expect(innerTop.popGestureEnabled, isFalse);

    // 外层关掉后恢复
    root.pop();
    await tester.pumpAndSettle();
    expect(innerTop.popGestureEnabled, isTrue);
  });

  testWidgets('非路由浮层也让出返回手势，且返回优先关闭浮层', (tester) async {
    var dismissed = 0;
    App.nonRouteOverlayDismisser = () => dismissed++;

    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.rootNavigatorKey,
      home: const Scaffold(body: Text('home')),
    ));

    final root = App.rootNavigatorKey.currentState!;
    root.push(AppPageRoute(
      builder: (_) => const Scaffold(body: Text('page-1')),
    ));
    await tester.pumpAndSettle();

    final page = _topRoute(root);
    expect(page.popGestureEnabled, isFalse);

    App.nonRouteOverlayDismisser = null;
    expect(page.popGestureEnabled, isTrue);

    // 返回时先关浮层，页面本身不动
    App.nonRouteOverlayDismisser = () => dismissed++;
    await App.handleBack();
    expect(dismissed, 1);
    expect(_topRoute(root), same(page));
  });

  testWidgets('退到最底层时 handleBack 返回 false，交给调用方确认退出', (tester) async {
    // handleBack 对同一次返回有 120ms 节流（防止一次手势退两层），
    // 前面的用例刚调用过，这里先等真实时间过去再测。
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );

    App.nonRouteOverlayDismisser = null;
    App.mainNavigatorKey = null;

    await tester.pumpWidget(MaterialApp(
      navigatorKey: App.rootNavigatorKey,
      home: const Scaffold(body: Text('home')),
    ));

    // 栈里只剩根路由：没有可退的了，返回 false 交由调用方弹「是否退出」
    expect(await App.handleBack(), isFalse);
  });

  testWidgets('松手提交时页面不回弹，从手指位置直接滑走', (tester) async {
    App.nonRouteOverlayDismisser = null;
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: Text('home')),
    ));

    late AppPageRoute route;
    route = AppPageRoute(
      builder: (_) => PredictiveBackGestureDetector(
        route: route,
        child: const Scaffold(body: Text('second')),
      ),
    );
    navKey.currentState!.push(route);
    await tester.pumpAndSettle();

    final detector =
        tester.state<PredictiveBackGestureDetectorState>(
            find.byType(PredictiveBackGestureDetector));

    // 划到 30%：系统 progress 按「触发返回的距离」归一化，页面位移做了
    // 0.5 的减速映射，动画值应为 1 - 0.5 × 0.3 = 0.85
    expect(detector.handleStartBackGesture(_backEvent(0.3)), isTrue);
    await tester.pump();
    expect(route.animation!.value, closeTo(0.85, 0.001));

    detector.handleCommitBackGesture();
    await tester.pump();
    // 关键断言：不能跳回 1.0。框架默认的 handleCommitBackGesture 会
    // reverse(from: upperBound)，页面先整页弹回原位再滑走（用户反馈的「闪一下」）。
    expect(route.animation!.value, lessThan(0.9));

    await tester.pumpAndSettle();
    expect(find.text('second'), findsNothing);
    // 手势状态必须复位，否则后续侧滑返回全部失灵
    expect(navKey.currentState!.userGestureInProgress, isFalse);
  });

  testWidgets('快划到底再松手，剩余动画不会瞬间闪完', (tester) async {
    App.nonRouteOverlayDismisser = null;
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: Text('home')),
    ));

    late AppPageRoute route;
    route = AppPageRoute(
      builder: (_) => PredictiveBackGestureDetector(
        route: route,
        child: const Scaffold(body: Text('second')),
      ),
    );
    navKey.currentState!.push(route);
    await tester.pumpAndSettle();

    final detector = tester.state<PredictiveBackGestureDetectorState>(
        find.byType(PredictiveBackGestureDetector));

    // 划走 85%（系统 progress 0.85，减速映射后页面只剩一半多一点位移）：
    // 按框架「时长随剩余比例缩放」的算法，这点位移会在五十毫秒内滑完，
    // 观感是"闪"一下消失。
    detector.handleStartBackGesture(_backEvent(0.85));
    await tester.pump();
    expect(route.animation!.value, closeTo(0.575, 0.001));

    detector.handleCommitBackGesture();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    // 80ms 后应该还在退场途中（现在至少有 210ms 的下限）
    expect(route.animation!.value, greaterThan(0));

    await tester.pumpAndSettle();
    expect(find.text('second'), findsNothing);
    expect(navKey.currentState!.userGestureInProgress, isFalse);
  });

  testWidgets('取消手势后页面回位，且手势状态复位', (tester) async {
    App.nonRouteOverlayDismisser = null;
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: Text('home')),
    ));

    late AppPageRoute route;
    route = AppPageRoute(
      builder: (_) => PredictiveBackGestureDetector(
        route: route,
        child: const Scaffold(body: Text('second')),
      ),
    );
    navKey.currentState!.push(route);
    await tester.pumpAndSettle();

    final detector =
        tester.state<PredictiveBackGestureDetectorState>(
            find.byType(PredictiveBackGestureDetector));

    // 划到 30%（减速映射后动画值 0.85）
    detector.handleStartBackGesture(_backEvent(0.3));
    await tester.pump();
    expect(route.animation!.value, closeTo(0.85, 0.001));

    detector.handleCancelBackGesture();
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);
    expect(route.animation!.value, 1.0);
    expect(navKey.currentState!.userGestureInProgress, isFalse);
  });
}

/// 取导航栈顶的路由（popUntil 在谓词命中栈顶时立即停止，不会真的退栈）。
ModalRoute _topRoute(NavigatorState navigator) {
  ModalRoute? result;
  navigator.popUntil((route) {
    if (route is ModalRoute) {
      result = route;
    }
    return true;
  });
  return result!;
}
