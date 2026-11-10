import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:rhttp/rhttp.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/display_refresh.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/background_tasks.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/notification_service.dart';
import 'package:venera/foundation/source_health.dart';
import 'package:venera/utils/download_background.dart';
import 'package:venera/foundation/startup_gate.dart';
import 'package:venera/foundation/update_check_policy.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/pages/settings/settings_page.dart';
import 'package:venera/utils/app_icon.dart';
import 'package:venera/utils/app_links.dart';
import 'package:venera/utils/handle_text_share.dart';
import 'package:venera/utils/opencc.dart';
import 'package:venera/utils/tags_translation.dart';
import 'package:venera/utils/translations.dart';
import 'foundation/appdata.dart';

extension _FutureInit<T> on Future<T> {
  /// Prevent unhandled exception
  ///
  /// A unhandled exception occurred in init() will cause the app to crash.
  Future<void> wait() async {
    try {
      await this;
    } catch (e, s) {
      Log.error("init", "$e\n$s");
    }
  }
}

/// 记录应用前后台状态，供通知使用（前台不打扰）。
class _LifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    NotificationService.isForeground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      // 冷启动时前台服务可能因为「进程还没被当成前台」没挂上，回到前台
      // 再试一次；已经在跑的（ticker 在转）这里什么也不会做。
      DownloadBackground.instance.refresh();
      // 后台被网络掐断而停下的下载，回前台再接上。
      LocalManager().retryErroredTasks();
      // 冷启动只查一次，可很多人根本不杀进程：App 一直躺在后台，切回来
      // 时 init() 不会重跑。少这一步，「启动时检查更新」就等于「开机时
      // 检查更新」，新版本发布后不手动点就永远发现不了。
      _checkAppUpdatesOnResume();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      // 进后台就把下载进度落盘。
      //
      // 平时靠 1.2 秒的合并窗口写，用户从最近任务里划掉应用时窗口里那笔
      // 还没轮到写，而进程下一秒就没了——下次进来进度就退回到上一次落盘
      // 的位置。收到 paused 时立刻写一次，代价只有一个几 KB 的 JSON。
      unawaited(LocalManager().saveDownloadProgressNow());
      // 后台可能被系统压住，再把前台服务抬一次，保证进程不被冻结。
      DownloadBackground.instance.refresh();
    }
  }
}

/// 回到前台时的静默检查。
///
/// 只有这条路会走节流（[_kUpdateCheckInterval]），避免一小时内进出十几次
/// 反复发请求；冷启动那次一律查，见 [updateCheckSkipReason]。
/// 仍在启动动画里时直接跳过——启动路径自己会查，别叠两次。
void _checkAppUpdatesOnResume() {
  if (!isStartupReady) {
    return;
  }
  unawaited(() async {
    try {
      await _checkAppUpdates(fromResume: true);
    } catch (e, s) {
      Log.error("Update Check", "Failed to check for updates on resume: $e\n$s");
    }
  }());
}

Future<void> init() async {
  await App.init().wait();
  await SingleInstanceCookieJar.createInstance();
  try {
    var futures = [
      Rhttp.init(),
      App.initComponents(),
      SAFTaskWorker().init().wait(),
      AppTranslation.init().wait(),
      TagsTranslation.readData().wait(),
      JsEngine().init().wait(),
      ComicSourceManager().init().wait(),
      OpenCC.init(),
    ];
    await Future.wait(futures);
  } catch (e, s) {
    Log.error("init", "$e\n$s");
  }
  CacheManager().setLimitSize(appdata.settings['cacheSize']);
  _checkOldConfigs();
  _setupSourceHealthFavoritesLink();
  if (App.isAndroid) {
    handleLinks();
    handleTextShare();
    // 保证桌面 launcher 入口存在（防止升级后组件状态残留导致无图标）
    await AppIcon.ensureApplied();
    await NotificationService.init();
    await BackgroundTasks.initialize();
    await BackgroundTasks.syncSchedule();
    try {
      // 先读一次屏幕信息（档位、最高刷新率），再按用户选择申请。
      // 申请失败不影响使用，Flutter 仍会跟随系统 vsync。
      await DisplayRefresh.refreshInfo();
      await DisplayRefresh.apply(appdata.settings['refreshRate'] ?? 'auto');
    } catch (e) {
      Log.error("Display Mode", "Failed to set high refresh rate: $e");
    }
  }
  WidgetsBinding.instance.addObserver(_LifecycleObserver());
  FlutterError.onError = (details) {
    Log.error("Unhandled Exception", "${details.exception}\n${details.stack}");
  };
  if (App.isWindows) {
    // Report to the monitor thread that the app is running
    // https://github.com/venera-app/venera/issues/343
    Timer.periodic(const Duration(seconds: 1), (_) {
      const methodChannel = MethodChannel('venera/method_channel');
      methodChannel.invokeMethod("heartBeat");
    });
  }
}

