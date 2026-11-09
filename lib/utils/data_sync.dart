import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/webdav_url.dart' show normalizeWebdavUrl;
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/app_dio.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/ext.dart';
import 'package:webdav_client/webdav_client.dart' hide File;
import 'package:venera/utils/translations.dart';

import 'io.dart';

class DataSync with ChangeNotifier {
  DataSync._() {
    if (isEnabled) {
      downloadData();
    }
    LocalFavoritesManager().addListener(onDataChanged);
    ComicSourceManager().addListener(onDataChanged);
    if (App.isDesktop) {
      Future.delayed(const Duration(seconds: 1), () {
        var controller = WindowFrame.of(App.rootContext);
        controller.addCloseListener(_handleWindowClose);
      });
    }
  }

  void onDataChanged() {
    if (isEnabled) {
      _scheduleUpload();
    }
  }

  /// 自动上传的合并窗口。
  ///
  /// 收藏一次改动、源变一次状态都会走到这里，连着操作几下就是几次完整的
  /// 上传（每次都要重新打包一遍数据、还可能顺手把服务器上的旧档删掉）。
  /// 攒 3 秒再发一次就够了。
  Timer? _uploadDebounce;

  void _scheduleUpload() {
    _uploadDebounce?.cancel();
    _uploadDebounce = Timer(const Duration(seconds: 3), () {
      _uploadDebounce = null;
      unawaited(uploadData());
    });
  }

  /// 自动同步失败后的重试。
  ///
  /// 断网、VPN 切换、坚果云抽风都会让一次同步失败，不值得为此在主页挂一
  /// 个红点让用户自己点。退避重试几次，实在不行才把错误留在界面上。
  Timer? _retryTimer;

  int _retryCount = 0;

  static const _maxAutoRetries = 3;

