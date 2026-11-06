part of 'settings_page.dart';

/// 应用更新下载的阶段。
///
/// [ready] 表示安装包已经下载并校验完成，只等用户点「安装」。
/// 这个状态会写进 appdata：应用被杀掉再打开，仍然能把用户领回安装。
enum UpdateDownloadPhase { idle, downloading, verifying, ready, failed }

/// 已下载完成、等待安装的更新包。
class PendingUpdate {
  const PendingUpdate({
    required this.version,
    required this.path,
    required this.size,
  });

  final String version;

  final String path;

  final int size;

  String get sizeLabel => "${_toMb(size.toDouble())} MB";
}

/// 一条「待安装」记录是否还该提示用户安装。
///
/// 三个条件缺一不可：有版本号、安装包确实在、版本比当前应用新。
/// 版本号已经追平说明用户装过了（覆盖安装后重启就是这个情况），
/// 此时记录和残留的安装包都该清掉，不该再打扰。
bool shouldOfferPendingUpdate({
  required String? version,
  required String currentVersion,
  required bool fileUsable,
}) {
  if (version == null || version.isEmpty || !fileUsable) {
    return false;
  }
  return compareVersion(version, currentVersion);
}

/// 下载期间的原生前台服务。
///
/// 只做两件事：把进程提到前台优先级、在通知栏挂一条进度。真正收字节的还是这里
/// 的 Dio 循环，所以断点续传、校验、重试都不受影响。
///
/// 没有它的话，切回桌面一段时间后进程可能被系统冻结甚至回收，下载就停在那儿；
/// 有了前台服务，切桌面、锁屏都继续下，通知栏能实时看到百分比。用户从最近任务
/// 里划掉应用等于关掉 App，服务随任务结束（manifest 里 stopWithTask）。
class _ForegroundDownload {
  static const _channel = MethodChannel("venera/method_channel");

  bool _running = false;

  String _version = "";

  int _lastPercent = -1;

  int _lastPushMs = 0;

  /// 启动前台服务。非 Android 平台（桌面端、widget 测试）直接跳过。
  void start(String version) {
    if (!Platform.isAndroid || _running) {
      return;
    }
    _running = true;
    _version = version;
    _lastPercent = -1;
    _lastPushMs = 0;
    unawaited(_begin());
  }

  Future<void> _begin() async {
    // 通知权限没给的话服务照样在跑，但用户看不到进度，所以顺手问一次。
    // 被拒绝也继续下载，不让权限挡住更新。
    try {
      if (!await NotificationService.hasPermission()) {
        await NotificationService.requestPermission();
      }
    } catch (_) {}
    await _invoke("startUpdateDownloadService", {
      "title": "Downloading update".tl,
      "text": "V$_version",
      "progress": -1,
    });
  }

  /// 刷新通知栏进度。一秒一次足够，刷太快既费电也会被系统限流。
  void update(double received, double total, double speed) {
    if (!_running) {
      return;
    }
    var percent = total > 0 ? (received / total * 100).floor() : -1;
    var now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastPushMs < 1000 || percent == _lastPercent) {
      return;
    }
    _lastPercent = percent;
    _lastPushMs = now;
    var detail = <String>[
      "V$_version",
      percent >= 0 ? "$percent%" : "${_toMb(received)} MB",
      if (speed > 0) "${_toMb(speed)} MB/s",
    ].join(" · ");
    unawaited(
      _invoke("updateUpdateDownloadService", {
        "title": "Downloading update".tl,
        "text": detail,
        "progress": percent,
      }),
    );
  }

  Future<void> stop() async {
    if (!_running) {
      return;
    }
    _running = false;
    _lastPercent = -1;
    await _invoke("stopUpdateDownloadService", const {});
  }

  Future<void> _invoke(String method, Map<String, Object?> args) async {
    try {
      await _channel.invokeMethod<bool>(method, args);
    } catch (e, s) {
      Log.error("Check Update", "Background service $method failed: $e", s);
    }
  }
}

/// 应用更新的下载任务，全局唯一。
///
/// 关键点是**下载不挂在弹窗上**：进度、取消令牌、目标路径都在这里，
/// 卡片只是一个订阅者。所以把卡片收起成顶部悬浮条、或者干脆切到别的
/// 页面去读漫画，下载都照常跑；回来展开卡片，看到的是同一份进度。
class UpdateDownloadController extends ChangeNotifier {
  static const _versionKey = "pendingUpdateVersion";

  static const _sizeKey = "pendingUpdateSize";

  UpdateDownloadPhase phase = UpdateDownloadPhase.idle;

  AppUpdateInfo? info;

  double received = 0;

  double total = 0;

  double speed = 0;

