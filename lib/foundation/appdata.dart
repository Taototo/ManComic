import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/init.dart';
import 'package:venera/utils/io.dart';

class Appdata with Init {
  Appdata._create();

  final Settings settings = Settings._create();

  var searchHistory = <String>[];

  bool _isSavingData = false;

  Future<void> saveData([bool sync = true]) async {
    while (_isSavingData) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    _isSavingData = true;
    try {
      var futures = <Future>[];
      var json = toJson();
      var data = jsonEncode(json);
      var file = File(FilePath.join(App.dataPath, 'appdata.json'));
      futures.add(file.writeAsString(data));

      var disableSyncFields = json["settings"]["disableSyncFields"] as String;
      if (disableSyncFields.isNotEmpty) {
        var json4sync = jsonDecode(data);
        List<String> customDisableSync = splitField(disableSyncFields);
        for (var field in customDisableSync) {
          json4sync["settings"].remove(field);
        }
        var data4sync = jsonEncode(json4sync);
        var file4sync = File(FilePath.join(App.dataPath, 'syncdata.json'));
        futures.add(file4sync.writeAsString(data4sync));
      }

      await Future.wait(futures);
    } finally {
      _isSavingData = false;
    }
    if (sync) {
      DataSync().uploadData();
    }
  }

  void addSearchHistory(String keyword) {
    if (searchHistory.contains(keyword)) {
      searchHistory.remove(keyword);
    }
    searchHistory.insert(0, keyword);
    if (searchHistory.length > 50) {
      searchHistory.removeLast();
    }
    saveData();
  }

  void removeSearchHistory(String keyword) {
    searchHistory.remove(keyword);
    saveData();
  }

  void clearSearchHistory() {
    searchHistory.clear();
    saveData();
  }

  Map<String, dynamic> toJson() {
    return {'settings': settings._data, 'searchHistory': searchHistory};
  }

  List<String> splitField(String merged) {
    return merged
        .split(',')
        .map((field) => field.trim())
        .where((field) => field.isNotEmpty)
        .toList();
  }

  /// Following fields are related to device-specific data and should not be synced.
  static const _disableSync = [
    "proxy",
    "authorizationRequired",
    "customImageProcessing",
    "webdav",
    "disableSyncFields",
    "deviceId",
  ];

  /// Sync data from another device
  void syncData(Map<String, dynamic> data) {
    if (data['settings'] is Map) {
      var settings = data['settings'] as Map<String, dynamic>;

      List<String> customDisableSync = splitField(
        this.settings["disableSyncFields"] as String,
      );

      for (var key in settings.keys) {
        if (!_disableSync.contains(key) && !customDisableSync.contains(key)) {
          this.settings[key] = settings[key];
        }
      }
    }
    searchHistory = List.from(data['searchHistory'] ?? []);
    saveData();
  }

  var implicitData = <String, dynamic>{};

  Future<void> writeImplicitData() async {
    while (_isSavingData) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    _isSavingData = true;
    try {
      var file = File(FilePath.join(App.dataPath, 'implicitData.json'));
      await file.writeAsString(jsonEncode(implicitData));
    } finally {
      _isSavingData = false;
    }
  }

  @override
  Future<void> doInit() async {
    var dataPath = (await getApplicationSupportDirectory()).path;
    var file = File(FilePath.join(dataPath, 'appdata.json'));
    if (!await file.exists()) {
      return;
    }
    try {
      var json = jsonDecode(await file.readAsString());
      for (var key in (json['settings'] as Map<String, dynamic>).keys) {
        if (json['settings'][key] != null) {
          settings[key] = json['settings'][key];
        }
      }
      searchHistory = List.from(json['searchHistory']);
    } catch (e) {
      Log.error("Appdata", "Failed to load appdata", e);
      Log.info("Appdata", "Resetting appdata");
      file.deleteIgnoreError();
    }
    if ((settings["deviceId"] as String).isEmpty) {
      settings._data["deviceId"] = const Uuid().v4();
      await saveData(false);
    }
    try {
      var implicitDataFile = File(FilePath.join(dataPath, 'implicitData.json'));
      if (await implicitDataFile.exists()) {
        implicitData = jsonDecode(await implicitDataFile.readAsString());
      }
    } catch (e) {
      Log.error("Appdata", "Failed to load implicit data", e);
      Log.info("Appdata", "Resetting implicit data");
      var implicitDataFile = File(FilePath.join(dataPath, 'implicitData.json'));
      implicitDataFile.deleteIgnoreError();
    }
    await _migrateUpdateCheckDefault();
  }

