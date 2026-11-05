part of 'settings_page.dart';

class AboutSettings extends StatefulWidget {
  const AboutSettings({super.key});

  @override
  State<AboutSettings> createState() => _AboutSettingsState();
}

class _AboutSettingsState extends State<AboutSettings> {
  bool isCheckingUpdate = false;

  /// 连点版本号的计数。7 次打开调试入口，间隔超过 3 秒重新计数。
  int _versionTaps = 0;

  DateTime _lastVersionTap = DateTime.fromMillisecondsSinceEpoch(0);

  void _onVersionTap() {
    final now = DateTime.now();
    if (now.difference(_lastVersionTap) > const Duration(seconds: 3)) {
      _versionTaps = 0;
    }
    _lastVersionTap = now;
    _versionTaps += 1;
    if (_versionTaps < 7) {
      return;
    }
    _versionTaps = 0;
    appdata.implicitData['debugUnlocked'] = true;
    appdata.writeImplicitData();
    setState(() {});
    context.showMessage(message: "Debug options enabled".tl);
  }

  /// 检查更新的统一入口：手动按钮和「启动时检查」开关共用。
  Future<void> _check([bool interactive = true]) async {
    if (isCheckingUpdate) {
      return;
    }
    setState(() {
      isCheckingUpdate = true;
    });
    await checkUpdateUi(interactive);
    if (mounted) {
      setState(() {
        isCheckingUpdate = false;
      });
    }
  }

  /// 「上次检查」的说明文字。
  ///
  /// 启动检查是静默的（没更新不弹窗），用户没法确认开关是否真的在工作，
  /// 所以把最近一次尝试摆在这里——**成功和失败都算**。如果只显示成功时间，
  /// 网络一直连不上时这里会停在一周前，看起来就是「开关没生效」。
  String _lastCheckLabel() {
    var okTs = appdata.implicitData['lastCheckUpdate'];
    var failTs = appdata.implicitData['lastCheckUpdateFailed'];
    var hasOk = okTs is int && okTs > 0;
    var hasFail = failTs is int && failTs > 0;
    if (!hasOk && !hasFail) {
      return "Checks for a new version when the app starts.".tl;
    }
    // 哪次更近就看哪次：手动检查成功会盖掉之前的失败，反之亦然。
    var failed = hasFail && (!hasOk || failTs > okTs);
    var ts = (failed ? failTs : okTs) as int;
    var ago = _agoLabel(DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(ts),
    ));
    return failed
        ? "Update check failed @time".tlParams({"time": ago})
        : "Last checked @time".tlParams({"time": ago});
  }

  /// 把时间差写成人话（「刚刚」「12 分钟前」…）。
  String _agoLabel(Duration diff) {
    if (diff.inMinutes < 1) {
      return "just now".tl;
    }
    if (diff.inMinutes < 60) {
      return "@n minutes ago".tlParams({"n": diff.inMinutes.toString()});
    }
    if (diff.inHours < 24) {
      return "@n hours ago".tlParams({"n": diff.inHours.toString()});
    }
    return "@n days ago".tlParams({"n": diff.inDays.toString()});
  }

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
            // 连点 7 次打开调试入口。设置页里不再摆「调试」分类——那不是
            // 普通用户会去的地方，白白占掉一行导航。
            GestureDetector(
              onTap: _onVersionTap,
              child: Text(
                "V$appVersionName",
                style: const TextStyle(fontSize: 16),
              ),
            ),
            const Text("ManComic 是一款免费开源的漫画阅读应用"),
            const SizedBox(height: 8),
          ],
        ).toSliver(),
        ListTile(
          contentPadding: kSettingTilePadding,
          title: Text("Check for updates".tl),
          trailing: Button.filled(
            isLoading: isCheckingUpdate,
            onPressed: _check,
            child: Text("Check".tl),
          ).fixHeight(32),
        ).toSliver(),
        _SwitchSetting(
          title: "Check for updates on startup".tl,
          settingKey: "checkUpdateOnStart",
          subtitle: _lastCheckLabel(),
          onChanged: () {
            // 打开开关就立刻跑一次：真有新版本能马上弹出来，没有也会提示，
            // 用户不必等到下次冷启动才确认这个开关到底生效没有。
            if (appdata.settings['checkUpdateOnStart'] == true) {
              _check();
            }
          },
        ).toSliver(),
        // 日志是反馈问题时的必需入口，普通用户也要够得着，所以留在「关于」。
        ListTile(
          contentPadding: kSettingTilePadding,
          title: Text("Open Log".tl),
          trailing: const Icon(Icons.arrow_right),
          onTap: () {
            context.to(() => const LogsPage());
          },
        ).toSliver(),
        ListTile(
          contentPadding: kSettingTilePadding,
          title: Text("GitHub".tl),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString(appRepoUrl);
          },
        ).toSliver(),
        if (appdata.implicitData['debugUnlocked'] == true)
          ListTile(
            contentPadding: kSettingTilePadding,
            title: Text("Debug options".tl),
            trailing: const Icon(Icons.arrow_right),
            onTap: () {
              context.to(() => const DebugPage());
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
    this.fromRelease = false,
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

  /// 版本号是否直接来自 GitHub Release（可信）。
  ///
  /// 走回退通道（发布页重定向 / 仓库里的 pubspec.yaml）时只能算「版本提示」，
  /// 它可能过期，也可能对应一个还没挂安装包的发布——所以只有可信来源才允许
  /// 回答「已是最新版本」或「安装包还没发布」。
  final bool fromRelease;
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

/// 兜底请求用的 Dio：网络不通时快速失败，不要卡住整个检查流程。
AppDio _fastDio() => AppDio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 6),
        receiveTimeout: const Duration(seconds: 8),
        headers: {"cache-time": "no"},
        validateStatus: (code) => code != null && code < 500,
      ),
    );