/// 源体检失败 → 收藏自动清理。
///
/// 「源挂了」这件事收藏侧本来就会判（`_isInvalidItem` 会看
/// `SourceHealthService.hasFailed`），缺的只是触发时机：以前得用户自己到
/// 收藏「全部」里点「一键清理失效」。体检一直是进源页自动跑的，跑完这里
/// 接一手，挂掉那些源下的漫画就自己进「失效」了。
///
/// 只在这一轮里失败集合真的变了时才会被调用（见 `_recordFailed`），
/// 源全都好好的时候一次库都不扫。
void _setupSourceHealthFavoritesLink() {
  SourceHealthService.instance.onFailuresChanged = () async {
    final moved = await LocalFavoritesManager().cleanupInvalid();
    if (moved <= 0) {
      return;
    }
    Log.info("Favorites", "Moved $moved comics to Invalid after source check");
    // 检测多半是在进源页时自动跑的，用户未必正看着收藏——不吱一声的话，
    // 「收藏怎么少了几本」就成了一个吓人的疑问。
    try {
      if (App.rootContext.mounted) {
        App.rootContext.showMessage(
          message: "Moved @a comics to Invalid".tlParams({"a": moved}),
        );
      }
    } catch (e) {
      // 启动早期还没有 Overlay 时 showMessage 会抛，吞掉即可，
      // 该挪的已经挪完了。
    }
  };
}

void _checkOldConfigs() {  if (appdata.settings['searchSources'] == null) {
    appdata.settings['searchSources'] = ComicSource.all()
        .where((e) => e.searchPageData != null)
        .map((e) => e.key)
        .toList();
  }

  if (appdata.implicitData['webdavAutoSync'] == null) {
    var webdavConfig = appdata.settings['webdav'];
    if (webdavConfig is List &&
        webdavConfig.length == 3 &&
        webdavConfig.whereType<String>().length == 3) {
      appdata.implicitData['webdavAutoSync'] = true;
    } else {
      appdata.implicitData['webdavAutoSync'] = false;
    }
    appdata.writeImplicitData();
  }
}

/// 漫画源列表的更新节流。
///
/// 与「应用更新」完全独立：漫画源列表变动慢，没必要跟着应用更新的节奏
/// 频繁请求；反过来，应用更新的节流也不该把漫画源检查按在门外。
const _kComicSourceCheckInterval = Duration(hours: 24);