  /// 把老用户「启动时检查更新」的默认值从关翻到开，只翻一次。
  ///
  /// 光改 `Settings._create()` 里的默认值没用：`saveData` 序列化的是整张
  /// `_data` 表（含默认值），所以从 1.2.x 起每个用户的 appdata.json 里都
  /// 明明白白写着 `checkUpdateOnStart: false`，加载时会被原样覆盖回来。
  ///
  /// 迁移标记放在 implicitData 而不是 settings：后者会随坚果云同步到别的
  /// 设备，一台机器翻过之后另一台就再也不翻了。
  Future<void> _migrateUpdateCheckDefault() async {
    if (implicitData['updateCheckDefaultOnMigrated'] == true) {
      return;
    }
    implicitData['updateCheckDefaultOnMigrated'] = true;
    if (settings._data['checkUpdateOnStart'] != true) {
      settings._data['checkUpdateOnStart'] = true;
      // 只管本地文件：迁移不是用户操作，不该顺手触发一次云端上传。
      saveData(false);
    }
    await writeImplicitData();
  }
}

final appdata = Appdata._create();

class Settings with ChangeNotifier {
  Settings._create();

  final _data = <String, dynamic>{
    'comicDisplayMode': 'detailed', // detailed, brief
    'comicLayoutMode': 'grid', // grid, staggered
    'comicTileScale': 1.00, // 0.75-1.25
    'color': 'system', // red, pink, purple, green, orange, blue
    'theme_mode': 'system', // light, dark, system
    'glassBlur': 26, // 0-40, 毛玻璃模糊半径
    'glassOpacity': 58, // 10-95, 毛玻璃不透明度百分比
    'liquidGlass': true, // 顶栏/底栏是否用带折射的液态玻璃引擎
    'liquidGlassQuality': 'standard', // minimal, standard, premium
    'refreshRate': 'auto', // auto, 60, 90, 120
    'showFps': false, // 右下角帧率读数（诊断用）
    'newFavoriteAddTo': 'end', // start, end
    'moveFavoriteAfterRead': 'none', // none, end, start
    'proxy': 'system', // direct, system, proxy string
    'enableUrlFiltering': true, // 过滤可能导致卡顿的大响应URL
    'explore_pages': [],
    'categories': [],
    'favorites': [],
    'searchSources': null,
    'showFavoriteStatusOnTile': true,
    'showHistoryStatusOnTile': false,
    'blockedWords': [],
    'blockedCommentWords': [],
    'defaultSearchTarget': null,
    'autoPageTurningInterval': 5, // in seconds
    'restReminderEnabled': false,
    'restReminderInterval': 45, // in minutes
    'readerMode': 'galleryLeftToRight', // values of [ReaderMode]
    'readerScreenPicNumberForLandscape': 1, // 1 - 5
    'readerScreenPicNumberForPortrait': 1, // 1 - 5
    'enableTapToTurnPages': true,
    'reverseTapToTurnPages': false,
    'enablePageAnimation': true,
    'language': 'system', // system, zh-CN, zh-TW, en-US
    'cacheSize': 2048, // in MB
    'downloadThreads': 5,
    // 同时下载几本（每本内部再按 downloadThreads 并发）
    'maxConcurrentDownloads': 3,
    // 下载期间挂前台服务：回到桌面/锁屏继续下，通知栏显示总进度
    'backgroundDownload': true,
    'enableLongPressToZoom': true,
    'longPressAction': 'hud', // hud, zoom —— HUD 为长按呼出快捷面板
    'longPressZoomPosition': "press", // press, center
    'enableFollowUpdateNotification': true,
    // 默认开启：本应用只通过 GitHub Release 分发 APK，没有应用商店代劳，
    // 默认关闭等于绝大多数用户永远收不到更新提示。查询失败的分支不会打扰
    // 用户（静默检查），冷启动最多发一次请求，代价可以接受。
    'checkUpdateOnStart': true,
    'limitImageWidth': true,
    'webdav': [], // empty means not configured
    "disableSyncFields": "", // "field1, field2, ..."
    'dataVersion': 0,
    'quickFavorite': null,
    'enableTurnPageByVolumeKey': true,
    'enableClockAndBatteryInfoInReader': true,
    'quickCollectImage': 'No', // No, DoubleTap, Swipe
    'authorizationRequired': false,
    'onClickFavorite': 'viewDetail', // viewDetail, read
    'enableDnsOverrides': false,
    'dnsOverrides': {},
    'enableCustomImageProcessing': false,
    'customImageProcessing': defaultCustomImageProcessing,
    'sni': true,
    'autoAddLanguageFilter': 'none', // none, chinese, english, japanese
    'comicSourceListUrl': _defaultSourceListUrl,
    'preloadImageCount': 4,
    'followUpdatesFolder': null,
    'initialPage': '0',
    'comicListDisplayMode': 'paging', // paging, continuous
    'showPageNumberInReader': true,
    'showSingleImageOnFirstPage': false,
    'enableDoubleTapToZoom': true,
    'reverseChapterOrder': false,
    'showSystemStatusBar': false,
    'comicSpecificSettings': <String, Map<String, dynamic>>{},
    'deviceSpecificSettings': <String, Map<String, dynamic>>{},
    'deviceId': '',
    'ignoreBadCertificate': false,
    'readerScrollSpeed': 1.0, // 0.5 - 3.0
    'localFavoritesFirst': true,
    'autoCloseFavoritePanel': false,
    'showChapterComments': true, // show chapter comments in reader
    'showChapterCommentsAtEnd':
        false, // show chapter comments at end of chapter
    'readerAutoTrim': 'normal', // off, conservative, normal, aggressive
    'readerWarmFilter': 0, // 0-100 护眼暖色强度
    'readerWarmFilterAuto': true, // 仅在夜间时段生效
    'privacyFavorites': false, // 收藏页隐私保护（模糊遮罩）
    'monthlyGoal': 0, // 本月阅读目标（分钟），0 表示未设置
  };