/// 查询最新版本。
///
/// 三级回退，任一成功即返回：
/// 1. GitHub Release API：版本号 + 安装包直链 + 大小 + 摘要，信息最全；
/// 2. releases 的 Atom 订阅源：不需要 API 配额，被限流时仍可用；
/// 3. 仓库 main 分支的 pubspec.yaml：只能拿到版本号，且可能被 CDN 缓存。
///
/// 全部失败返回 null（由调用方提示检查失败）。
Future<AppUpdateInfo?> fetchLatestVersion() async {
  var info = await _fetchFromReleaseApi();
  if (info != null) {
    return info;
  }
  info = await _fetchFromReleaseFeed();
  if (info != null) {
    return info;
  }
  return await _fetchFromPubspec();
}

/// 从 GitHub Release API 读取最新版本，同时拿到 APK 的直链、大小与摘要。
Future<AppUpdateInfo?> _fetchFromReleaseApi() async {
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
      fromRelease: true,
    );
  } catch (e, s) {
    Log.error("Check Update", "Failed to read release info: $e", s);
    return null;
  }
}

/// 从 releases 的 Atom 订阅源拿最新 tag。
///
/// GitHub API 对未认证请求按 IP 限流（每小时 60 次），国内还常常连不上；
/// 这个订阅源走网页域名、没有配额限制，也不需要跟随重定向（rhttp 适配器
/// 会强制跟随跳转，拿不到 Location 头，所以不能用 `releases/latest`）。
Future<AppUpdateInfo?> _fetchFromReleaseFeed() async {
  try {
    var res = await _fastDio().get("$appRepoUrl/releases.atom");
    if (res.statusCode != 200) {
      return null;
    }
    var tag = latestTagFromReleasesFeed(res.data.toString());
    if (tag == null) {
      return null;
    }
    var version = normalizeVersion(tag);
    if (version == null) {
      return null;
    }
    var asset = await _probeApkAsset(tag, version);
    return AppUpdateInfo(
      version: version,
      url: asset?.url ?? appReleasesUrl,
      apkSize: asset?.size ?? 0,
      fromRelease: true,
    );
  } catch (e, s) {
    Log.error("Check Update", "Failed to read release feed: $e", s);
    return null;
  }
}