  /// 卡片是否已收起为顶部悬浮条。
  bool minimized = false;

  /// 已下载待安装的包（null 表示没有）。
  PendingUpdate? pending;

  CancelToken? _cancelToken;

  bool _cancelled = false;

  /// 收到「立即安装」后可能同时被按钮和整行的点击各触发一次，
  /// 真连点两下会拉起两个系统安装框，用这个标记挡住。
  bool _installing = false;

  final _background = _ForegroundDownload();

  DialogRoute<void>? _dialogRoute;

  /// 「是否立即安装」的弹窗是否已经开着，防止启动检查和手动检查各弹一个。
  bool readyDialogOpen = false;

  bool get isDownloading =>
      phase == UpdateDownloadPhase.downloading ||
      phase == UpdateDownloadPhase.verifying;

  /// 0..1，总大小未知时返回 0（界面按「不确定」处理）。
  double get progress => total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;

  /// 开始下载并展示进度卡片。
  ///
  /// 已经在下载时不会重复开任务，只是把卡片拉回前台。
  Future<void> start(AppUpdateInfo info) async {
    if (isDownloading) {
      expand();
      return;
    }
    // 同一版本已经下好：没必要再下一遍，直接问要不要装
    var ready = pending;
    if (ready != null && ready.version == info.version) {
      showUpdateReadyDialog(ready);
      return;
    }
    // 换版本了，旧包作废，顺手清掉别占着几十兆
    if (ready != null) {
      await _discardPending();
    }

    this.info = info;
    phase = UpdateDownloadPhase.downloading;
    received = 0;
    total = info.apkSize.toDouble();
    speed = 0;
    minimized = false;
    notifyListeners();
    _openProgressDialog();

    var dir = Directory(_updateDirPath());
    var apkName = _apkFileName(info.version);
    var savePath = FilePath.join(dir.path, apkName);
    var partPath = "$savePath.part";
    var apkFile = File(savePath);
    var cancelToken = _cancelToken = CancelToken();
    _cancelled = false;

    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await _cleanOldUpdateFiles(dir, apkName);
      // 之前已经下完整了（比如上次装到一半被杀、记录丢了）：别重下几十兆
      if (await _isApkUsable(apkFile, info)) {
        var cached = PendingUpdate(
          version: info.version,
          path: savePath,
          size: await apkFile.length(),
        );
        _savePending(cached);
        phase = UpdateDownloadPhase.ready;
        minimized = false;
        speed = 0;
        notifyListeners();
        _closeProgressDialog();
        showUpdateReadyDialog(cached);
        return;
      }
      // 走到这里说明这个版本还没有完整的包，残留的半成品不能当成成品
      if (await apkFile.exists()) {
        await apkFile.delete();
      }

      // 从这里开始才真正收字节：挂前台服务，切到桌面、锁屏都不中断
      _background.start(info.version);

      for (var attempt = 0;; attempt++) {
        try {
          await _downloadApk(info, partPath, _onProgress, cancelToken);
          break;
        } on DioException catch (e) {
          if (cancelToken.isCancelled ||
              e.type == DioExceptionType.cancel ||
              _cancelled) {
            return; // 用户取消：弹窗已关，part 保留供下次续传
          }
          if (attempt >= 2) {
            rethrow;
          }
          // 断流后保留已下载部分，退避后从断点续传
          await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
          if (_cancelled) {
            return;
          }
          speed = 0;
          notifyListeners();
        }
      }
      if (_cancelled) {
        return;
      }

      phase = UpdateDownloadPhase.verifying;
      notifyListeners();

      var partFile = File(partPath);
      var length = await partFile.length();
      if (info.apkSize > 0 && length != info.apkSize) {
        throw Exception("APK size mismatch: $length != ${info.apkSize}");
      }
      var sha = info.apkSha256;
      if (sha != null && await _sha256Of(partFile) != sha) {
        await partFile.delete();
        throw Exception("APK sha256 mismatch");
      }
      await partFile.rename(savePath);
      if (_cancelled) {
        return;
      }

      var downloaded = PendingUpdate(
        version: info.version,
        path: savePath,
        size: length,
      );
      _savePending(downloaded);
      phase = UpdateDownloadPhase.ready;
      minimized = false;
      speed = 0;
      notifyListeners();
      _closeProgressDialog();
      // 下载只是完成了一半：装不装、什么时候装交给用户决定
      showUpdateReadyDialog(downloaded);
    } catch (e, s) {
      Log.error("Check Update", "Failed to download update: $e", s);
      _closeProgressDialog();
      // 校验失败说明数据不可信，直接丢弃；网络错误则保留 part 以便续传
      try {
        var partFile = File(partPath);
        if (await partFile.exists() && e.toString().contains("mismatch")) {
          await partFile.delete();
        }
      } catch (_) {}
      if (_cancelled) {
        return;
      }
      phase = UpdateDownloadPhase.failed;
      minimized = false;
      notifyListeners();
      _toast("Download failed".tl);
    } finally {
      // 成功、失败、取消都要撤掉前台服务，通知栏不能留一条僵尸进度
      await _background.stop();
    }
  }

  /// 收起大卡片，改为顶部悬浮条继续下载。
  void minimize() {
    if (!isDownloading) {
      return;
    }
    minimized = true;
    notifyListeners();
    _closeProgressDialog();
  }

  /// 从悬浮条（或关于页的下载行）展开回大卡片。
  void expand() {
    if (!isDownloading) {
      return;
    }
    minimized = false;
    notifyListeners();
    _openProgressDialog();
  }

  /// 取消下载：停止传输，保留已下载的 `.part` 供下次续传。
  void cancel() {
    if (!isDownloading) {
      return;
    }
    _cancelled = true;
    _cancelToken?.cancel();
    phase = UpdateDownloadPhase.idle;
    minimized = false;
    speed = 0;
    notifyListeners();
    _closeProgressDialog();
  }

  /// 拉起系统安装器安装已下载的包。
  Future<void> install(PendingUpdate p) async {
    if (_installing) {
      return;
    }
    _installing = true;
    try {
      if (!await File(p.path).exists()) {
        await _discardPending();
        _toast("The update package is missing, please download again".tl);
        return;
      }
      if (!await _installApk(p.path)) {
        _toast("Unable to start the installer".tl);
      }
    } finally {
      _installing = false;
    }
  }

  /// 读取并核对 appdata 里的「待安装」记录。
  ///
  /// 返回 null 表示没有可安装的包，同时会把过期记录清干净：
  /// 版本已经追平（装过了）或安装包被删了，都不该继续提示。
  /// 注意到期版本的检测必须每次启动都做，否则用户装完之后这里会一直挂着。
  Future<PendingUpdate?> resolvePendingUpdate() async {
    if (isDownloading) {
      return pending;
    }
    var version = appdata.implicitData[_versionKey];
    var size = appdata.implicitData[_sizeKey];
    if (version is! String || version.isEmpty) {
      if (pending != null) {
        pending = null;
        notifyListeners();
      }
      return null;
    }
    var path = FilePath.join(_updateDirPath(), _apkFileName(version));
    var usable = false;
    try {
      var file = File(path);
      if (await file.exists()) {
        var length = await file.length();
        usable =
            size is int && size > 0 ? length == size : length > 1024 * 1024;
      }
    } catch (e, s) {
      Log.error("Check Update", "Failed to inspect update package: $e", s);
    }
    if (!shouldOfferPendingUpdate(
      version: version,
      currentVersion: appVersionName,
      fileUsable: usable,
    )) {
      await _discardPending();
      return null;
    }
    var resolved = PendingUpdate(
      version: version,
      path: path,
      size: size is int ? size : 0,
    );
    pending = resolved;
    notifyListeners();
    return resolved;
  }

  /// 有已下载的包就弹出「是否立即安装」，返回是否真的弹了。
  bool promptPendingInstall() {
    var p = pending;
    if (p == null) {
      return false;
    }
    showUpdateReadyDialog(p);
    return true;
  }

  void _savePending(PendingUpdate p) {
    pending = p;
    appdata.implicitData[_versionKey] = p.version;
    appdata.implicitData[_sizeKey] = p.size;
    appdata.writeImplicitData();
  }

  /// 丢弃「待安装」记录和对应的安装包。
  Future<void> _discardPending() async {
    if (isDownloading) {
      return;
    }
    var version = pending?.version ?? appdata.implicitData[_versionKey];
    pending = null;
    appdata.implicitData.remove(_versionKey);
    appdata.implicitData.remove(_sizeKey);
    appdata.writeImplicitData();
    notifyListeners();
    if (version is! String || version.isEmpty) {
      return;
    }
    try {
      var apk = File(FilePath.join(_updateDirPath(), _apkFileName(version)));
      if (await apk.exists()) {
        await apk.delete();
      }
      var part = File("${apk.path}.part");
      if (await part.exists()) {
        await part.delete();
      }
    } catch (e, s) {
      Log.error("Check Update", "Failed to remove update package: $e", s);
    }
  }

  void _onProgress(int received, int total, double speed) {
    if (_cancelled || !isDownloading) {
      return;
    }
    this.received = received.toDouble();
    this.total = total.toDouble();
    this.speed = speed;
    notifyListeners();
    _background.update(this.received, this.total, speed);
  }

  void _openProgressDialog() {
    if (_dialogRoute != null) {
      return;
    }
    var ctx = App.rootNavigatorKey.currentContext;
    if (ctx == null) {
      return;
    }
    var route = DialogRoute<void>(
      context: ctx,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (dialogContext) {
        return PopScope(
          // 返回键不当「取消」：收起成悬浮条继续下载，符合用户按返回时的预期
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              minimize();
            }
          },
          child: ListenableBuilder(
            listenable: this,
            builder: (context, _) => UpdateDownloadDialog(
              received: received,
              total: total,
              speed: speed,
              onMinimize: minimize,
              onCancel: cancel,
            ),
          ),
        );
      },
    );
    _dialogRoute = route;
    Navigator.of(ctx, rootNavigator: true).push(route).whenComplete(() {
      if (identical(_dialogRoute, route)) {
        _dialogRoute = null;
      }
    });
  }

  void _closeProgressDialog() {
    var route = _dialogRoute;
    _dialogRoute = null;
    route?.navigator?.removeRoute(route);
  }
}

