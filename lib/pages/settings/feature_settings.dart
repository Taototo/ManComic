part of 'settings_page.dart';

/// Content：看什么、从哪看、怎么排。
///
/// 参考 VeneraX 的分类口径——「漫画列表、源与内容过滤」。所以这一页装三件事：
/// 源本身、内容来源与关键词过滤、以及列表里缩略图的排布方式（缩略图是内容
/// 的组织形态，不是 App 的外观）。
class ExploreSettings extends StatefulWidget {
  const ExploreSettings({super.key});

  @override
  State<ExploreSettings> createState() => _ExploreSettingsState();
}

class _ExploreSettingsState extends State<ExploreSettings> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Content".tl)),
        _SettingPartTitle(title: "Comic sources".tl, icon: Icons.dns_outlined),
        // 漫画源是一个完整的管理页（源列表、导入、调试），单独一行跳过去，
        // 比在一堆开关中间塞「管理源」按钮清楚。
        ListTile(
          contentPadding: kSettingTilePadding,
          title: Text("Comic Sources".tl),
          trailing: const Icon(Icons.arrow_right),
          onTap: () {
            context.to(() => const ComicSourcePage());
          },
        ).toSliver(),
        _SettingPartTitle(
          title: "Content sources".tl,
          icon: Icons.tune_rounded,
        ),
        ...contentSourceSlivers(),
        _SettingPartTitle(title: "Filters".tl, icon: Icons.filter_alt_outlined),
        // 「屏蔽哪些词」和「从哪些源取内容」是同一件事的两面：都是在决定
        // 内容边界。
        ...keywordFilterSlivers(),
        _SettingPartTitle(
          title: "Comic tiles".tl,
          icon: Icons.grid_view_rounded,
        ),
        SelectSetting(
          title: "Display mode of comic tile".tl,
          settingKey: "comicDisplayMode",
          optionTranslation: {"detailed": "Detailed".tl, "brief": "Brief".tl},
        ).toSliver(),
        SelectSetting(
          title: "Layout mode of comic grid".tl,
          settingKey: "comicLayoutMode",
          optionTranslation: {
            "grid": "Grid Layout".tl,
            "staggered": "Staggered Layout".tl,
          },
        ).toSliver(),
        SelectSetting(
          title: "Display mode of comic list".tl,
          settingKey: "comicListDisplayMode",
          optionTranslation: {
            "paging": "Paging".tl,
            "Continuous": "Continuous".tl,
          },
        ).toSliver(),
        _SliderSetting(
          title: "Size of comic tile".tl,
          settingsIndex: "comicTileScale",
          interval: 0.05,
          min: 0.5,
          max: 1.5,
        ).toSliver(),
        _SwitchSetting(
          title: "Show favorite status on comic tile".tl,
          settingKey: "showFavoriteStatusOnTile",
        ).toSliver(),
        _SwitchSetting(
          title: "Show history on comic tile".tl,
          settingKey: "showHistoryStatusOnTile",
        ).toSliver(),
      ],
    );
  }
}

/// Data & Sync：要搬走的东西和要吃掉的空间。
///
/// 存储路径、存储占用、导入导出、WebDAV、下载并发、通知——共同点是「和这台
/// 设备上的数据有关」。下载线程原本挂在「网络」页，用户想调下载不会去点网络，
/// 放这里和存储、缓存一起才找得到。
class DataSettings extends StatefulWidget {
  const DataSettings({super.key});

  @override
  State<DataSettings> createState() => _DataSettingsState();
}

class _DataSettingsState extends State<DataSettings> {
  Future<void> _setNewStoragePath() async {
    String? result;
    if (App.isAndroid) {
      var picker = DirectoryPicker();
      result = (await picker.pickDirectory())?.path;
    } else if (App.isIOS) {
      result = await selectDirectoryIOS();
    } else {
      result = await selectDirectory();
    }
    if (result == null || !mounted) return;
    var loadingDialog = showLoadingDialog(
      App.rootContext,
      barrierDismissible: false,
      allowCancel: false,
    );
    var res = await LocalManager().setNewPath(result);
    loadingDialog.close();
    if (!mounted) return;
    if (res != null) {
      context.showMessage(message: res);
    } else {
      context.showMessage(message: "Path set successfully".tl);
      setState(() {});
    }
  }

