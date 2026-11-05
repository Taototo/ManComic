import 'dart:async';

import 'package:display_mode/display_mode.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_saf/flutter_saf.dart';
import 'package:rhttp/rhttp.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/background_tasks.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/notification_service.dart';
import 'package:venera/foundation/startup_gate.dart';
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
  }
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
  if (App.isAndroid) {
    handleLinks();
    handleTextShare();
    // 保证桌面 launcher 入口存在（防止升级后组件状态残留导致无图标）
    await AppIcon.ensureApplied();
    await NotificationService.init();
    await BackgroundTasks.initialize();
    await BackgroundTasks.syncSchedule();
    try {
      await FlutterDisplayMode.setHighRefreshRate();
    } catch(e) {
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

void _checkOldConfigs() {
  if (appdata.settings['searchSources'] == null) {
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

/// 自动检查的节流间隔。
///
/// 语义上「启动时检查更新」就该是每次冷启动都查，这里只拦掉「30 分钟内来回
/// 切好几次」的重复请求。不用按天节流：这个分支常常一天发两三版，早上装的
/// 版本下午就过期了，按天算等于当天再也发现不了新版本。
///
/// 请求本身很小（Release API 几 KB），未认证限流是 60 次/小时，30 分钟一次
/// 完全够用。
const _kUpdateCheckInterval = Duration(minutes: 30);

/// 检查失败后的重试间隔。
///
/// 失败（断网、GitHub 被墙）不能占用成功的额度，否则一次开机时的网络抖动
/// 就会让「启动时检查更新」在接下来的整段时间里失效；但也不能每次启动都去
/// 撞墙，所以失败后隔半小时再试。
const _kUpdateCheckRetryInterval = Duration(minutes: 30);

/// 漫画源列表的更新节流。
///
/// 与「应用更新」完全独立：漫画源列表变动慢，没必要跟着应用更新的节奏
/// 频繁请求；反过来，应用更新的节流也不该把漫画源检查按在门外。
const _kComicSourceCheckInterval = Duration(hours: 24);

Future<void> _checkAppUpdates() async {
  var now = DateTime.now().millisecondsSinceEpoch;

  // 开关默认关闭，没开就到此为止。
  if (appdata.settings['checkUpdateOnStart'] != true) {
    return;
  }

  // 刚升级完一定查一次：新版本里可能带了「更新检查」本身的修复，
  // 若还被上一版写下的节流挡住，用户只会觉得开关依然没用。
  var versionChanged =
      appdata.implicitData['lastCheckUpdateVersion'] != appVersionName;
  var lastSuccess = appdata.implicitData['lastCheckUpdate'] ?? 0;
  if (!versionChanged &&
      now - lastSuccess < _kUpdateCheckInterval.inMilliseconds) {
    return;
  }
  var lastFail = appdata.implicitData['lastCheckUpdateFailed'] ?? 0;
  if (now - lastFail < _kUpdateCheckRetryInterval.inMilliseconds) {
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
  for (var i = 0;
      i < 20 && App.rootNavigatorKey.currentContext == null;
      i++) {
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
