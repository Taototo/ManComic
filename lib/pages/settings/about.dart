part of 'settings_page.dart';

class AboutSettings extends StatefulWidget {
  const AboutSettings({super.key});

  @override
  State<AboutSettings> createState() => _AboutSettingsState();
}

class _AboutSettingsState extends State<AboutSettings> {
  bool isCheckingUpdate = false;

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("About".tl)),
        SizedBox(
          height: 112,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(136),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image(
                image: AssetImage(AppIcon.currentAsset),
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ).paddingTop(16).toSliver(),
        Column(
          children: [
            const SizedBox(height: 8),
            Text(
              "V$appVersionName",
              style: const TextStyle(fontSize: 16),
            ),
            const Text("ManComic 是一款免费开源的漫画阅读应用"),
            const SizedBox(height: 8),
          ],
        ).toSliver(),
        ListTile(
          title: Text("Check for updates".tl),
          trailing: Button.filled(
            isLoading: isCheckingUpdate,
            child: Text("Check".tl),
            onPressed: () {
              setState(() {
                isCheckingUpdate = true;
              });
              checkUpdateUi().whenComplete(() {
                if (mounted) {
                  setState(() {
                    isCheckingUpdate = false;
                  });
                }
              });
            },
          ).fixHeight(32),
        ).toSliver(),
        _SwitchSetting(
          title: "Check for updates on startup".tl,
          settingKey: "checkUpdateOnStart",
        ).toSliver(),
        ListTile(
          title: Text("GitHub".tl),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString(appRepoUrl);
          },
        ).toSliver(),
      ],
    );
  }
}

/// 一次更新检查的结果。
class AppUpdateInfo {
  const AppUpdateInfo({
    required this.version,
    required this.url,
    this.apkSize = 0,
    this.apkSha256,
  });

  /// 纯版本号，形如 `1.4.2`（已去掉 `v` 前缀与 `+build` 后缀）。
  final String version;

  /// 更新入口：优先指向 Release 中的 APK，找不到时指向 Release 页面。
  final String url;

  /// 是否拿到了可直接下载安装的 APK 直链。
  bool get hasApk => url.toLowerCase().endsWith(".apk");

  /// APK 字节数，0 表示未知。
  final int apkSize;

  /// APK 的 SHA-256（小写十六进制），null 表示 Release 未提供摘要。
  final String? apkSha256;
}

/// 创建用于更新检查的 Dio 实例。
///
/// - 关闭网络缓存，避免读到上一次的结果
/// - 超时略放宽：国内访问 GitHub 首字节常见 1~4 秒，8 秒容易误判为失败
AppDio _updateDio() => AppDio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        headers: {"cache-time": "no"},
        validateStatus: (code) => code != null && code < 500,
      ),
    );

/// 下载更新包使用的 Dio 实例。
///
/// 大文件下载：接收超时按数据块计，30 秒足够容忍慢速网络。
AppDio _downloadDio() => AppDio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        headers: {"cache-time": "no"},
      ),
    );

/// 查询最新版本。
///
/// 依次尝试：GitHub Release -> 仓库 main 分支的 pubspec.yaml。
/// 任一成功即返回，全部失败返回 null（由调用方提示网络错误）。
Future<AppUpdateInfo?> fetchLatestVersion() async {
  var info = await _fetchFromRelease();
  if (info != null) {
    return info;
  }
  return await _fetchFromPubspec();
}