  void _scheduleRetry(Future<Res<bool>> Function() action) {
    if (_retryCount >= _maxAutoRetries) {
      return;
    }
    _retryCount++;
    var delay = Duration(seconds: 30 * (1 << (_retryCount - 1)));
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      if (!isEnabled) {
        return;
      }
      unawaited(action().then((res) {
        if (res.error) {
          _scheduleRetry(action);
        }
      }));
    });
  }

  void _resetRetry() {
    _retryCount = 0;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  bool _handleWindowClose() {
    if (_isUploading) {
      _showWindowCloseDialog();
      return false;
    }
    return true;
  }

  void _showWindowCloseDialog() async {
    showLoadingDialog(
      App.rootContext,
      cancelButtonText: "Shut Down".tl,
      onCancel: () => exit(0),
      barrierDismissible: false,
      message: "Uploading data...".tl,
    );
    while (_isUploading) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    exit(0);
  }

  static DataSync? instance;

  factory DataSync() => instance ?? (instance = DataSync._());

  bool _isDownloading = false;

  bool get isDownloading => _isDownloading;

  bool _isUploading = false;

  bool get isUploading => _isUploading;

  bool _haveWaitingTask = false;

  String? _lastError;

  String? get lastError => _lastError;

  /// 最近一次同步成功（上传或下载）的时间，存在 implicitData 里。
  ///
  /// 用 implicitData 而不是 settings：settings 会跟着 WebDAV 同步到别的
  /// 设备上，那台机器的「上次同步」就会被另一台的时间覆盖。这是本机的
  /// 状态，不是配置。
  static const _lastSyncKey = 'webdavLastSyncTime';

  DateTime? get lastSyncTime {
    var value = appdata.implicitData[_lastSyncKey];
    if (value is int && value > 0) {
      return DateTime.fromMillisecondsSinceEpoch(value);
    }
    return null;
  }

  void _markSynced() {
    appdata.implicitData[_lastSyncKey] = DateTime.now().millisecondsSinceEpoch;
    appdata.writeImplicitData();
    notifyListeners();
  }

  bool get isEnabled {
    var config = appdata.settings['webdav'];
    var autoSync = appdata.implicitData['webdavAutoSync'] ?? false;
    return autoSync && config is List && config.isNotEmpty;
  }

  List<String>? _validateConfig() {
    var config = appdata.settings['webdav'];
    if (config is! List) {
      return null;
    }
    if (config.isEmpty) {
      return [];
    }
    if (config.length != 3 || config.whereType<String>().length != 3) {
      return null;
    }
    return List.from(config);
  }

  Future<Res<bool>> uploadData() async {
    if (isDownloading) return const Res(true);
    if (_haveWaitingTask) return const Res(true);
    while (isUploading) {
      _haveWaitingTask = true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _haveWaitingTask = false;
    _isUploading = true;
    _lastError = null;
    notifyListeners();
    try {
      var config = _validateConfig();
      if (config == null) {
        _lastError = 'Invalid WebDAV configuration';
        return const Res.error('Invalid WebDAV configuration');
      }
      if (config.isEmpty) {
        return const Res(true);
      }
      String url = config[0];
      String user = config[1];
      String pass = config[2];

      var client = newClient(
        normalizeWebdavUrl(url),
        user: user,
        password: pass,
        adapter: RHttpAdapter(),
      );

      try {
        appdata.settings['dataVersion']++;
        await appdata.saveData(false);
        var data = await exportAppData(
            appdata.settings['disableSyncFields'].toString().isNotEmpty
        );
        var time =
            (DateTime.now().millisecondsSinceEpoch ~/ 86400000).toString();
        var filename = time;
        filename += '-';
        filename += appdata.settings['dataVersion'].toString();
        filename += '.venera';
        var files = await client.readDir('/');
        files = files.where((e) => e.name!.endsWith('.venera')).toList();
        var old = files.firstWhereOrNull((e) => e.name!.startsWith("$time-"));
        if (old != null) {
          await client.remove(old.name!);
        }
        if (files.length >= 10) {
          files.sort((a, b) => a.name!.compareTo(b.name!));
          await client.remove(files.first.name!);
        }
        await client.write(filename, await data.readAsBytes());
        data.deleteIgnoreError();
        Log.info("Upload Data", "Data uploaded successfully");
        _resetRetry();
        _markSynced();
        return const Res(true);
      } catch (e, s) {
        Log.error("Upload Data", e, s);
        _lastError = _friendlyError(e);
        _scheduleRetry(uploadData);
        return Res.error(_lastError!);
      }
    } finally {
      _isUploading = false;
      notifyListeners();
    }
  }

  Future<Res<bool>> downloadData() async {
    if (_haveWaitingTask) return const Res(true);
    while (isDownloading || isUploading) {
      _haveWaitingTask = true;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _haveWaitingTask = false;
    _isDownloading = true;
    _lastError = null;
    notifyListeners();
    try {
      var config = _validateConfig();
      if (config == null) {
        _lastError = 'Invalid WebDAV configuration';
        return const Res.error('Invalid WebDAV configuration');
      }
      if (config.isEmpty) {
        return const Res(true);
      }
      String url = config[0];
      String user = config[1];
      String pass = config[2];

      var client = newClient(
        normalizeWebdavUrl(url),
        user: user,
        password: pass,
        adapter: RHttpAdapter(),
      );

      try {
        var files = await client.readDir('/');
        files.sort((a, b) => b.name!.compareTo(a.name!));
        var file = files.firstWhereOrNull((e) => e.name!.endsWith('.venera'));
        if (file == null) {
          throw 'No data file found';
        }
        var version =
            file.name!.split('-').elementAtOrNull(1)?.split('.').first;
        if (version != null && int.tryParse(version) != null) {
          var currentVersion = appdata.settings['dataVersion'];
          if (currentVersion != null && int.parse(version) <= currentVersion) {
            Log.info("Data Sync", 'No new data to download');
            // 「检查过了，没有新数据」也算一次成功的同步——主页那行时间
            // 表示的是「最近一次连上服务器是什么时候」。
            _markSynced();
            return const Res(true);
          }
        }
        Log.info("Data Sync", "Downloading data from WebDAV server");
        var localFile = File(FilePath.join(App.cachePath, file.name!));
        await client.read2File(file.name!, localFile.path);
        await importAppData(localFile, true);
        await localFile.delete();
        Log.info("Data Sync", "Data downloaded successfully");
        _resetRetry();
        _markSynced();
        return const Res(true);
      } catch (e, s) {
        Log.error("Data Sync", e, s);
        _lastError = _friendlyError(e);
        _scheduleRetry(downloadData);
        return Res.error(_lastError!);
      }
    } finally {
      _isDownloading = false;
      notifyListeners();
    }
  }

  /// 把底层异常翻成人话。
  ///
  /// 以前直接把 `e.toString()` 塞进界面，用户看到的是整段
  /// `DioException [unknown]: null Error: [RhttpConnectionException] ...
  /// hyper_util::client::legacy::Error(Connect, ConnectError("dns error"...))`。
  /// 既看不懂，也看不出该怎么办。原始字符串仍然完整写进日志。
  static String _friendlyError(Object e) {
    var text = e.toString();
    var lower = text.toLowerCase();
    if (lower.contains('dns') ||
        lower.contains('failed to lookup address') ||
        lower.contains('no address associated with hostname') ||
        lower.contains('connection error') ||
        lower.contains('connection refused') ||
        lower.contains('connection reset') ||
        lower.contains('timed out') ||
        lower.contains('timeout') ||
        lower.contains('network is unreachable') ||
        lower.contains('failed host lookup')) {
      return "Can't reach the WebDAV server, check the network".tl;
    }
    if (lower.contains('401') || lower.contains('unauthorized')) {
      return "WebDAV rejected the account or password".tl;
    }
    if (lower.contains('403') || lower.contains('forbidden')) {
      return "WebDAV denied access to this folder".tl;
    }
    if (lower.contains('404')) {
      return "WebDAV folder does not exist".tl;
    }
    if (lower.contains('507') || lower.contains('insufficient storage')) {
      return "WebDAV storage is full".tl;
    }
    if (text.contains('No data file found')) {
      return "The WebDAV server has no synced data yet".tl;
    }
    // 兜底：只给第一行。整段栈对用户没用，完整内容已经在日志里了。
    var firstLine = text.split('\n').first.trim();
    if (firstLine.length > 120) {
      firstLine = "${firstLine.substring(0, 120)}…";
    }
    return firstLine;
  }
}