  operator [](String key) {
    return _data[key];
  }

  operator []=(String key, dynamic value) {
    _data[key] = value;
    if (key != "dataVersion") {
      notifyListeners();
    }
  }

  void setEnabledComicSpecificSettings(
    String comicId,
    String sourceKey,
    bool enabled,
  ) {
    setReaderSetting(comicId, sourceKey, "enabled", enabled);
  }

  bool isComicSpecificSettingsEnabled(String? comicId, String? sourceKey) {
    if (comicId == null || sourceKey == null) {
      return false;
    }
    return _data['comicSpecificSettings']["$comicId@$sourceKey"]?["enabled"] ==
        true;
  }

  dynamic getReaderSetting(String comicId, String sourceKey, String key) {
    if (isComicSpecificSettingsEnabled(comicId, sourceKey)) {
      var comicValue =
          _data['comicSpecificSettings']["$comicId@$sourceKey"]?[key];
      if (comicValue != null) {
        return comicValue;
      }
    }
    return getDeviceReaderSetting(key);
  }

  void setReaderSetting(
    String comicId,
    String sourceKey,
    String key,
    dynamic value,
  ) {
    (_data['comicSpecificSettings'] as Map<String, dynamic>).putIfAbsent(
      "$comicId@$sourceKey",
      () => <String, dynamic>{},
    )[key] = value;
    notifyListeners();
  }

  void resetComicReaderSettings(String key) {
    (_data['comicSpecificSettings'] as Map).remove(key);
    notifyListeners();
  }

  void setEnabledDeviceSpecificSettings(bool enabled) {
    setDeviceReaderSetting("enabled", enabled);
  }

  bool isDeviceSpecificSettingsEnabled() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isEmpty) {
      return false;
    }
    return _data['deviceSpecificSettings'][deviceId]?["enabled"] == true;
  }

  dynamic getDeviceReaderSetting(String key) {
    if (!isDeviceSpecificSettingsEnabled()) {
      return _data[key];
    }
    var deviceId = _data['deviceId'] as String;
    return _data['deviceSpecificSettings'][deviceId]?[key] ?? _data[key];
  }

  void setDeviceReaderSetting(String key, dynamic value) {
    var deviceId = _getOrCreateDeviceId();
    (_data['deviceSpecificSettings'] as Map<String, dynamic>).putIfAbsent(
      deviceId,
      () => <String, dynamic>{},
    )[key] = value;
    notifyListeners();
  }

  void resetDeviceReaderSettings() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isEmpty) {
      return;
    }
    (_data['deviceSpecificSettings'] as Map).remove(deviceId);
    notifyListeners();
  }

  String _getOrCreateDeviceId() {
    var deviceId = _data['deviceId'] as String;
    if (deviceId.isNotEmpty) {
      return deviceId;
    }
    var id = const Uuid().v4();
    _data['deviceId'] = id;
    return id;
  }

  @override
  String toString() {
    return _data.toString();
  }
}

const defaultCustomImageProcessing = '''
/**
 * Process an image
 * @param image {ArrayBuffer} - The image to process
 * @param cid {string} - The comic ID
 * @param eid {string} - The episode ID
 * @param page {number} - The page number
 * @param sourceKey {string} - The source key
 * @returns {Promise<ArrayBuffer> | {image: Promise<ArrayBuffer>, onCancel: () => void}} - The processed image
 */
async function processImage(image, cid, eid, page, sourceKey) {
    let futureImage = new Promise((resolve, reject) => {
        resolve(image);
    });
    return futureImage;
}
''';

// 不内置任何漫画源列表，避免分发第三方源带来的版权与合规风险。
// 用户需自行在「设置 → 漫画源」中添加源列表地址，或按 doc/comic_source.md 编写自己的源。
const _defaultSourceListUrl = "";
