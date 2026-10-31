import 'package:flutter/widgets.dart';
import 'package:rhttp/rhttp.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/follow_updates.dart';
import 'package:venera/foundation/js_engine.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/notification_service.dart';
import 'package:venera/network/cookie_jar.dart';
import 'package:workmanager/workmanager.dart';

/// 后台追更检查：由 WorkManager 定期唤醒一个无界面的 Flutter 引擎，
/// 跑一遍收藏夹的更新检查，有新章节就发本地通知。
const String kFollowUpdatesTask = "mancomic-follow-updates";

const String kFollowUpdatesTaskUnique = "mancomic-follow-updates-periodic";

/// 后台执行的入口，不能是闭包，必须是顶层函数。
@pragma('vm:entry-point')
void backgroundCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      WidgetsFlutterBinding.ensureInitialized();
      await BackgroundTasks.initMinimal();
      if (appdata.settings['enableFollowUpdateNotification'] != true) {
        return true;
      }
      final folder = appdata.settings['followUpdatesFolder'];
      if (folder is! String || folder.isEmpty) {
        return true;
      }
      var updated = 0;
      var lastUpdated = 0;
      final titles = <String>[];
      await for (final progress in updateFolder(folder, false)) {
        if (progress.updated > lastUpdated) {
          lastUpdated = progress.updated;
          final comic = progress.comic;
          if (comic != null) {
            titles.add(comic.name);
          }
        }
        updated = progress.updated;
      }
      if (updated > 0) {
        await NotificationService.notifyUpdates(titles, updated, force: true);
      }
      Log.info("Background", "follow updates check finished, updated=$updated");
    } catch (e, s) {
      Log.error("Background", "follow updates check failed: $e\n$s");
    }
    return true;
  });
}

class BackgroundTasks {
  /// 只初始化后台检查所需的最小依赖（不含 UI 相关组件）。
  static Future<void> initMinimal() async {
    await App.init();
    await SingleInstanceCookieJar.createInstance();
    await Rhttp.init();
    await JsEngine().init();
    await ComicSourceManager().init();
    await LocalFavoritesManager().init();
    await NotificationService.init();
  }

  static Future<void> initialize() async {
    if (!App.isAndroid) {
      return;
    }
    try {
      await Workmanager().initialize(backgroundCallbackDispatcher);
    } catch (e, s) {
      Log.error("Background", "Failed to initialize workmanager: $e\n$s");
    }
  }

  /// 按当前设置注册/取消周期任务。
  static Future<void> syncSchedule() async {
    if (!App.isAndroid) {
      return;
    }
    try {
      final enabled = appdata.settings['enableFollowUpdateNotification'] == true;
      if (!enabled) {
        await Workmanager().cancelByUniqueName(kFollowUpdatesTaskUnique);
        return;
      }
      await Workmanager().registerPeriodicTask(
        kFollowUpdatesTaskUnique,
        kFollowUpdatesTask,
        frequency: const Duration(hours: 6),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    } catch (e, s) {
      Log.error("Background", "Failed to schedule task: $e\n$s");
    }
  }
}
