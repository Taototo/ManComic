import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:venera/foundation/history.dart';

import 'appdata.dart';
import 'favorites.dart';
import 'local.dart';

export "widget_utils.dart";
export "context.dart";

class _App {
  final version = "1.6.3";

  bool get isAndroid => Platform.isAndroid;

  bool get isIOS => Platform.isIOS;

  bool get isWindows => Platform.isWindows;

  bool get isLinux => Platform.isLinux;

  bool get isMacOS => Platform.isMacOS;

  bool get isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  bool get isMobile => Platform.isAndroid || Platform.isIOS;

  // Whether the app has been initialized.
  // If current Isolate is main Isolate, this value is always true.
  bool isInitialized = false;

  Locale get locale {
    Locale deviceLocale = PlatformDispatcher.instance.locale;
    if (deviceLocale.languageCode == "zh" &&
        deviceLocale.scriptCode == "Hant") {
      deviceLocale = const Locale("zh", "TW");
    }
    if (appdata.settings['language'] != 'system') {
      return Locale(
        appdata.settings['language'].split('-')[0],
        appdata.settings['language'].split('-')[1],
      );
    }
    return deviceLocale;
  }

  late String dataPath;
  late String cachePath;
  String? externalStoragePath;

  final rootNavigatorKey = GlobalKey<NavigatorState>();

  GlobalKey<NavigatorState>? mainNavigatorKey;

  BuildContext get rootContext => rootNavigatorKey.currentContext!;

  final Appdata data = appdata;

  final HistoryManager history = HistoryManager();

  final LocalFavoritesManager favorites = LocalFavoritesManager();

  final LocalManager local = LocalManager();

  void rootPop() {
    rootNavigatorKey.currentState?.maybePop();
  }

  void pop() {
    if (rootNavigatorKey.currentState?.canPop() ?? false) {
      rootNavigatorKey.currentState?.pop();
    } else if (mainNavigatorKey?.currentState?.canPop() ?? false) {
      mainNavigatorKey?.currentState?.pop();
    }
  }

  /// 上一次系统返回事件被处理的时刻。
  ///
  /// 同一次物理返回手势（尤其是 Android 预测性返回）有可能被派发两次：
  /// 一次来自路由自带的返回手势、一次来自系统返回键的兜底回调。
  /// 这里做一次很短的节流，保证「一次手势只回退一层」。
  DateTime? _lastBackHandled;

  /// 统一的系统返回入口：一次只回退一层。
  ///
  /// App 里有两套导航器：
  /// * 根导航器（rootNavigatorKey）挂着主导航器上方的弹层，如收藏面板、
  ///   弹窗、阅读器；
  /// * 主导航器（mainNavigatorKey）装着三个 Tab 里的页面栈。
  ///
  /// 视觉上根导航器永远在上面，所以顺序必须是「先根、后主、最后退出应用」。
  /// 由单一入口按这个顺序退栈，才不会出现一次侧滑关掉两层、或者关掉
  /// 被弹层遮住的下层页面。
  Future<void> handleBack() async {
    final now = DateTime.now();
    final last = _lastBackHandled;
    if (last != null && now.difference(last) < const Duration(milliseconds: 120)) {
      return;
    }
    _lastBackHandled = now;

    final root = rootNavigatorKey.currentState;
    // 根导航器：只有上面压着弹层时才需要处理。根路由自身挂着本方法所在的
    // PopScope，这里必须先判 canPop()，否则会绕回自己形成递归。
    if (root != null && root.canPop() && await root.maybePop()) {
      return;
    }

    // 主导航器：不要先判 canPop()。收藏页的多选/搜索状态是用 PopScope 表达
    // 的，此时栈里只有一层、canPop() 为 false，但这次返回仍应交给它退出
    // 多选状态，而不是直接退出应用。maybePop 在无人处理时返回 false，
    // 会继续往下走。
    final main = mainNavigatorKey?.currentState;
    if (main != null && await main.maybePop()) {
      return;
    }

    // 已经退到最底层：Android 上按返回键退出应用；其它平台没有系统返回键，
    // 不应该由这里主动结束进程。
    if (isAndroid) {
      SystemNavigator.pop();
    }
  }

  Future<void> init() async {
    cachePath = (await getApplicationCacheDirectory()).path;
    dataPath = (await getApplicationSupportDirectory()).path;
    if (isAndroid) {
      externalStoragePath = (await getExternalStorageDirectory())!.path;
    }
    isInitialized = true;
  }

  Future<void> initComponents() async {
    await Future.wait([
      data.init(),
      history.init(),
      favorites.init(),
      local.init(),
    ]);
  }

  Function? _forceRebuildHandler;

  void registerForceRebuild(Function handler) {
    _forceRebuildHandler = handler;
  }

  void forceRebuild() {
    _forceRebuildHandler?.call();
  }
}

// ignore: non_constant_identifier_names
final App = _App();