Future<void> _checkAppUpdates({bool fromResume = false}) async {
  // 开关、冷启动、刚升级、刚查过、刚失败过，全交给这个纯函数判，
  // 规则写在一处。冷启动那次不做时间窗判断，切回前台才节流。
  var skip = updateCheckSkipReason(
    enabled: appdata.settings['checkUpdateOnStart'] == true,
    fromResume: fromResume,
    // 刚升级完一定查一次：新版本里可能带了「更新检查」本身的修复，
    // 若还被上一版写下的节流挡住，用户只会觉得开关依然没用。
    versionChanged:
        appdata.implicitData['lastCheckUpdateVersion'] != appVersionName,
    now: DateTime.now(),
    lastSuccessMs: appdata.implicitData['lastCheckUpdate'] ?? 0,
    lastFailureMs: appdata.implicitData['lastCheckUpdateFailed'] ?? 0,
  );
  if (skip != UpdateCheckSkip.none) {
    Log.info(
      "Update Check",
      "Skipped automatic check: ${skip.name}",
    );
    return;
  }

  // 请求立刻发出，和启动动画并行跑（约 1.6 秒）；结果先存着，
  // 等启动页退场后再弹窗，这样用户看到的就是「进主页即有更新提示」。
  prewarmUpdateCheck();
  await _waitForStartupUi();
  await checkUpdateUi(false);
  // 成功与失败的时间点都由 checkUpdateUi 自己记录：手动检查、启动检查
  // 走的是同一条路径，设置页才能统一显示「最近一次尝试的结果」。
}

/// 等启动页退场、根导航器就绪。
///
/// 之前的做法是 `Future.delayed(2s)` 硬等，既可能不够也可能白等。现在由
/// 启动页在退场时打开闸门，这里只负责「闸门开了 + 导航器有 context」。
Future<void> _waitForStartupUi() async {
  if (!isStartupReady) {
    try {
      // 兜底 8 秒：启动页万一没走完（异常、被系统打断），更新检查
      // 也不能永远挂着，宁可弹得晚一点。
      await startupReady.timeout(const Duration(seconds: 8));
    } catch (_) {}
  }
  for (var i = 0; i < 20 && App.rootNavigatorKey.currentContext == null; i++) {
    await Future.delayed(const Duration(milliseconds: 50));
  }
  // 让主页先完成首帧布局，避免弹窗和首帧渲染抢同一帧。
  await Future.delayed(const Duration(milliseconds: 160));
}

/// 漫画源列表更新，与应用更新完全独立。
///
/// 单独拎出来是因为它要联网：放在更新检查前面会抢带宽，让「马上检测到
/// 新版本」这件事被拖慢。现在延后 3 秒再跑。
void _checkComicSourceUpdates() {
  var now = DateTime.now().millisecondsSinceEpoch;
  var lastSourceCheck = appdata.implicitData['lastComicSourceCheck'] ?? 0;
  if (now - lastSourceCheck >= _kComicSourceCheckInterval.inMilliseconds) {
    appdata.implicitData['lastComicSourceCheck'] = now;
    appdata.writeImplicitData();
    ComicSourcePage.checkComicSourceUpdate();
  }
}

void checkUpdates() {
  // 应用更新检查：立刻起跑。
  //
  // 这里原来是 2 秒延时，加上 checkUpdateUi 里弹窗前又等 2 秒，从点图标
  // 到看见更新提示要 4 秒以上。现在请求与启动动画并行，启动页一退场
  // 就能弹窗。
  unawaited(() async {
    try {
      // 已下载但没安装的包优先提示：用户上次可能点了「稍后安装」，这次
      // 进来先给他一次安装机会。弹过就直接结束，不再叠一个「发现新版本」。
      // 没有待安装包时 resolvePendingUpdate 几乎立刻返回，不影响预热。
      if (await updateDownload.resolvePendingUpdate() != null) {
        await _waitForStartupUi();
        updateDownload.promptPendingInstall();
        return;
      }
      await _checkAppUpdates();
    } catch (e, s) {
      Log.error("Update Check", "Failed to check for updates: $e\n$s");
    }
  }());

  // 漫画源列表放到后面查，别和应用更新抢带宽。
  Future.delayed(const Duration(seconds: 3), () {
    try {
      _checkComicSourceUpdates();
    } catch (e, s) {
      Log.error("Update Check", "Failed to check comic sources: $e\n$s");
    }
  });

  // 初始化关注更新服务，也包装在错误处理中
  Future.delayed(const Duration(seconds: 1), () {
    try {
      FollowUpdatesService.initChecker();
    } catch (e, s) {
      Log.error(
        "Follow Updates",
        "Failed to initialize follow updates service: $e\n$s",
      );
    }
  });
}
