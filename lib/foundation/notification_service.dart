import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';

/// 本地通知服务（目前用于「追更提醒」）。
///
/// 只在 Android / iOS 上工作，其他平台所有方法都直接返回。
class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  /// 应用是否在前台。前台时不弹通知（用户自己看得到更新），避免打扰。
  static bool isForeground = true;

  static const String _channelId = 'follow_updates';

  static const int _notifyId = 1001;

  static bool get _supported => App.isAndroid;

  static Future<void> init() async {
    if (!_supported || _initialized) {
      return;
    }
    _initialized = true;
    try {
      const android = AndroidInitializationSettings('@drawable/ic_stat_comic');
      await _plugin.initialize(const InitializationSettings(android: android));
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          '追更提醒',
          description: '收藏的漫画有新章节时提醒',
          importance: Importance.defaultImportance,
        ),
      );
    } catch (e, s) {
      Log.error("Notification", "Failed to initialize: $e\n$s");
    }
  }

  /// 请求通知权限（Android 13+ 需要）。
  static Future<bool> requestPermission() async {
    if (!_supported) {
      return false;
    }
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) {
        return false;
      }
      final granted = await android.requestNotificationsPermission();
      return granted ?? false;
    } catch (e, s) {
      Log.error("Notification", "Failed to request permission: $e\n$s");
      return false;
    }
  }

  /// 检查是否已获得通知权限。
  static Future<bool> hasPermission() async {
    if (!_supported) {
      return false;
    }
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final enabled = await android?.areNotificationsEnabled();
      return enabled ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 发送追更提醒。[titles] 为本次检查中新更新的漫画名。
  static Future<void> notifyUpdates(
    List<String> titles,
    int total, {
    bool force = false,
  }) async {
    if (!_supported || total <= 0) {
      return;
    }
    if (!force && isForeground) {
      return;
    }
    await init();
    try {
      final preview = titles.take(3).join('、');
      final more = total > titles.take(3).length ? ' 等' : '';
      final body = preview.isEmpty
          ? "$total 部漫画有新章节"
          : "$total 部漫画有更新：$preview$more";
      await _plugin.show(
        _notifyId,
        "追更提醒",
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            "追更提醒",
            channelDescription: '收藏的漫画有新章节时提醒',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            styleInformation: BigTextStyleInformation(body),
            ticker: "追更提醒",
          ),
        ),
        payload: "follow_updates",
      );
    } catch (e, s) {
      Log.error("Notification", "Failed to show: $e\n$s");
    }
  }

  static Future<void> cancelAll() async {
    if (!_supported) {
      return;
    }
    try {
      await _plugin.cancelAll();
    } catch (_) {}
  }

  /// 供设置页显示用（例如判断是否需要引导用户去系统设置打开通知）。
  static Future<String?> debugPlatformInfo() async {
    if (!Platform.isAndroid) {
      return null;
    }
    return "android";
  }
}