  /// 「数据与备份」那行直接显示当前同步到哪，省得点进去才知道。
  String _syncDestinationLabel() {
    switch (resolveSyncProvider()) {
      case syncProviderQuark:
        final accountId = appdata.implicitData[quarkSyncAccountKey];
        final account = accountId is String
            ? RemoteStorageAccounts.instance.account(accountId)
            : null;
        return '${"Quark Drive".tl} · ${account?.name ?? "account unavailable".tl}';
      case syncProviderWebdav:
        return "Nutstore WebDAV".tl;
    }
    return "Off".tl;
  }

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Data & Sync".tl)),
        _SettingPartTitle(
          title: "Data & backup".tl,
          icon: Icons.storage_rounded,
        ),
        // 原来是「显示路径」+「设置新路径」两行，说的其实是同一件事。
        ListTile(
          contentPadding: kSettingTilePadding,
          title: Text("Storage Path for local comics".tl),
          subtitle: Text(LocalManager().path, softWrap: false),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: "Copy".tl,
                icon: const Icon(Icons.copy),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: LocalManager().path));
                  context.showMessage(message: "Path copied to clipboard".tl);
                },
              ),
              IconButton(
                tooltip: "Set New Storage Path".tl,
                icon: const Icon(Icons.drive_file_move_outline),
                onPressed: _setNewStoragePath,
              ),
            ],
          ),
          onTap: _setNewStoragePath,
        ).toSliver(),
        // 总数看不出谁占的空间，所以进「存储」页看分类明细。
        _CallbackSetting(
          title: "Storage".tl,
          subtitle: "Cache, app data, local comics and logs".tl,
          callback: () => context.to(() => const StorageSettings()),
          actionTitle: "Manage".tl,
        ).toSliver(),
        _CallbackSetting(
          title: "Export App Data".tl,
          callback: () async {
            var controller = showLoadingDialog(context);
            var file = await exportAppData(false);
            await saveFile(filename: "data.venera", file: file);
            controller.close();
          },
          actionTitle: 'Export'.tl,
        ).toSliver(),
        _CallbackSetting(
          title: "Import App Data".tl,
          callback: () async {
            var controller = showLoadingDialog(context);
            var file = await selectFile(ext: ['venera', 'picadata']);
            if (file != null) {
              var cacheFile = File(
                FilePath.join(App.cachePath, "import_data_temp"),
              );
              await file.saveTo(cacheFile.path);
              try {
                if (file.name.endsWith('picadata')) {
                  await importPicaData(cacheFile);
                } else {
                  await importAppData(cacheFile);
                }
              } catch (e, s) {
                Log.error("Import data", e.toString(), s);
                context.showMessage(message: "Failed to import data".tl);
              } finally {
                cacheFile.deleteIgnoreError();
                App.forceRebuild();
              }
            }
            controller.close();
          },
          actionTitle: 'Import'.tl,
        ).toSliver(),
        _CallbackSetting(
          title: "Cloud Sync".tl,
          subtitle: _syncDestinationLabel(),
          callback: () async {
            showPopUpWidget(context, const _CloudSyncSetting());
          },
          actionTitle: 'Set'.tl,
        ).toSliver(),
        _SettingPartTitle(title: "Downloads".tl, icon: Icons.download_rounded),
        _SliderSetting(
          title: "Download Threads".tl,
          settingsIndex: 'downloadThreads',
          interval: 1,
          min: 1,
          max: 16,
        ).toSliver(),
        // 「下载线程数」是单本内部的并发，下面是同时下几本，两个一起决定
        // 实际请求量，所以放在相邻位置方便一起调。
        _SliderSetting(
          title: "Concurrent downloads".tl,
          settingsIndex: 'maxConcurrentDownloads',
          interval: 1,
          min: 1,
          max: 6,
          onChanged: () {
            LocalManager().pumpQueue();
          },
        ).toSliver(),
        // 关掉它会退回「只在应用可见时下载」：切出去就可能被系统冻住。
        // 桌面端没有前台服务这回事，这个开关只对 Android 有意义。
        if (App.isAndroid)
          _SwitchSetting(
            title: "Background downloads".tl,
            subtitle: "Keep downloading when the app goes to the background".tl,
            settingKey: "backgroundDownload",
            onChanged: () {
              // 立刻生效：开着就重新探一次前台服务，关掉就摘通知
              LocalManager().pumpQueue();
            },
          ).toSliver(),
        // 前台服务 + wakelock 在原生 Android 上够用，但国内 ROM 的省电
        // 策略会把后台进程整个冻住（表现就是「切出去两分钟下载就停了」）。
        // 这里给一个入口手动放行；不是必选项，不影响其他功能。
        if (App.isAndroid)
          _CallbackSetting(
            title: "Allow background running".tl,
            subtitle:
                "Exempt from battery optimization so downloads survive in the background"
                    .tl,
            callback: () async {
              if (await DownloadBackground
                  .instance
                  .ignoringBatteryOptimizations) {
                context.showMessage(message: "Already allowed".tl);
                return;
              }
              var ok = await DownloadBackground.instance
                  .requestIgnoreBatteryOptimizations();
              if (!ok && context.mounted) {
                context.showMessage(message: "Failed to open settings".tl);
              }
            },
            actionTitle: "Allow".tl,
          ).toSliver(),
        _SettingPartTitle(
          title: "Notifications".tl,
          icon: Icons.notifications_none_rounded,
        ),
        _SwitchSetting(
          title: "Follow update notifications".tl,
          subtitle: "Notify when followed comics have new chapters".tl,
          settingKey: "enableFollowUpdateNotification",
          onChanged: () async {
            if (appdata.settings['enableFollowUpdateNotification'] == true) {
              final ok = await NotificationService.requestPermission();
              if (!ok && context.mounted) {
                context.showMessage(
                  message: "Notification permission denied".tl,
                );
              }
            }
            await BackgroundTasks.syncSchedule();
          },
        ).toSliver(),
      ],
    );
  }
}

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  String logLevelToShow = "all";

  @override
  Widget build(BuildContext context) {
    var logToShow = logLevelToShow == "all"
        ? Log.logs
        : Log.logs.where((log) => log.level.name == logLevelToShow).toList();
    return Scaffold(
      appBar: Appbar(
        title: Text("Logs".tl),
        actions: [
          IconButton(
            onPressed: () => setState(() {
              final RelativeRect position = RelativeRect.fromLTRB(
                MediaQuery.of(context).size.width,
                MediaQuery.of(context).padding.top + kToolbarHeight,
                0.0,
                0.0,
              );
              showMenu(
                context: context,
                position: position,
                items: [
                  PopupMenuItem(
                    child: Text("all"),
                    onTap: () => setState(() => logLevelToShow = "all"),
                  ),
                  PopupMenuItem(
                    child: Text("info"),
                    onTap: () => setState(() => logLevelToShow = "info"),
                  ),
                  PopupMenuItem(
                    child: Text("warning"),
                    onTap: () => setState(() => logLevelToShow = "warning"),
                  ),
                  PopupMenuItem(
                    child: Text("error"),
                    onTap: () => setState(() => logLevelToShow = "error"),
                  ),
                ],
              );
            }),
            icon: const Icon(Icons.filter_list_outlined),
          ),
          IconButton(
            tooltip: "Share".tl,
            onPressed: () => shareLog(Log().toString()),
            icon: const Icon(Icons.share_outlined),
          ),
          IconButton(
            onPressed: () => setState(() {
              final RelativeRect position = RelativeRect.fromLTRB(
                MediaQuery.of(context).size.width,
                MediaQuery.of(context).padding.top + kToolbarHeight,
                0.0,
                0.0,
              );
              showMenu(
                context: context,
                position: position,
                items: [
                  PopupMenuItem(
                    child: Text("Clear".tl),
                    onTap: () => setState(() => Log.clear()),
                  ),
                  PopupMenuItem(
                    child: Text("Share".tl),
                    onTap: () => shareLog(Log().toString()),
                  ),
                  PopupMenuItem(
                    child: Text("Disable Length Limitation".tl),
                    onTap: () {
                      Log.ignoreLimitation = true;
                      context.showMessage(
                        message: "Only valid for this run".tl,
                      );
                    },
                  ),
                  PopupMenuItem(
                    child: Text("Export".tl),
                    onTap: () => saveLog(Log().toString()),
                  ),
                ],
              );
            }),
            icon: const Icon(Icons.more_horiz),
          ),
        ],
      ),
      body: ListView.builder(
        reverse: true,
        controller: ScrollController(),
        itemCount: logToShow.length,
        itemBuilder: (context, index) {
          index = logToShow.length - index - 1;
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerHighest,
                          borderRadius: const BorderRadius.all(
                            Radius.circular(16),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(5, 0, 5, 1),
                          child: Text(logToShow[index].title),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Container(
                        decoration: BoxDecoration(
                          color: [
                            Theme.of(context).colorScheme.error,
                            Theme.of(context).colorScheme.errorContainer,
                            Theme.of(context).colorScheme.primaryContainer,
                          ][logToShow[index].level.index],
                          borderRadius: const BorderRadius.all(
                            Radius.circular(16),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(5, 0, 5, 1),
                          child: Text(
                            logToShow[index].level.name,
                            style: TextStyle(
                              color: logToShow[index].level.index == 0
                                  ? Colors.white
                                  : Colors.black,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(logToShow[index].content),
                  Text(
                    logToShow[index].time.toString().replaceAll(
                      RegExp(r"\.\w+"),
                      "",
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: logToShow[index].content),
                      );
                    },
                    child: Text("Copy".tl),
                  ),
                  const Divider(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void saveLog(String log) async {
    saveFile(data: utf8.encode(log), filename: 'log.txt');
  }

  /// 调起系统分享，**一律作为 log.txt 附件**。
  ///
  /// 以前短日志走 `shareText`：接收方拿到的是一坨没有文件名、没有换行上下文
  /// 的纯文本，微信/邮件里会被折叠成一段，几十行堆栈根本没法看，也没法转存。
  /// 走文件分享，对方看到的就是一个 log.txt，能直接下载、能拖进编辑器。
  ///
  /// 顺带也解决了 Intent 大小限制：文本分享超过 ~500KB 会被系统截断或直接
  /// 抛 TransactionTooLargeException，文件分享没有这个问题。
  void shareLog(String log) {
    if (log.isEmpty) {
      context.showMessage(message: "No logs to share".tl);
      return;
    }
    try {
      Share.shareFile(
        data: utf8.encode(log),
        filename: 'log.txt',
        mime: 'text/plain',
      );
    } catch (e) {
      Log.error("Share log failed", e.toString());
      context.showMessage(message: "Failed to share logs".tl);
    }
  }
}

class _CloudSyncSetting extends StatefulWidget {
  const _CloudSyncSetting();

  @override
  State<_CloudSyncSetting> createState() => _CloudSyncSettingState();
}

/// 数据同步设置：坚果云（WebDAV）与夸克网盘共用一套。
///
/// 同步文件（`.venera`）放在所选的网盘里，两者只有存储位置不同，版本比较、
/// 清理旧包、导入流程完全一致。夸克失效时把「同步方式」切回坚果云即可继续，
/// 不是二选一的单程票。
class _CloudSyncSettingState extends State<_CloudSyncSetting> {
  /// 坚果云官方的 WebDAV 入口，填错地址是这类同步最常见的失败原因。
  static const nutstoreUrl = "https://dav.jianguoyun.com/dav/";

  String provider = syncProviderOff;
  String url = "";
  String user = "";
  String pass = "";
  String disableSync = "";
  String quarkAccountId = "";
  String quarkDirectory = "/venera_sync/";

  bool autoSync = true;

  bool isTesting = false;
  bool upload = true;

  late final urlController = TextEditingController(text: url);
  late final userController = TextEditingController(text: user);
  late final passController = TextEditingController(text: pass);
  late final disableSyncController = TextEditingController(text: disableSync);

  @override
  void initState() {
    super.initState();
    final storedProvider = appdata.implicitData[syncProviderKey];
    provider =
        resolveSyncProvider() ??
        (storedProvider == syncProviderOff
            ? syncProviderOff
            : (_quarkAccounts.isEmpty ? syncProviderOff : syncProviderQuark));
    if (appdata.settings['webdav'] is! List) {
      appdata.settings['webdav'] = [];
    }
    if (appdata.settings['disableSyncFields'].trim().isNotEmpty) {
      disableSync = appdata.settings['disableSyncFields'];
    }
    var configs = appdata.settings['webdav'] as List;
    if (configs.whereType<String>().length == 3) {
      url = configs[0];
      user = configs[1];
      pass = configs[2];
    }
    quarkAccountId = appdata.implicitData[quarkSyncAccountKey] as String? ?? '';
    quarkDirectory =
        appdata.implicitData[quarkSyncDirectoryKey] as String? ??
        "/venera_sync/";
    autoSync = appdata.implicitData['webdavAutoSync'] ?? true;
    urlController.text = url;
    userController.text = user;
    passController.text = pass;
    disableSyncController.text = disableSync;
  }

  @override
  void dispose() {
    urlController.dispose();
    userController.dispose();
    passController.dispose();
    disableSyncController.dispose();
    super.dispose();
  }

  List<StorageAccount> get _quarkAccounts {
    final values = RemoteStorageAccounts.instance.accounts
        .where(
          (account) =>
              account.backend == StorageBackend.openlist &&
              (account.driver == 'Quark' || account.driver == 'QuarkOpen'),
        )
        .toList();
    values.sort((a, b) => a.name.compareTo(b.name));
    return values;
  }

  String? get _selectedQuarkAccountId {
    final ids = _quarkAccounts.map((account) => account.id).toSet();
    if (ids.contains(quarkAccountId)) return quarkAccountId;
    return ids.isEmpty ? null : ids.first;
  }

  void onAutoSyncChanged(bool value) {
    setState(() {
      autoSync = value;
    });
  }

  Future<void> _openAccounts() async {
    await context.to(() => StorageAccountsPage());
    if (mounted) setState(() {});
  }

  Future<void> _pickQuarkDirectory() async {
    final accountId = _selectedQuarkAccountId;
    if (accountId == null) return;
    final storage = RemoteStorageAccounts.instance;
    final store = storage.storeFor(accountId);
    final selected = await context.to<List<String>>(
      () => RemoteDirectoryPicker(
        store: store,
        initialDirectories: [quarkDirectory],
        multiSelect: false,
        disposeStore: true,
        onDisposeStore: storage.release,
      ),
    );
    if (!mounted || selected == null || selected.isEmpty) return;
    setState(() => quarkDirectory = selected.first);
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Cloud Sync".tl,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: context.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.sync_rounded, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      "Sync favorites, history and settings to Nutstore or Quark Drive. "
                              "Two destinations, one switch away from each other."
                          .tl,
                      style: ts.s12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text("Sync method".tl, style: ts.s14),
            RadioGroup<String>(
              groupValue: provider,
              onChanged: (value) {
                setState(() {
                  provider = value ?? provider;
                });
              },
              child: Column(
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Radio<String>(value: syncProviderOff),
                    title: Text("Off".tl),
                    onTap: () => setState(() => provider = syncProviderOff),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Radio<String>(value: syncProviderWebdav),
                    title: Text("Nutstore WebDAV".tl),
                    subtitle: Text("Nutstore · WebDAV".tl),
                    onTap: () => setState(() => provider = syncProviderWebdav),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Radio<String>(value: syncProviderQuark),
                    title: Text("Quark Drive".tl),
                    subtitle: Text(
                      "Uses the Quark account from cloud accounts".tl,
                    ),
                    onTap: () => setState(() => provider = syncProviderQuark),
                  ),
                ],
              ),
            ),
            if (provider == syncProviderWebdav) ...[
              const Divider(height: 24),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: context.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.cloud_outlined, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Nutstore → Account info → Security → Add app password. "
                                "Use it here, not your login password."
                            .tl,
                        style: ts.s12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                decoration: InputDecoration(
                  labelText: "URL",
                  hintText: nutstoreUrl,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.auto_fix_high),
                    tooltip: "Fill in Nutstore address".tl,
                    onPressed: () {
                      urlController.text = nutstoreUrl;
                      url = nutstoreUrl;
                    },
                  ),
                ),
                controller: urlController,
                onChanged: (value) => url = value,
              ),
              const SizedBox(height: 12),
              TextField(
                decoration: InputDecoration(
                  labelText: "Username".tl,
                  border: const OutlineInputBorder(),
                ),
                controller: userController,
                onChanged: (value) => user = value,
              ),
              const SizedBox(height: 12),
              TextField(
                decoration: InputDecoration(
                  labelText: "App password".tl,
                  border: const OutlineInputBorder(),
                ),
                controller: passController,
                onChanged: (value) => pass = value,
              ),
              const SizedBox(height: 12),
              TextField(
                decoration: InputDecoration(
                  labelText: "Skip Setting Fields (Optional)".tl,
                  hintText: "field0, field1, field2, ...",
                  hintStyle: TextStyle(color: Theme.of(context).hintColor),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.help_outline),
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: Text("Skip Setting Fields".tl),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "When sync data, skip certain setting fields, which means these won't be uploaded / override."
                                    .tl,
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      "See source code for available fields."
                                          .tl,
                                    ),
                                  ),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: IconButton(
                                      icon: const Icon(Icons.open_in_new),
                                      onPressed: () {
                                        launchUrlString(
                                          "https://github.com/venera-app/venera/blob/b08f11f6ac49bd07d34b4fcde233ed07e86efbc9/lib/foundation/appdata.dart#L138",
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                controller: disableSyncController,
                onChanged: (value) => disableSync = value,
              ),
            ],
            if (provider == syncProviderQuark) ...[
              const Divider(height: 24),
              if (_quarkAccounts.isEmpty)
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: context.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("No Quark account yet".tl),
                      const SizedBox(height: 4),
                      Text(
                        "Add a Quark account first, then come back to pick a sync folder."
                            .tl,
                        style: ts.s12,
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: _openAccounts,
                          child: Text("Add Quark account".tl),
                        ),
                      ),
                    ],
                  ),
                )
              else ...[
                InputDecorator(
                  decoration: InputDecoration(
                    labelText: "Quark account".tl,
                    border: const OutlineInputBorder(),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _selectedQuarkAccountId,
                      hint: Text("Select account".tl),
                      items: [
                        for (final account in _quarkAccounts)
                          DropdownMenuItem(
                            value: account.id,
                            child: Text(
                              account.authorizationIsKnownInvalid
                                  ? "${account.name} (${"authorization expired".tl})"
                                  : account.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => quarkAccountId = value);
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_outlined),
                  title: Text("Sync folder".tl),
                  subtitle: Text(quarkDirectory),
                  trailing: const Icon(Icons.arrow_right),
                  onTap: _pickQuarkDirectory,
                ),
                Text(
                  "Sync files are stored in this folder. If Quark stops working, switch back to Nutstore and continue."
                      .tl,
                  style: ts.s12,
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _openAccounts,
                    child: Text("Manage cloud accounts".tl),
                  ),
                ),
              ],
            ],
            if (provider != syncProviderOff) ...[
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.sync),
                title: Text("Auto Sync Data".tl),
                contentPadding: EdgeInsets.zero,
                trailing: Switch(value: autoSync, onChanged: onAutoSyncChanged),
              ),
              const SizedBox(height: 4),
              RadioGroup<bool>(
                groupValue: upload,
                onChanged: (value) {
                  setState(() {
                    upload = value ?? upload;
                  });
                },
                child: Row(
                  children: [
                    Text("Operation".tl),
                    Radio<bool>(value: true),
                    Text("Upload".tl),
                    Radio<bool>(value: false),
                    Text("Download".tl),
                  ],
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                child: autoSync
                    ? Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                "Once the operation is successful, app will automatically sync data with the server."
                                    .tl,
                              ),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(height: 16),
            ],
            Center(
              child: Button.filled(
                isLoading: isTesting,
                onPressed: _save,
                child: Text("Continue".tl),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ).paddingHorizontal(16),
      ),
    );
  }

  Future<void> _save() async {
    if (provider == syncProviderWebdav &&
        (url.trim().isEmpty || user.trim().isEmpty || pass.trim().isEmpty)) {
      context.showMessage(message: "Fill in URL, username and app password".tl);
      return;
    }
    if (provider == syncProviderQuark && _selectedQuarkAccountId == null) {
      context.showMessage(message: "Select a Quark account".tl);
      return;
    }

    final effectiveQuarkAccount = _selectedQuarkAccountId;
    if (provider == syncProviderWebdav) {
      appdata.settings['webdav'] = [url, user, pass];
      appdata.settings['disableSyncFields'] = disableSync;
    } else if (provider == syncProviderQuark) {
      appdata.implicitData[quarkSyncAccountKey] = effectiveQuarkAccount;
      appdata.implicitData[quarkSyncDirectoryKey] = quarkDirectory;
    }
    appdata.implicitData[syncProviderKey] = provider;
    appdata.implicitData['webdavAutoSync'] = provider == syncProviderOff
        ? false
        : autoSync;
    await appdata.writeImplicitData();

    if (provider == syncProviderOff || !autoSync) {
      await appdata.saveData();
      context.showMessage(message: "Saved".tl);
      App.rootPop();
      return;
    }

    setState(() {
      isTesting = true;
    });
    var testResult = upload
        ? await DataSync().uploadData()
        : await DataSync().downloadData();
    if (!mounted) return;
    if (testResult.error) {
      // 选择本身保留，只把自动同步关掉：网络抖动不该把用户刚选的网盘
      // 悄悄改回去，但也不能让每次启动都对着一个连不上的目标重试。
      setState(() {
        isTesting = false;
        autoSync = false;
      });
      appdata.implicitData['webdavAutoSync'] = false;
      await appdata.writeImplicitData();
      await appdata.saveData();
      context.showMessage(message: testResult.errorMessage!);
      context.showMessage(
        message: "Saved, but auto sync is off because the test failed".tl,
      );
    } else {
      await appdata.saveData();
      context.showMessage(message: "Saved".tl);
      App.rootPop();
    }
  }
}
