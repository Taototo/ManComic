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
const _kUpdateCheckInterval = Duration(hours: 24);

/// 检查失败后的重试间隔。
///
/// 失败（断网、GitHub 被墙）不能占用 24 小时的额度，否则一次开机时的网络
/// 抖动就会让「启动时检查更新」整天失效；但也不能每次启动都去撞墙，
/// 所以失败后隔半小时再试。
const _kUpdateCheckRetryInterval = Duration(minutes: 30);

Future<void> _checkAppUpdates() async {
  var now = DateTime.now().millisecondsSinceEpoch;
  // 刚升级完一定查一次：新版本里可能带了「更新检查」本身的修复，
  // 若还被上一版写下的 24 小时节流挡住，用户只会觉得开关依然没用。
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
  ComicSourcePage.checkComicSourceUpdate();
  if (!appdata.settings['checkUpdateOnStart']) {
    // 没开自动更新时，这次只用于漫画源更新检查，仍然记一个时间点做节流。
    appdata.implicitData['lastCheckUpdate'] = now;
    appdata.implicitData['lastCheckUpdateVersion'] = appVersionName;
    appdata.writeImplicitData();
    return;
  }
  var ok = await checkUpdateUi(false, true);
  // 成功时 checkUpdateUi 会自己记下时间点；失败只记一个短节流，
  // 让下次启动早一点再试，而不是把一整天的额度用掉。
  if (!ok) {
    appdata.implicitData['lastCheckUpdateFailed'] = now;
    appdata.writeImplicitData();
  }
}

void checkUpdates() {
  // 延迟执行更新检查，避免在应用启动时因网络错误导致白屏
  Future.delayed(const Duration(seconds: 2), () async {
    try {
      await _checkAppUpdates();
    } catch (e, s) {
      Log.error("Update Check", "Failed to check for updates: $e\n$s");
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