/// 探测发布页里按约定命名的安装包是否存在。
///
/// 发布流程把 APK 固定命名为 `ManComic-<版本号>.apk`，所以只要知道 tag 就能
/// 推出直链。探测失败（不存在或网络不通）时返回 null，由调用方决定兜底。
Future<({String url, int size})?> _probeApkAsset(
  String tag,
  String version,
) async {
  var url = "$appRepoUrl/releases/download/$tag/ManComic-$version.apk";
  try {
    var res = await _fastDio().head<void>(
      url,
      options: Options(
        followRedirects: true,
        validateStatus: (code) => code != null && code < 400,
      ),
    );
    var length = res.headers.value(Headers.contentLengthHeader);
    return (url: url, size: int.tryParse(length ?? "") ?? 0);
  } catch (e, s) {
    Log.error("Check Update", "Failed to probe $url: $e", s);
    return null;
  }
}

/// 从仓库 main 分支的 pubspec.yaml 读取版本号。
///
/// 这条通道只用于「新版本已推送但还没发 Release」的场景：拿到版本号后再按
/// 约定探测安装包，探不到就当作检查失败——不能凭它回答「已是最新版本」，
/// 因为 CDN 缓存可能还停在旧版本上。
Future<AppUpdateInfo?> _fetchFromPubspec() async {
  var urls = [
    // raw 的缓存时间短，但带个时间戳参数更保险；jsdelivr 国内可达性好，
    // 但对 @main 的缓存可长达 12 小时，只能作为补充。
    "https://raw.githubusercontent.com/$appRepoOwner/$appRepoName/main/pubspec.yaml"
        "?t=${DateTime.now().millisecondsSinceEpoch}",
    "https://cdn.jsdelivr.net/gh/$appRepoOwner/$appRepoName@main/pubspec.yaml",
  ];
  for (var url in urls) {
    try {
      var res = await _fastDio().get(url);
      if (res.statusCode != 200) {
        continue;
      }
      var data = loadYaml(res.data.toString());
      if (data is Map && data["version"] != null) {
        var version = normalizeVersion(data["version"].toString());
        if (version == null) {
          continue;
        }
        var asset = await _probeApkAsset("v$version", version);
        return AppUpdateInfo(
          version: version,
          url: asset?.url ?? appReleasesUrl,
          apkSize: asset?.size ?? 0,
        );
      }
    } catch (e, s) {
      Log.error("Check Update", "Failed to read pubspec from $url: $e", s);
    }
  }
  return null;
}

/// 启动预热：把「查最新版本」的请求提前到启动页阶段。
///
/// 网络往返（尤其国内连 GitHub）常常要几百毫秒到几秒，原来这段时间完全
/// 串在「启动 → 等 2 秒 → 请求 → 再等 2 秒 → 弹窗」的链子里。现在请求和
/// 启动动画同时起跑，结果先存在这里，弹窗前直接取用，等于把网络耗时藏进
/// 了动画里。
///
/// 失败也没关系：[fetchLatestVersion] 内部已吞掉异常返回 null，调用方按
/// 检查失败处理。
void prewarmUpdateCheck() {
  _prewarmedFetch ??= fetchLatestVersion();
}

Future<AppUpdateInfo?>? _prewarmedFetch;