/// 全局唯一的更新下载任务。
final updateDownload = UpdateDownloadController();

void _toast(String message) {
  var ctx = App.rootNavigatorKey.currentContext;
  if (ctx == null || !ctx.mounted) {
    return;
  }
  ctx.showMessage(message: message);
}

/// 弹出「下载完成，是否立即安装」。
///
/// 选择「稍后安装」不会丢东西：安装包留在 `updates/` 里，关于页有安装入口，
/// 下次启动也会再问一次。
void showUpdateReadyDialog(PendingUpdate pending) {
  var ctx = App.rootNavigatorKey.currentContext;
  if (ctx == null || !ctx.mounted || updateDownload.readyDialogOpen) {
    return;
  }
  updateDownload.readyDialogOpen = true;
  showDialog(
    context: ctx,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (dialogContext) {
      return UpdateReadyDialog(
        pending: pending,
        onLater: () {
          Navigator.of(dialogContext).pop();
          _toast("You can install it later in Settings - About".tl);
        },
        onInstall: () {
          Navigator.of(dialogContext).pop();
          updateDownload.install(pending);
        },
      );
    },
  ).whenComplete(() {
    updateDownload.readyDialogOpen = false;
  });
}

/// 下载卡片收起后，浮在页面顶部的进度条。
///
/// 直接返回 [Positioned]，所以只能作为 `main.dart` 里最外层 [Stack] 的子节点：
/// 这样它浮在导航器之上，切到任何页面都看得到，也不会吃掉页面内的点击。
class UpdateDownloadBanner extends StatelessWidget {
  const UpdateDownloadBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 8,
      left: 12,
      right: 12,
      child: ListenableBuilder(
        listenable: updateDownload,
        builder: (context, _) {
          // 只有「正在下载 + 已收起」才出现：下载完成会弹安装提示，
          // 那时再挂一条悬浮条反而挡住页面。
          var visible =
              updateDownload.isDownloading && updateDownload.minimized;
          return IgnorePointer(
            ignoring: !visible,
            child: AnimatedSlide(
              offset: visible ? Offset.zero : const Offset(0, -1.6),
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              child: AnimatedOpacity(
                opacity: visible ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: _buildCard(context),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCard(BuildContext context) {
    var cs = Theme.of(context).colorScheme;
    var isDark = Theme.of(context).brightness == Brightness.dark;
    var progress = updateDownload.progress;
    var indeterminate = updateDownload.total <= 0;
    var version = updateDownload.info?.version ?? "";
    var detail = <String>[
      if (version.isNotEmpty) "V$version",
      if (indeterminate)
        "${_toMb(updateDownload.received)} MB"
      else
        "${(progress * 100).toStringAsFixed(0)}%",
      if (updateDownload.speed > 0) "${_toMb(updateDownload.speed)} MB/s",
    ].join(" · ");

    return LiquidGlass(
      borderRadius: BorderRadius.circular(22),
      opacity: isDark ? 0.92 : 0.9,
      blur: 32,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: updateDownload.expand,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
            child: Row(
              children: [
                SizedBox(
                  width: 26,
                  height: 26,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(
                          value: indeterminate ? null : progress,
                          strokeWidth: 3,
                          strokeCap: StrokeCap.round,
                          backgroundColor: cs.onSurface.withValues(alpha: 0.14),
                          valueColor: AlwaysStoppedAnimation(cs.primary),
                        ),
                      ),
                      Icon(
                        Icons.arrow_downward_rounded,
                        size: 12,
                        color: cs.primary,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "Downloading update".tl,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: cs.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.open_in_full_rounded,
                  size: 15,
                  color: cs.onSurface.withValues(alpha: 0.5),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
