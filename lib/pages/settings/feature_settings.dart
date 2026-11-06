part of 'settings_page.dart';

/// 功能：数据、通知、内容来源与过滤。
///
/// 原来这些散在「APP」和「探索」两个分类里：「APP」这个名字本身就说明不了
/// 里面有什么（数据备份 + 阅读报告 + 语言 + 指纹锁），而探索页显示哪些源、
/// 屏蔽哪些词又藏在「探索」下面。现在按「功能」这个语义收成一处：拿到一台
/// 新手机要搬的东西、要关掉的通知、要屏蔽的关键词，都在这一页。
class FeatureSettings extends StatefulWidget {
  const FeatureSettings({super.key});

  @override
  State<FeatureSettings> createState() => _FeatureSettingsState();
}

class _FeatureSettingsState extends State<FeatureSettings> {
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

  Future<void> _clearCache() async {
    var loadingDialog = showLoadingDialog(
      App.rootContext,
      barrierDismissible: false,
      allowCancel: false,
    );
    await CacheManager().clear();
    loadingDialog.close();
    if (!mounted) return;
    context.showMessage(message: "Cache cleared".tl);
    setState(() {});
  }

  void _setCacheLimit() {
    showInputDialog(
      context: context,
      title: "Set Cache Limit".tl,
      hintText: "Size in MB".tl,
      inputValidator: RegExp(r"^\d+$"),
      onConfirm: (value) {
        appdata.settings['cacheSize'] = int.parse(value);
        appdata.saveData();
        setState(() {});
        CacheManager().setLimitSize(appdata.settings['cacheSize']);
        return null;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("Features".tl)),
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
        // 「缓存大小」「清除缓存」「缓存上限」三行合并成一行，两件事用两个
        // 图标按钮表达：清空、改上限。占用从三行变一行。
        ListTile(
          contentPadding: kSettingTilePadding,
          title: Text("Cache".tl),
          subtitle: Text(
            "${bytesToReadableString(CacheManager().currentSize)} / "
            "${appdata.settings['cacheSize']} MB",
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: "Clear Cache".tl,
                icon: const Icon(Icons.delete_outline),
                onPressed: _clearCache,
              ),
              IconButton(
                tooltip: "Cache Limit".tl,
                icon: const Icon(Icons.tune),
                onPressed: _setCacheLimit,
              ),
            ],
          ),
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
          title: "Data Sync".tl,
          callback: () async {
            showPopUpWidget(context, const _WebdavSetting());
          },
          actionTitle: 'Set'.tl,
        ).toSliver(),
        _SettingPartTitle(
          title: "Reading & notifications".tl,
          icon: Icons.auto_stories_outlined,
        ),
        _CallbackSetting(
          title: "Yearly Report".tl,
          callback: () async {
            context.to(() => const ReadingReportPage());
          },
          actionTitle: 'Open'.tl,
        ).toSliver(),
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
        _SettingPartTitle(title: "Content".tl, icon: Icons.dns_outlined),
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
        ...contentSourceSlivers(),
        _SettingPartTitle(
          title: "Filters & keywords".tl,
          icon: Icons.filter_alt_outlined,
        ),
        ...keywordFilterSlivers(),
        _SettingPartTitle(title: "Other".tl, icon: Icons.tune_rounded),
        SelectSetting(
          title: "Initial Page".tl,
          settingKey: "initialPage",
          optionTranslation: {
            '0': "Home Page".tl,
            '1': "Explore Page".tl,
            '2': "Categories Page".tl,
            '3': "Favorites Page".tl,
          },
        ).toSliver(),
        SelectSetting(
          title: "Language".tl,
          settingKey: "language",
          optionTranslation: const {
            "system": "System",
            "zh-CN": "简体中文",
            "zh-TW": "繁體中文",
            "en-US": "English",
          },
          onChanged: () {
            App.forceRebuild();
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

class _WebdavSetting extends StatefulWidget {
  const _WebdavSetting();

  @override
  State<_WebdavSetting> createState() => _WebdavSettingState();
}

class _WebdavSettingState extends State<_WebdavSetting> {
  String url = "";
  String user = "";
  String pass = "";
  String disableSync = "";

  bool autoSync = true;

  bool isTesting = false;
  bool upload = true;

  @override
  void initState() {
    super.initState();
    if (appdata.settings['webdav'] is! List) {
      appdata.settings['webdav'] = [];
    }
    if (appdata.settings['disableSyncFields'].trim().isNotEmpty) {
      disableSync = appdata.settings['disableSyncFields'];
    }
    var configs = appdata.settings['webdav'] as List;
    if (configs.whereType<String>().length != 3) {
      return;
    }
    url = configs[0];
    user = configs[1];
    pass = configs[2];
    autoSync = appdata.implicitData['webdavAutoSync'] ?? true;
  }

  void onAutoSyncChanged(bool value) {
    setState(() {
      autoSync = value;
      appdata.implicitData['webdavAutoSync'] = value;
      appdata.writeImplicitData();
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "Webdav",
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                labelText: "URL",
                hintText: "A valid WebDav directory URL".tl,
                border: OutlineInputBorder(),
              ),
              controller: TextEditingController(text: url),
              onChanged: (value) => url = value,
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                labelText: "Username".tl,
                border: const OutlineInputBorder(),
              ),
              controller: TextEditingController(text: user),
              onChanged: (value) => user = value,
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                labelText: "Password".tl,
                border: const OutlineInputBorder(),
              ),
              controller: TextEditingController(text: pass),
              onChanged: (value) => pass = value,
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                labelText: "Skip Setting Fields (Optional)".tl,
                hintText: "field0, field1, field2, ...",
                hintStyle: TextStyle(color: Theme.of(context).hintColor),
                border: OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(Icons.help_outline),
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
                                    "See source code for available fields.".tl,
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
              controller: TextEditingController(text: disableSync),
              onChanged: (value) => disableSync = value,
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: Icon(Icons.sync),
              title: Text("Auto Sync Data".tl),
              contentPadding: EdgeInsets.zero,
              trailing: Switch(value: autoSync, onChanged: onAutoSyncChanged),
            ),
            const SizedBox(height: 12),
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
            const SizedBox(height: 16),
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
            Center(
              child: Button.filled(
                isLoading: isTesting,
                onPressed: () async {
                  var oldConfig = appdata.settings['webdav'];
                  var oldAutoSync = appdata.implicitData['webdavAutoSync'];

                  if (url.trim().isEmpty &&
                      user.trim().isEmpty &&
                      pass.trim().isEmpty) {
                    appdata.settings['webdav'] = [];
                    appdata.implicitData['webdavAutoSync'] = false;
                    appdata.writeImplicitData();
                    appdata.saveData();
                    context.showMessage(message: "Saved".tl);
                    App.rootPop();
                    return;
                  }

                  appdata.settings['webdav'] = [url, user, pass];
                  appdata.settings['disableSyncFields'] = disableSync;
                  appdata.implicitData['webdavAutoSync'] = autoSync;
                  appdata.writeImplicitData();

                  if (!autoSync) {
                    appdata.saveData();
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
                  if (testResult.error) {
                    setState(() {
                      isTesting = false;
                    });
                    appdata.settings['webdav'] = oldConfig;
                    appdata.implicitData['webdavAutoSync'] = oldAutoSync;
                    appdata.writeImplicitData();
                    appdata.saveData();
                    context.showMessage(message: testResult.errorMessage!);
                    context.showMessage(message: "Saved Failed".tl);
                  } else {
                    appdata.saveData();
                    context.showMessage(message: "Saved".tl);
                    App.rootPop();
                  }
                },
                child: Text("Continue".tl),
              ),
            ),
          ],
        ).paddingHorizontal(16),
      ),
    );
  }
}