/// 检查更新并在需要时弹窗引导下载。
///
/// [showMessageIfNoUpdate] 为 false 时，没有更新（或检查失败）不打扰用户，
/// 用于应用启动时的静默检查（启动检查本身已有 24 小时节流）。
///
/// 返回「是否真正读到了远端版本信息」：网络不通、接口全挂时返回 false，
/// 调用方据此决定要不要在下次启动重试，避免失败也吃掉一整天的检查额度。
Future<bool> checkUpdateUi([bool showMessageIfNoUpdate = true]) async {
  try {
    // 启动阶段预热过的请求直接复用，避免再发一遍。
    var pending = _prewarmedFetch;
    _prewarmedFetch = null;
    var info = await (pending ?? fetchLatestVersion());
    if (info == null) {
      _recordCheckFailure();
      if (showMessageIfNoUpdate) {
        App.rootContext.showMessage(message: "Check for updates failed".tl);
      }
      return false;
    }
    // 读到远端版本才算「检查成功」：记下时间点，既用于启动检查的节流，
    // 也用于设置页的「上次检查」展示。失败时不写，交给调用方稍后重试。
    appdata.implicitData['lastCheckUpdate'] =
        DateTime.now().millisecondsSinceEpoch;
    appdata.implicitData['lastCheckUpdateVersion'] = appVersionName;
    appdata.writeImplicitData();
    if (!compareVersion(info.version, appVersionName)) {
      if (showMessageIfNoUpdate) {
        // 只有真实读到了 Release 才敢说「已是最新」；走回退通道拿到的版本号
        // 可能是 CDN 上的旧值，说「已是最新」会让人误以为更新检查坏了。
        App.rootContext.showMessage(
          message: info.fromRelease
              ? "No new version available".tl
              : "Check for updates failed".tl,
        );
      }
      return true;
    }
    // 版本号更新但 Release 里没有 APK：不弹「更新」，否则用户会跳到空的发布页。
    if (!info.hasApk) {
      if (showMessageIfNoUpdate) {
        App.rootContext.showMessage(
          message: info.fromRelease
              ? "New version found but no APK published".tl
              : "Check for updates failed".tl,
        );
      }
      return true;
    }
    showUpdateAvailableDialog(info);
    return true;
  } catch (e, s) {
    Log.error("Check Update", e.toString(), s);
    _recordCheckFailure();
    if (showMessageIfNoUpdate) {
      App.rootContext.showMessage(message: "Check for updates failed".tl);
    }
    return false;
  }
}

/// 弹出「发现新版本」卡片。
///
/// 根导航器还没就绪时直接放弃：宁可这次不弹，也不要让 `App.rootContext`
/// 的空断言把检查流程整个打崩。
void showUpdateAvailableDialog(AppUpdateInfo info) {
  var navigatorContext = App.rootNavigatorKey.currentContext;
  if (navigatorContext == null) {
    return;
  }
  showDialog(
    context: navigatorContext,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (dialogContext) => UpdateAvailableDialog(info: info),
  );
}

/// 「发现新版本」的磨砂玻璃卡片。
///
/// 原来直接套通用 ContentDialog：一个标题栏、两行说明、三个文字按钮挤在
/// 右侧，看起来像系统警告而不是「有个新版本可以装」。这里重做：
/// 渐变徽标 + 版本号「旧 → 新」对照 + 单独一行主操作。
class UpdateAvailableDialog extends StatefulWidget {
  const UpdateAvailableDialog({required this.info});

  final AppUpdateInfo info;

  @override
  State<UpdateAvailableDialog> createState() => UpdateAvailableDialogState();
}

