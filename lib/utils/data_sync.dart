import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/window_frame.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/cloud_storage/remote_file_store.dart';
import 'package:venera/utils/data.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/translations.dart';

import 'cloud_bootstrap.dart';
import 'data_sync_storage.dart';
import 'io.dart';

/// 启动同步拉完云端之后，还要不要把本地那份推上去。
///
/// 三条规则挤在一个布尔里，单独抽出来是为了能单测：
/// - 云端更新、刚把本地覆盖掉 → 不再上传（传上去的就是刚拉下来的东西，
///   白跑一趟几十 MB，还会把 dataVersion 顶高，让别的设备以为有更新）；
/// - 云端没有更新的 → 上次留下的改动还是要推；
/// - 什么都没改 → 不上传。这条正是「一天不再传几十次」的来源。
bool shouldUploadAfterLaunch({
  required bool importedRemote,
  required bool pending,
}) => !importedRemote && pending;

class DataSync with ChangeNotifier {
  DataSync._() {
    LocalFavoritesManager().addListener(onDataChanged);
    ComicSourceManager().addListener(onDataChanged);
    if (App.isDesktop) {
      Future.delayed(const Duration(seconds: 1), () {
        var controller = WindowFrame.of(App.rootContext);
        controller.addCloseListener(_handleWindowClose);
      });
    }
  }

  /// 数据变了：只记一笔「有改动待上传」，不当场传。
  ///
  /// 以前这里是「攒 3 秒发一次整包」。收藏改一下、源变一次状态、退出阅读
  /// 页、改个设置都会走到这里，再加上 `saveData()` 里那次直传，一天下来
  /// 能往坚果云推几十份几十 MB 的包——而且每次换网/换代理都要再来一遍。
  /// 现在只写一个布尔标记，真正的自动上传收在 [syncOnLaunch] 里，
  /// 一次启动最多一次。
  void onDataChanged() {
    if (isEnabled) {
      _markPendingUpload();
    }
  }

  /// 有没有「本地改过、还没传上去」的东西。标记落盘，杀进程也不丢。
  static const _pendingKey = 'webdavPendingUpload';

  bool get hasPendingUpload => appdata.implicitData[_pendingKey] == true;

  void _markPendingUpload() {
    // 已经是 true 就别再写盘：这个函数被调用的频率和「用户操作」一样高。
    if (hasPendingUpload) {
      return;
    }
    appdata.implicitData[_pendingKey] = true;
    unawaited(appdata.writeImplicitData());
  }

  void _clearPendingUpload() {
    if (!hasPendingUpload) {
      return;
    }
    appdata.implicitData[_pendingKey] = false;
    unawaited(appdata.writeImplicitData());
  }

  /// 启动时的那一次自动同步。
  ///
  /// 顺序是「先拉后推」：云端有更新的就整份覆盖（本地那点改动本来也就
  /// 被覆盖了，再传回去没有意义）；云端没有更新的，才把上次留下的改动
  /// 推上去。整个过程一次启动一次，由 `init` 触发，运行期间不再自动发起。
  bool _launchSyncStarted = false;

  Future<void> syncOnLaunch() async {
    if (_launchSyncStarted) {
      return;
    }
    _launchSyncStarted = true;
    if (!isEnabled) {
      return;
    }
    await downloadData();
    if (!isEnabled) {
      return;
    }
    if (_importedRemote) {
      // 本地已经被云端那份覆盖，pending 也跟着作废。
      _clearPendingUpload();
    }
    if (shouldUploadAfterLaunch(
      importedRemote: _importedRemote,
      pending: hasPendingUpload,
    )) {
      await uploadData();
    }
  }

  /// 同步失败后的重试。
  ///
  /// 断网、VPN 切换、坚果云抽风都会让一次同步失败，不值得为此在主页挂一
  /// 个红点让用户自己点。退避重试几次，实在不行才把错误留在界面上。
  ///
  /// 只有「真的发起过一次同步」（启动那一次、或者用户手点）才会走到这里，
  /// 所以它不会变成「一换网就传一次」的来源。
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
      unawaited(
        action().then((res) {
          if (res.error) {
            _scheduleRetry(action);
          }
        }),
      );
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

  /// 最近一次 [downloadData] 是否真的把云端那份导进来了。
  ///
  /// 只有「导进来了」才说明本地被覆盖过；「云端没有更新的」和「根本没连上」
  /// 都不算，这两种情况下本地改动仍然需要上传。
  bool _importedRemote = false;

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
    var autoSync = appdata.implicitData['webdavAutoSync'] ?? false;
    return autoSync && hasSyncDestination;
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
    DataSyncStorage? storage;
    try {
      if (resolveSyncProvider() == syncProviderQuark) {
        // 夸克走内置内核，冷启动时同步可能抢在初始化前面。
        await CloudBootstrap.configure();
      }
      storage = createDataSyncStorage();
      if (storage == null || !storage.isConfigured) {
        return const Res(true);
      }

      try {
        appdata.settings['dataVersion']++;
        await appdata.saveData(false);
        var data = await exportAppData(
          appdata.settings['disableSyncFields'].toString().isNotEmpty,
        );
        var time = (DateTime.now().millisecondsSinceEpoch ~/ 86400000)
            .toString();
        var filename = time;
        filename += '-';
        filename += appdata.settings['dataVersion'].toString();
        filename += '.venera';
        var files = (await storage.list())
            .where((name) => name.endsWith('.venera'))
            .toList();
        var old = files.firstWhereOrNull((name) => name.startsWith("$time-"));
        if (old != null) {
          await storage.delete(old);
        }
        if (files.length >= 10) {
          files.sort((a, b) => a.compareTo(b));
          await storage.delete(files.first);
        }
        await storage.write(filename, data);
        data.deleteIgnoreError();
        Log.info("Upload Data", "Data uploaded successfully");
        _resetRetry();
        _clearPendingUpload();
        _markSynced();
        return const Res(true);
      } catch (e, s) {
        Log.error("Upload Data", e, s);
        _lastError = _friendlyError(e);
        _scheduleRetry(uploadData);
        return Res.error(_lastError!);
      }
    } finally {
      await storage?.close();
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
    _importedRemote = false;
    notifyListeners();
    DataSyncStorage? storage;
    try {
      if (resolveSyncProvider() == syncProviderQuark) {
        // 夸克走内置内核，冷启动时同步可能抢在初始化前面。
        await CloudBootstrap.configure();
      }
      storage = createDataSyncStorage();
      if (storage == null || !storage.isConfigured) {
        return const Res(true);
      }

      try {
        var files =
            (await storage.list())
                .where((name) => name.endsWith('.venera'))
                .toList()
              ..sort((a, b) => b.compareTo(a));
        var file = files.isEmpty ? null : files.first;
        if (file == null) {
          throw 'No data file found';
        }
        var version = file.split('-').elementAtOrNull(1)?.split('.').first;
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
        Log.info("Data Sync", "Downloading data from sync destination");
        var localFile = File(FilePath.join(App.cachePath, file));
        await storage.read(file, localFile.path);
        await importAppData(localFile, true);
        await localFile.delete();
        _importedRemote = true;
        // 导入过程中 `syncData()` 会顺手 saveData 一次，把 pending 标起来；
        // 那批改动来源就是云端，不该再等下一次启动推回去。
        _clearPendingUpload();
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
      await storage?.close();
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
    // 网盘（夸克）的报错本身已经是「登录失效 / 连接超时」这类可读中文，
    // 再套一层 WebDAV 的话术只会误导。
    if (e is RemoteStorageException) return e.message;
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