/// 从 GitHub Release 读取最新版本，同时拿到 APK 的直链、大小与摘要。
Future<AppUpdateInfo?> _fetchFromRelease() async {
  try {
    var res = await _updateDio().get(
      "https://api.github.com/repos/$appRepoOwner/$appRepoName/releases/latest",
    );
    if (res.statusCode != 200 || res.data is! Map) {
      return null;
    }
    var data = res.data as Map;
    var tag = data["tag_name"];
    if (tag is! String) {
      return null;
    }
    var version = normalizeVersion(tag);
    if (version == null) {
      return null;
    }
    var url = appReleasesUrl;
    var apkSize = 0;
    String? apkSha256;
    var assets = data["assets"];
    if (assets is List) {
      for (var asset in assets) {
        if (asset is! Map) {
          continue;
        }
        var name = asset["name"];
        var downloadUrl = asset["browser_download_url"];
        if (name is String &&
            name.toLowerCase().endsWith(".apk") &&
            downloadUrl is String) {
          url = downloadUrl;
          var size = asset["size"];
          if (size is int) {
            apkSize = size;
          }
          // GitHub 为 release 资产提供 digest 字段，形如 sha256:xxx
          var digest = asset["digest"];
          if (digest is String && digest.toLowerCase().startsWith("sha256:")) {
            apkSha256 = digest.substring(7).toLowerCase();
          }
          break;
        }
      }
    }
    if (url == appReleasesUrl && data["html_url"] is String) {
      url = data["html_url"] as String;
    }
    return AppUpdateInfo(
      version: version,
      url: url,
      apkSize: apkSize,
      apkSha256: apkSha256,
    );
  } catch (e, s) {
    Log.error("Check Update", "Failed to read release info: $e", s);
    return null;
  }
}

/// 从仓库 main 分支的 pubspec.yaml 读取版本号。
///
/// 这条回退只用于「新版本已推送但还没发 Release」的场景，
/// 返回值不带 APK 直链，调用方据此不弹更新提示（避免点了却下载不到）。
Future<AppUpdateInfo?> _fetchFromPubspec() async {
  var urls = [
    // jsdelivr 在部分网络环境下比 raw 更易访问，放在前面做首选重试
    "https://cdn.jsdelivr.net/gh/$appRepoOwner/$appRepoName@main/pubspec.yaml",
    "https://raw.githubusercontent.com/$appRepoOwner/$appRepoName/main/pubspec.yaml",
  ];
  for (var url in urls) {
    try {
      var res = await _updateDio().get(url);
      if (res.statusCode != 200) {
        continue;
      }
      var data = loadYaml(res.data.toString());
      if (data is Map && data["version"] != null) {
        var version = normalizeVersion(data["version"].toString());
        if (version != null) {
          return AppUpdateInfo(version: version, url: appReleasesUrl);
        }
      }
    } catch (e, s) {
      Log.error("Check Update", "Failed to read pubspec from $url: $e", s);
    }
  }
  return null;
}

/// 检查更新并在需要时弹窗引导下载。
///
/// [showMessageIfNoUpdate] 为 false 时，没有更新（或检查失败）不打扰用户，
/// 用于应用启动时的静默检查（启动检查本身已有 24 小时节流）。
Future<void> checkUpdateUi(
    [bool showMessageIfNoUpdate = true, bool delay = false]) async {
  try {
    var info = await fetchLatestVersion();
    if (info == null) {
      if (showMessageIfNoUpdate) {
        App.rootContext.showMessage(message: "Check for updates failed".tl);
      }
      return;
    }
    if (!compareVersion(info.version, appVersionName)) {
      if (showMessageIfNoUpdate) {
        App.rootContext.showMessage(message: "No new version available".tl);
      }
      return;
    }
    // 版本号更新但 Release 里没有 APK：不弹「更新」，否则用户会跳到空的发布页。
    if (!info.hasApk) {
      if (showMessageIfNoUpdate) {
        App.rootContext.showMessage(
          message: "New version found but no APK published".tl,
        );
      }
      return;
    }
    if (delay) {
      await Future.delayed(const Duration(seconds: 2));
    }
    showDialog(
        context: App.rootContext,
        builder: (context) {
          return ContentDialog(
            title: "New version available".tl,
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Found new version @version, current version @current."
                      .tlParams({
                    "version": info.version,
                    "current": appVersionName,
                  }),
                ),
                Text(
                  "The update will be downloaded and installed automatically."
                      .tl,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
              ],
            ).paddingHorizontal(16),
            actions: [
              Button.text(
                onPressed: () => Navigator.pop(context),
                child: Text("Cancel".tl),
              ),
              Button.text(
                onPressed: () {
                  Navigator.pop(context);
                  launchUrlString(info.url);
                },
                child: Text("Open in browser".tl),
              ),
              Button.filled(
                onPressed: () {
                  Navigator.pop(context);
                  _downloadAndInstallUpdate(info);
                },
                child: Text("Update now".tl),
              ),
            ],
          );
        });
  } catch (e, s) {
    Log.error("Check Update", e.toString(), s);
    if (showMessageIfNoUpdate) {
      App.rootContext.showMessage(message: "Check for updates failed".tl);
    }
  }
}