class UpdateAvailableDialogState extends State<UpdateAvailableDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..forward();

  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final info = widget.info;

    return AnimatedBuilder(
      animation: _curve,
      builder: (context, child) {
        final t = _curve.value;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 18 * (1 - t)),
            child: Transform.scale(scale: 0.94 + 0.06 * t, child: child),
          ),
        );
      },
      child: Dialog(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 26, vertical: 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: LiquidGlass(
            borderRadius: BorderRadius.circular(28),
            opacity: isDark ? 0.9 : 0.86,
            blur: 38,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [cs.primary, cs.tertiary],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: cs.primary.withValues(alpha: 0.35),
                            blurRadius: 20,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.rocket_launch_rounded,
                        size: 26,
                        color: cs.onPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    "New version available".tl,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 版本对照：「当前的」灰、「新的」用主题色放大，一眼看出升级了什么
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        appVersionName,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: cs.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(
                          Icons.east_rounded,
                          size: 15,
                          color: cs.onSurface.withValues(alpha: 0.4),
                        ),
                      ),
                      Text(
                        info.version,
                        style: TextStyle(
                          fontSize: 24,
                          height: 1.1,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                          color: cs.primary,
                        ),
                      ),
                    ],
                  ),
                  if (info.apkSize > 0) ...[
                    const SizedBox(height: 10),
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: cs.onSurface.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: cs.onSurface.withValues(alpha: 0.12),
                            width: 0.6,
                          ),
                        ),
                        child: Text(
                          "${_toMb(info.apkSize.toDouble())} MB",
                          style: TextStyle(
                            fontSize: 11,
                            color: cs.onSurface.withValues(alpha: 0.72),
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    "The update will be downloaded and installed automatically."
                        .tl,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: cs.onSurface.withValues(alpha: 0.66),
                    ),
                  ),
                  const SizedBox(height: 18),
                  // 「取消 / 立即更新」并排，主操作给更大的权重。「在浏览器
                  // 打开」是备用路径，降级成下面一行小字，三个按钮挤一行在
                  // 窄屏上放不下。
                  Row(
                    children: [
                      Expanded(
                        child: Button.outlined(
                          height: 44,
                          onPressed: () => Navigator.pop(context),
                          child: Text("Cancel".tl),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: Button.filled(
                          height: 44,
                          onPressed: () {
                            Navigator.pop(context);
                            _downloadAndInstallUpdate(info);
                          },
                          child: Text("Update now".tl),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Center(
                    child: Button.text(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      onPressed: () {
                        Navigator.pop(context);
                        launchUrlString(info.url);
                      },
                      child: Text(
                        "Open in browser".tl,
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.onSurface.withValues(alpha: 0.55),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 下载中的磨砂玻璃卡片。
class UpdateDownloadDialog extends StatelessWidget {
  const UpdateDownloadDialog({
    required this.received,
    required this.total,
    required this.speed,
    required this.onCancel,
  });

  final double received;
  final double total;
  final double speed;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    var value = total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
    var waiting = total <= 0 && received <= 0;
    var moving = speed > 0;

    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 26, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: LiquidGlass(
          borderRadius: BorderRadius.circular(28),
          opacity: isDark ? 0.9 : 0.86,
          blur: 38,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  "Downloading update".tl.toUpperCase(),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.4,
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
                const SizedBox(height: 10),
                Center(
                  child: _DownloadRing(
                    value: value,
                    indeterminate: waiting,
                    moving: moving,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  total > 0
                      ? "${_toMb(received)} / ${_toMb(total)} MB"
                      : "${_toMb(received)} MB",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.62),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _speedLabel(speed, received, total),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withValues(alpha: 0.45),
                  ),
                ),
                const SizedBox(height: 8),
                Button.text(
                  onPressed: onCancel,
                  child: Text(
                    "Cancel".tl,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 「2.4 MB/s · ≈ 16s」。速度未知时只显示一行占位，不要空白。
  String _speedLabel(double speed, double received, double total) {
    if (speed <= 0) {
      return "······";
    }
    var text = "${_toMb(speed)} MB/s";
    if (total > 0 && total > received) {
      var seconds = ((total - received) / speed).ceil();
      text += seconds >= 60 ? " · ≈ ${(seconds / 60).ceil()} min" : " · ≈ ${seconds}s";
    }
    return text;
  }
}

/// 环形下载进度：渐变进度弧 + 弧头光点 + 呼吸光晕 + 上下浮动的箭头。
///
/// 进度回调是一段一段来的（Dio 每几百毫秒推一次），直接画会在弧上留下
/// 台阶，所以用 [TweenAnimationBuilder] 把每段跳变补成 420ms 的缓动。
class _DownloadRing extends StatefulWidget {
  const _DownloadRing({
    required this.value,
    required this.indeterminate,
    required this.moving,
  });

  final double value;
  final bool indeterminate;

  /// 是否正在实际传输：速度归零（断流重试中）时箭头停下，视觉上就是「卡住了」
  final bool moving;

  @override
  State<_DownloadRing> createState() => _DownloadRingState();
}

class _DownloadRingState extends State<_DownloadRing>
    with TickerProviderStateMixin {
  static const _size = 158.0;

  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat();

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  )..repeat();

  late final AnimationController _bob = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _spin.dispose();
    _pulse.dispose();
    _bob.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SizedBox(
      width: _size,
      height: _size,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: widget.value),
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        builder: (context, animatedValue, _) {
          return Stack(
            alignment: Alignment.center,
            children: [
              AnimatedBuilder(
                animation: Listenable.merge([_spin, _pulse]),
                builder: (context, _) {
                  return CustomPaint(
                    size: const Size.square(_size),
                    painter: _DownloadRingPainter(
                      progress: animatedValue,
                      indeterminate: widget.indeterminate,
                      spin: _spin.value,
                      pulse: _pulse.value,
                      accent: cs.primary,
                      accentAlt: cs.tertiary,
                      track: cs.onSurface.withValues(alpha: 0.09),
                    ),
                  );
                },
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedBuilder(
                    animation: _bob,
                    builder: (context, child) {
                      var t = Curves.easeInOut.transform(_bob.value);
                      return Transform.translate(
                        offset: Offset(0, widget.moving ? -3 + 6 * t : 0),
                        child: child,
                      );
                    },
                    child: Icon(
                      Icons.arrow_downward_rounded,
                      size: 20,
                      color: cs.primary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.indeterminate
                        ? "—"
                        : "${(animatedValue * 100).toStringAsFixed(0)}%",
                    style: TextStyle(
                      fontSize: widget.indeterminate ? 20 : 25,
                      height: 1.1,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.6,
                      color: cs.onSurface,
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DownloadRingPainter extends CustomPainter {
  _DownloadRingPainter({
    required this.progress,
    required this.indeterminate,
    required this.spin,
    required this.pulse,
    required this.accent,
    required this.accentAlt,
    required this.track,
  });

  final double progress;
  final bool indeterminate;
  final double spin;
  final double pulse;
  final Color accent;
  final Color accentAlt;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - 24) / 2;
    const stroke = 9.0;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // 1. 呼吸光晕：每 2.4 秒向外扩一圈再消失，让静态的环也有呼吸感
    canvas.drawCircle(
      center,
      radius + 3 + pulse * 10,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = accent.withValues(alpha: 0.28 * (1 - pulse)),
    );

    // 2. 轨道
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = track,
    );

    // 3. 进度弧：主色到第三色的渐变，圆头收口
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [accent, accentAlt, accent],
        stops: const [0.0, 0.6, 1.0],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(rect);

    if (indeterminate) {
      // 还没收到字节：一段 0.62π 的弧绕圈转，后面拖一小截淡尾
      final start = -math.pi / 2 + spin * math.pi * 2;
      canvas.drawArc(rect, start - 0.55, 0.42, false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..strokeCap = StrokeCap.round
            ..color = accent.withValues(alpha: 0.16));
      canvas.drawArc(rect, start, math.pi * 0.62, false, arcPaint);
    } else if (progress > 0.001) {
      final sweep = math.pi * 2 * progress.clamp(0.0, 1.0);
      canvas.drawArc(rect, -math.pi / 2, sweep, false, arcPaint);

      // 4. 弧头光点：外面一层模糊光晕，里面一颗实心点
      final angle = -math.pi / 2 + sweep;
      final head = center + Offset(math.cos(angle), math.sin(angle)) * radius;
      canvas.drawCircle(
        head,
        stroke * 0.95,
        Paint()
          ..color = accent.withValues(alpha: 0.45)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
      );
      canvas.drawCircle(head, stroke * 0.4, Paint()..color = accentAlt);
    }
  }

  @override
  bool shouldRepaint(_DownloadRingPainter old) {
    return old.progress != progress ||
        old.indeterminate != indeterminate ||
        old.spin != spin ||
        old.pulse != pulse ||
        old.accent != accent ||
        old.accentAlt != accentAlt ||
        old.track != track;
  }
}

/// 记录一次「没能读到远端版本」的尝试。
///
/// 只写失败时间，不动 [lastCheckUpdate]：那个字段表示「上次成功读到版本」，
/// 是 4 小时节流的基准。两者分开存，设置页才能说清「最近一次尝试是什么
/// 时候、结果是成功还是失败」。
void _recordCheckFailure() {
  appdata.implicitData['lastCheckUpdateFailed'] =
      DateTime.now().millisecondsSinceEpoch;
  appdata.writeImplicitData();
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
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (dialogContext) {
        return StatefulBuilder(builder: (context, setState) {
          dialogSetState = setState;
          return UpdateDownloadDialog(
            received: progress["received"] ?? 0,
            total: progress["total"] ?? 0,
            speed: progress["speed"] ?? 0,
            onCancel: () {
              dialogOpen = false;
              cancelToken.cancel();
              Navigator.pop(dialogContext);
            },
          );
        });
      },
    );

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