/// 应用内更新包的存放目录：`<dataPath>/updates/`，
/// 与 Android 侧 FileProvider 的 `files-path` 覆盖范围对应。
String _updateDirPath() => FilePath.join(App.dataPath, "updates");

String _apkFileName(String version) => "ManComic-$version.apk";

String _toMb(double bytes) => (bytes / 1048576).toStringAsFixed(1);

/// 通过原生通道拉起系统安装器安装 [apkPath]。
Future<bool> _installApk(String apkPath) async {
  try {
    return await const MethodChannel("venera/method_channel")
            .invokeMethod("installApk", {"path": apkPath}) ==
        true;
  } catch (e, s) {
    Log.error("Check Update", "Failed to launch installer: $e", s);
    return false;
  }
}

Future<String> _sha256Of(File file) async {
  var digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

/// 清理历史更新包，只保留当前版本的文件（apk 与未完成的 part）。
Future<void> _cleanOldUpdateFiles(Directory dir, String keepName) async {
  try {
    await for (var entity in dir.list()) {
      if (entity is! File) {
        continue;
      }
      var name = entity.uri.pathSegments.last;
      if (!name.startsWith("ManComic-")) {
        continue;
      }
      if (name == keepName || name == "$keepName.part") {
        continue;
      }
      await entity.delete();
    }
  } catch (e, s) {
    Log.error("Check Update", "Failed to clean old update files: $e", s);
  }
}

/// 判断已下载的安装包是否完整可用。
///
/// 优先比对 Release 给出的字节数与 SHA-256，两者都没有时退化为大小下限判断。
Future<bool> _isApkUsable(File file, AppUpdateInfo info) async {
  if (!await file.exists()) {
    return false;
  }
  var length = await file.length();
  if (info.apkSize > 0) {
    if (length != info.apkSize) {
      return false;
    }
  } else if (length < 1024 * 1024) {
    return false;
  }
  var expected = info.apkSha256;
  if (expected != null) {
    try {
      return await _sha256Of(file) == expected;
    } catch (_) {
      return false;
    }
  }
  return true;
}

/// 带断点续传的单次下载：已有 part 文件时用 Range 头接着下。
Future<void> _downloadApk(
  AppUpdateInfo info,
  String partPath,
  void Function(int received, int total, double speed) onProgress,
  CancelToken cancelToken,
) async {
  var part = File(partPath);
  var existing = await part.exists() ? await part.length() : 0;
  var headers = <String, dynamic>{"cache-time": "no"};
  if (existing > 0) {
    headers["Range"] = "bytes=$existing-";
  }
  var res = await _downloadDio().get<ResponseBody>(
    info.url,
    options: Options(responseType: ResponseType.stream, headers: headers),
    cancelToken: cancelToken,
  );
  var statusCode = res.statusCode ?? 0;
  if (statusCode != 200 && statusCode != 206) {
    throw Exception("HTTP $statusCode");
  }
  var body = res.data!;
  // 服务端不支持 Range 时会返回 200，此时必须从头写
  var resuming = statusCode == 206 && existing > 0;
  var start = resuming ? existing : 0;
  var contentLength = int.tryParse(
      body.headers[Headers.contentLengthHeader]?.first ?? "");
  int total;
  if (contentLength != null && contentLength >= 0) {
    total = start + contentLength;
  } else {
    total = info.apkSize;
  }
  var received = start;
  var sink = part.openWrite(mode: resuming ? FileMode.append : FileMode.write);
  var lastTick = DateTime.now();
  var lastReceived = received;
  try {
    await for (var chunk in body.stream) {
      sink.add(chunk);
      received += chunk.length;
      var now = DateTime.now();
      var elapsed = now.difference(lastTick).inMilliseconds;
      if (elapsed >= 300) {
        onProgress(
            received, total, (received - lastReceived) / (elapsed / 1000));
        lastTick = now;
        lastReceived = received;
      }
    }
    onProgress(received, total, 0);
  } finally {
    await sink.flush();
    await sink.close();
  }
}

/// 下载并安装新版本。
///
/// 流程：清理历史包 -> 复用已完成的包 -> 断点续传下载（最多重试 2 次）
/// -> 校验大小与 SHA-256 -> 改名并拉起系统安装器。
Future<void> _downloadAndInstallUpdate(AppUpdateInfo info) async {
  var dir = Directory(_updateDirPath());
  var apkName = _apkFileName(info.version);
  var savePath = FilePath.join(dir.path, apkName);
  var partPath = "$savePath.part";
  var apkFile = File(savePath);
  var cancelToken = CancelToken();
  var dialogOpen = false;
  var progress = <String, double>{};
  void Function(void Function())? dialogSetState;

  Future<void> closeDialog() async {
    if (!dialogOpen) {
      return;
    }
    dialogOpen = false;
    if (App.rootContext.mounted) {
      Navigator.of(App.rootContext, rootNavigator: true).pop();
    }
  }

  try {
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    await _cleanOldUpdateFiles(dir, apkName);

    if (await _isApkUsable(apkFile, info)) {
      // 之前已下载完整（且校验通过），直接拉起安装器
      if (!await _installApk(savePath)) {
        launchUrlString(info.url);
      }
      return;
    }
    if (await apkFile.exists()) {
      await apkFile.delete();
    }

    dialogOpen = true;
    showDialog(
        context: App.rootContext,
        barrierDismissible: false,
        builder: (dialogContext) {
          return StatefulBuilder(builder: (context, setState) {
            dialogSetState = setState;
            var received = progress["received"] ?? 0;
            var total = progress["total"] ?? 0;
            var speed = progress["speed"] ?? 0;
            Widget content;
            if (received <= 0) {
              content = const SizedBox(
                height: 48,
                child: Center(child: CircularProgressIndicator()),
              );
            } else {
              var value = total > 0 ? received / total : 0.0;
              content = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: total > 0 ? value : null),
                  const SizedBox(height: 8),
                  Text(
                    total > 0
                        ? "${(value * 100).toStringAsFixed(1)}%   "
                            "${_toMb(received)} / ${_toMb(total)} MB"
                        : "${_toMb(received)} MB",
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (speed > 0)
                    Text(
                      "${_toMb(speed)} MB/s",
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                    ),
                ],
              );
            }
            return ContentDialog(
              title: "Downloading update".tl,
              content: content,
              actions: [
                Button.text(
                  onPressed: () {
                    dialogOpen = false;
                    cancelToken.cancel();
                    Navigator.pop(dialogContext);
                  },
                  child: Text("Cancel".tl),
                ),
              ],
            );
          });
        });

    for (var attempt = 0;; attempt++) {
      try {
        await _downloadApk(
          info,
          partPath,
          (received, total, speed) {
            dialogSetState?.call(() {
              progress["received"] = received.toDouble();
              progress["total"] = total.toDouble();
              progress["speed"] = speed;
            });
          },
          cancelToken,
        );
        break;
      } on DioException catch (e) {
        if (cancelToken.isCancelled || e.type == DioExceptionType.cancel) {
          return; // 用户取消：弹窗已关闭，part 文件保留供下次续传
        }
        if (attempt >= 2) {
          rethrow;
        }
        // 断流后保留已下载部分，退避后从断点续传
        await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
        dialogSetState?.call(() {
          progress["speed"] = 0;
        });
      }
    }

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
    await closeDialog();

    App.rootContext.showMessage(message: "Update downloaded".tl);
    if (!await _installApk(savePath)) {
      App.rootContext.showMessage(
        message: "Unable to start the installer".tl,
      );
      launchUrlString(info.url);
    }
  } catch (e, s) {
    Log.error("Check Update", "Failed to download update: $e", s);
    await closeDialog();
    // 校验失败说明数据不可信，直接丢弃；网络错误则保留 part 以便续传
    try {
      var partFile = File(partPath);
      if (await partFile.exists() && e.toString().contains("mismatch")) {
        await partFile.delete();
      }
    } catch (_) {}
    App.rootContext.showMessage(message: "Download failed".tl);
  }
}
