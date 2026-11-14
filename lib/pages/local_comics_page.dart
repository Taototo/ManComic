import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/downloading_card.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/local_insights.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/download.dart';
import 'package:venera/pages/downloading_page.dart';
import 'package:venera/pages/favorites/favorites_page.dart';
import 'package:venera/pages/local_comic_page.dart';
import 'package:venera/pages/missing_chapters_page.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/epub.dart';
import 'package:venera/utils/haptics.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/pdf.dart';
import 'package:venera/utils/translations.dart';
import 'package:zip_flutter/zip_flutter.dart';
import 'package:url_launcher/url_launcher_string.dart';

class LocalComicsPage extends StatefulWidget {
  const LocalComicsPage({super.key});

  @override
  State<LocalComicsPage> createState() => _LocalComicsPageState();
}

class _LocalComicsPageState extends State<LocalComicsPage> {
  late List<LocalComic> comics;

  late LocalSortType sortType;

  String keyword = "";

  bool searchMode = false;

  bool multiSelectMode = false;

  Map<LocalComic, bool> selectedComics = {};

  void update() {
    if (keyword.isEmpty) {
      setState(() {
        comics = LocalManager().getComics(sortType);
      });
    } else {
      setState(() {
        comics = LocalManager().search(keyword);
      });
    }
    // 本地库变动（下完一本、删一本）之后顺手补一轮更新检查。内部有 TTL
    // 和每轮上限，重复调用不会变成连续请求。
    LocalInsights().autoCheck(comics);
  }

  @override
  void initState() {
    var sort = appdata.implicitData["local_sort"] ?? "name";
    sortType = LocalSortType.fromString(sort);
    comics = LocalManager().getComics(sortType);
    LocalManager().addListener(update);
    super.initState();
    // 首帧之后再发请求：进页面先出列表，角标晚几秒到不影响。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        LocalInsights().autoCheck(comics);
      }
    });
  }

  @override
  void dispose() {
    LocalManager().removeListener(update);
    super.dispose();
  }

  void sort() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return ContentDialog(
              title: "Sort".tl,
              content: RadioGroup<LocalSortType>(
                groupValue: sortType,
                onChanged: (v) {
                  setState(() {
                    sortType = v ?? sortType;
                  });
                },
                child: Column(
                  children: [
                    RadioListTile<LocalSortType>(
                      title: Text("Name".tl),
                      value: LocalSortType.name,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Name A-Z".tl),
                      value: LocalSortType.titleAZ,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Date".tl),
                      value: LocalSortType.timeAsc,
                    ),
                    RadioListTile<LocalSortType>(
                      title: Text("Date Desc".tl),
                      value: LocalSortType.timeDesc,
                    ),
                  ],
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () {
                    appdata.implicitData["local_sort"] = sortType.value;
                    appdata.writeImplicitData();
                    Navigator.pop(context);
                    update();
                  },
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// 手动查一轮更新。
  ///
  /// 进页面时已经自动查过一批（带 TTL、每轮上限），这颗按钮是「我现在就想
  /// 知道」——所以忽略 TTL，把整页都查一遍。
  Future<void> _checkUpdates() async {
    final targets = comics
        .where((c) => LocalInsights().isCheckable(c))
        .toList();
    if (targets.isEmpty) {
      context.showMessage(message: "No comics to check".tl);
      return;
    }
    var canceled = false;
    final controller = showLoadingDialog(
      context,
      message: "Checking updates".tl,
      withProgress: true,
      onCancel: () => canceled = true,
    );
    final result = await LocalInsights().checkAll(
      targets,
      force: true,
      onProgress: (done, total) {
        if (canceled || controller.closed) {
          return;
        }
        controller.setMessage("${"Checking updates".tl} $done/$total");
        controller.setProgress(total == 0 ? null : done / total);
      },
    );
    controller.close();
    if (!mounted || canceled) {
      return;
    }
    if (result.failed == targets.length && result.checked > 0) {
      context.showMessage(message: "Failed to check updates".tl);
    } else if (result.updated > 0) {
      context.showMessage(
        message: "@n comics have updates".tlParams({"n": result.updated}),
      );
    } else {
      context.showMessage(message: "No updates found".tl);
    }
  }

  Widget buildMultiSelectMenu() {
    return MenuButton(
      entries: [
        MenuEntry(
          icon: Icons.delete_outline,
          text: "Delete".tl,
          onClick: () {
            deleteComics(selectedComics.keys.toList()).then((value) {
              if (value) {
                setState(() {
                  multiSelectMode = false;
                  selectedComics.clear();
                });
              }
            });
          },
        ),
        MenuEntry(
          icon: Icons.favorite_border,
          text: "Add to favorites".tl,
          onClick: () {
            addFavorite(selectedComics.keys.toList());
          },
        ),
        if (selectedComics.length == 1)
          MenuEntry(
            icon: Icons.folder_open,
            text: "Open Folder".tl,
            onClick: () {
              openComicFolder(selectedComics.keys.first);
            },
          ),
        if (selectedComics.length == 1)
          MenuEntry(
            icon: Icons.chrome_reader_mode_outlined,
            text: "View Detail".tl,
            onClick: () {
              LocalComicPage.open(context, selectedComics.keys.first);
            },
          ),
        if (selectedComics.isNotEmpty)
          ...exportActions(selectedComics.keys.toList()),
      ],
    );
  }

  void selectAll() {
    setState(() {
      selectedComics = comics.asMap().map((k, v) => MapEntry(v, true));
    });
  }

  void deSelect() {
    setState(() {
      selectedComics.clear();
    });
  }

  void invertSelection() {
    setState(() {
      comics.asMap().forEach((k, v) {
        selectedComics[v] = !selectedComics.putIfAbsent(v, () => false);
      });
      selectedComics.removeWhere((k, v) => !v);
    });
  }

  /// 网格展示还是详情行。
  ///
  /// 本地漫画的信息（体积、进度、更新角标）在行里排得下，但一眼扫"我下了哪些
  /// 本"还是封面墙更快——收藏页能切，这里凭什么不能。默认保持原来的详情行，
  /// 老用户升级上来观感不变。
  bool get gridMode => appdata.settings['localComicsLayout'] == 'grid';

  void toggleLayout() {
    appdata.settings['localComicsLayout'] = gridMode ? 'list' : 'grid';
    appdata.saveData();
    setState(() {});
  }

  void openOrSelect(LocalComic comic, int index) {
    if (multiSelectMode) {
      setState(() {
        if (selectedComics.containsKey(comic)) {
          selectedComics.remove(comic);
        } else {
          selectedComics[comic] = true;
        }
        if (selectedComics.isEmpty) {
          multiSelectMode = false;
        }
      });
    } else {
      // 点封面进详情页，不再一步跳进阅读器：简介、章节、来源都在详情页上，
      // 想直接读点「开始阅读」也只多一下。
      LocalComicPage.open(context, comic, heroID: index);
    }
  }

  /// 一本书的长按菜单。列表和网格共用同一份，不然两处会慢慢长歪。
  List<MenuEntry> buildComicMenu(LocalComic comic) {
    return [
      MenuEntry(
        icon: Icons.folder_open,
        text: "Open Folder".tl,
        onClick: () {
          openComicFolder(comic);
        },
      ),
      if (comic.comicType.comicSource?.loadComicPages != null)
        MenuEntry(
          icon: Icons.fact_check_outlined,
          text: "Check missing chapters".tl,
          onClick: () {
            MissingChaptersPage.show(context, comic);
          },
        ),
      MenuEntry(
        icon: Icons.delete,
        text: "Delete".tl,
        onClick: () {
          deleteComics([comic]).then((value) {
            if (value && multiSelectMode) {
              setState(() {
                multiSelectMode = false;
                selectedComics.clear();
              });
            }
          });
        },
      ),
      ...exportActions([comic]),
    ];
  }

  /// 封面墙。列数按屏宽算：132 是「每列至少这么宽」的下限。
  ///
  /// 用 round 而不是 floor：390/132 = 2.95，floor 会砍成 2 列，手机上一排
  /// 只有两张封面。平板自然落到 5~6 列，不用另开一档。
  Widget _buildGrid(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final cols = (width / 132).round().clamp(2, 6);
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          mainAxisSpacing: 14,
          crossAxisSpacing: 10,
          childAspectRatio: 0.58,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final comic = comics[index];
          return _LocalComicGridTile(
            key: ValueKey("grid:${comic.comicType.value}:${comic.id}"),
            comic: comic,
            heroID: index,
            selected: selectedComics.containsKey(comic),
            selecting: multiSelectMode,
            onTap: () => openOrSelect(comic, index),
            onLongPress: () {
              setState(() {
                multiSelectMode = true;
                selectedComics[comic] = true;
              });
            },
            menu: buildComicMenu(comic),
          );
        }, childCount: comics.length),
      ),
    );
  }

  /// 顶栏行高。和收藏页顶栏（`NaviPane` 里那个 48）同档。
  static const _kTopBarHeight = 48.0;

  void onLeadingPressed() {
    if (multiSelectMode) {
      setState(() {
        multiSelectMode = false;
        selectedComics.clear();
      });
    } else if (searchMode) {
      setState(() {
        searchMode = false;
        keyword = "";
        update();
      });
    } else {
      context.pop();
    }
  }

  /// 收藏页同款玻璃。
  ///
  /// 参数照抄 `NaviPane.buildTop()`：同一档底色（`barTintAlpha`），同样压低
  /// 边缘高光——顶栏只有下沿露在屏幕里，高光留着就是沿交界画一条白线。
  ///
  /// 用的 `LiquidGlassBar` 默认走 premium 档，和收藏页一致。premium 每帧
  /// 重新采背景，不依赖「进页面那一刻的快照」，所以 push 进来的独立页面
  /// 也不会出现整条玻璃采不到背景的情况。
  Widget _buildTopBar(BuildContext context, List<Widget> actions) {
    final isDark = context.brightness == Brightness.dark;
    final topInset = context.padding.top;
    return LiquidGlassBar(
      lightIntensity: isDark ? 0.16 : 0.45,
      fresnelStrength: 0.35,
      tintAlpha: LiquidGlassEngine.barTintAlpha,
      child: SizedBox(
        height: topInset + _kTopBarHeight,
        width: double.infinity,
        child: Padding(
          padding: EdgeInsets.only(top: topInset, left: 4, right: 8),
          child: Row(
            children: [
              Tooltip(
                message: multiSelectMode || searchMode
                    ? "Cancel".tl
                    : "Back".tl,
                child: IconButton(
                  onPressed: onLeadingPressed,
                  icon: Icon(
                    multiSelectMode || searchMode
                        ? Icons.close
                        : Icons.arrow_back,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: _buildTopTitle(context)),
              ...actions,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopTitle(BuildContext context) {
    const style = TextStyle(fontSize: 18, fontWeight: FontWeight.bold);
    if (multiSelectMode) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(selectedComics.length.toString(), style: style),
      );
    }
    if (searchMode) {
      return TextField(
        autofocus: true,
        style: const TextStyle(fontSize: 16),
        decoration: InputDecoration(
          hintText: "Search".tl,
          isDense: true,
          border: InputBorder.none,
        ),
        onChanged: (v) {
          keyword = v;
          update();
        },
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Text("Local".tl, style: style),
    );
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> selectActions = [
      IconButton(
        icon: const Icon(Icons.select_all),
        tooltip: "Select All".tl,
        onPressed: selectAll,
      ),
      IconButton(
        icon: const Icon(Icons.deselect),
        tooltip: "Deselect".tl,
        onPressed: deSelect,
      ),
      IconButton(
        icon: const Icon(Icons.flip),
        tooltip: "Invert Selection".tl,
        onPressed: invertSelection,
      ),
      buildMultiSelectMenu(),
    ];

    List<Widget> normalActions = [
      Tooltip(
        message: "Check updates".tl,
        child: IconButton(
          icon: const Icon(Icons.sync),
          onPressed: _checkUpdates,
        ),
      ),
      Tooltip(
        message: "Search".tl,
        child: IconButton(
          icon: const Icon(Icons.search),
          onPressed: () {
            setState(() {
              searchMode = true;
            });
          },
        ),
      ),
      Tooltip(
        message: "Sort".tl,
        child: IconButton(icon: const Icon(Icons.sort), onPressed: sort),
      ),
      Tooltip(
        message: "Downloading".tl,
        child: IconButton(
          icon: const Icon(Icons.download),
          onPressed: () {
            showPopUpWidget(context, const DownloadingPage());
          },
        ),
      ),
      Tooltip(
        message: gridMode ? "List view".tl : "Grid view".tl,
        child: IconButton(
          icon: Icon(
            gridMode ? Icons.view_agenda_outlined : Icons.grid_view_rounded,
          ),
          onPressed: toggleLayout,
        ),
      ),
    ];

    final actions = multiSelectMode
        ? selectActions
        : (searchMode ? const <Widget>[] : normalActions);

    var body = Scaffold(
      body: Stack(
        children: [
          const GlassPageBackdrop(),
          SmoothCustomScrollView(
            slivers: [
              // 顶栏不在滚动视图里：它是叠在内容上的一层，一直贴在状态栏
              // 下沿，列表滚上来时从玻璃后面经过——收藏页就是这个观感。
              //
              // 留白必须付在滚动容器**内部**：付在外面（给 Stack 加 padding）
              // 等于把整块内容往下推，内容永远滚不到玻璃底下，"穿过去"就
              // 没了。这里 `padding.top` 只是状态栏高度，顶栏那 48 得自己加。
              SliverToBoxAdapter(
                child: SizedBox(height: context.padding.top + _kTopBarHeight),
              ),
              if (!searchMode && LocalManager().downloadingTasks.isNotEmpty)
                // 不能加 const：任务数变化时父级 setState 会重建这棵树，但如果
                // widget 实例相同（const），Flutter 会跳过子树更新，横条就会
                // 停在第一次渲染时的任务数上。
                SliverToBoxAdapter(child: _DownloadingSection()),
              if (comics.isEmpty)
                SliverToBoxAdapter(
                  child: _LocalEmptyHint(hasKeyword: keyword.isNotEmpty),
                )
              else if (gridMode)
                _buildGrid(context)
              else
                SliverList.builder(
                  itemCount: comics.length,
                  itemBuilder: (context, index) {
                    final comic = comics[index];
                    return _LocalComicTile(
                      key: ValueKey("${comic.comicType.value}:${comic.id}"),
                      comic: comic,
                      heroID: index,
                      selected: selectedComics.containsKey(comic),
                      selecting: multiSelectMode,
                      onTap: () => openOrSelect(comic, index),
                      onLongPress: () {
                        setState(() {
                          multiSelectMode = true;
                          selectedComics[comic] = true;
                        });
                      },
                      // 点整行就是进详情页，这里不再放「View Detail」。
                      // 多选菜单里那一条要保留：多选态下点行是切换勾选，
                      // 没有别的路径能进详情。
                      menu: buildComicMenu(comic),
                    );
                  },
                ),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildTopBar(context, actions),
          ),
        ],
      ),
    );

    return PopScope(
      canPop: !multiSelectMode && !searchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedComics.clear();
          });
        } else if (searchMode) {
          setState(() {
            searchMode = false;
            keyword = "";
            update();
          });
        }
      },
      child: body,
    );
  }

  Future<bool> deleteComics(List<LocalComic> comics) async {
    bool isDeleted = false;
    await showDialog(
      context: App.rootContext,
      builder: (context) {
        bool removeComicFile = true;
        bool removeFavoriteAndHistory = true;
        return StatefulBuilder(
          builder: (context, state) {
            return ContentDialog(
              title: "Delete".tl,
              content: Column(
                children: [
                  CheckboxListTile(
                    title: Text("Remove local favorite and history".tl),
                    value: removeFavoriteAndHistory,
                    onChanged: (v) {
                      state(() {
                        removeFavoriteAndHistory = !removeFavoriteAndHistory;
                      });
                    },
                  ),
                  CheckboxListTile(
                    title: Text("Also remove files on disk".tl),
                    value: removeComicFile,
                    onChanged: (v) {
                      state(() {
                        removeComicFile = !removeComicFile;
                      });
                    },
                  ),
                ],
              ),
              actions: [
                if (comics.length == 1 && comics.first.hasChapters)
                  TextButton(
                    child: Text("Delete Chapters".tl),
                    onPressed: () {
                      context.pop();
                      showDeleteChaptersPopWindow(context, comics.first);
                    },
                  ),
                FilledButton(
                  onPressed: () {
                    context.pop();
                    LocalManager().batchDeleteComics(
                      comics,
                      removeComicFile,
                      removeFavoriteAndHistory,
                    );
                    // 删掉的书不该继续在隐式缓存里留着体积和更新记录。
                    for (final comic in comics) {
                      LocalInsights().forgetSize(comic);
                      LocalInsights().forgetUpdates(comic);
                    }
                    isDeleted = true;
                  },
                  child: Text("Confirm".tl),
                ),
              ],
            );
          },
        );
      },
    );
    return isDeleted;
  }

  List<MenuEntry> exportActions(List<LocalComic> comics) {
    return [
      MenuEntry(
        icon: Icons.outbox_outlined,
        text: "Export as cbz".tl,
        onClick: () {
          exportLocalComics(context, comics, CBZ.export, ".cbz");
        },
      ),
      MenuEntry(
        icon: Icons.picture_as_pdf_outlined,
        text: "Export as pdf".tl,
        onClick: () async {
          exportLocalComics(context, comics, createPdfFromComicIsolate, ".pdf");
        },
      ),
      MenuEntry(
        icon: Icons.import_contacts_outlined,
        text: "Export as epub".tl,
        onClick: () async {
          exportLocalComics(context, comics, createEpubWithLocalComic, ".epub");
        },
      ),
    ];
  }
}

/// Export given comics to a file.
///
/// 抽成顶层函数是为了让本地详情页也能调（那边不在这个 State 里）。
/// 失败时把异常原文摊给用户看——这类错误大多来自文件系统（目录只读、
/// 文件名非法），吞掉只会变成「点了没反应」。
Future<void> exportLocalComics(
  BuildContext context,
  List<LocalComic> comics,
  ExportComicFunc export,
  String ext,
) async {
  var current = 0;
  var cacheDir = FilePath.join(App.cachePath, 'comics_export');
  var outFile = FilePath.join(App.cachePath, 'comics_export.zip');
  bool canceled = false;
  if (Directory(cacheDir).existsSync()) {
    Directory(cacheDir).deleteSync(recursive: true);
  }
  Directory(cacheDir).createSync();
  var loadingController = showLoadingDialog(
    context,
    allowCancel: true,
    message: "${"Exporting".tl} $current/${comics.length}",
    withProgress: comics.length > 1,
    onCancel: () {
      canceled = true;
    },
  );
  try {
    var fileName = "";
    // For each comic, export it to a file
    for (var comic in comics) {
      fileName = FilePath.join(
        cacheDir,
        sanitizeFileName(comic.title, maxLength: 100) + ext,
      );
      await export(comic, fileName);
      current++;
      if (comics.length > 1) {
        loadingController.setMessage(
          "${"Exporting".tl} $current/${comics.length}",
        );
        loadingController.setProgress(current / comics.length);
      }
      if (canceled) {
        return;
      }
    }
    // For single comic, just save the file
    if (comics.length == 1) {
      await saveFile(file: File(fileName), filename: File(fileName).name);
      Directory(cacheDir).deleteSync(recursive: true);
      loadingController.close();
      return;
    }
    // For multiple comics, compress the folder
    loadingController.setProgress(null);
    loadingController.setMessage("Compressing".tl);
    await ZipFile.compressFolderAsync(cacheDir, outFile);
    if (canceled) {
      File(outFile).deleteIgnoreError();
      return;
    }
  } catch (e, s) {
    Log.error("Export Comics", e, s);
    context.showMessage(message: e.toString());
    loadingController.close();
    return;
  } finally {
    Directory(cacheDir).deleteIgnoreError(recursive: true);
  }
  await saveFile(file: File(outFile), filename: "comics_export.zip");
  loadingController.close();
  File(outFile).deleteIgnoreError();
}

typedef ExportComicFunc =
    Future<File> Function(LocalComic comic, String outFilePath);

/// Opens the folder containing the comic in the system file explorer
Future<void> openComicFolder(LocalComic comic) async {
  final folderPath = comic.baseDir;
  if (App.isAndroid) {
    // 交给原生侧用 FileProvider 包成 content:// URI 再打开。直接用
    // `launchUrlString('file://...')` 在 Android 7 以上必然抛
    // FileUriExposedException（用户看到的那条 Failed to open folder）。
    bool opened = false;
    try {
      opened =
          await _folderChannel.invokeMethod<bool>('openFolder', {
            'path': folderPath,
          }) ??
          false;
    } catch (e, s) {
      Log.error("Open Folder", "native openFolder failed: $e", s);
    }
    if (!opened) {
      // 设备上没有能接管目录的应用（或者这个路径不在 FileProvider 的
      // 可共享范围内）。那就把路径摆出来，用户至少能复制出去自己找。
      if (App.rootContext.mounted) {
        _showFolderPathDialog(folderPath);
      }
    }
    return;
  }
  try {
    if (App.isWindows) {
      await Process.run('explorer', [folderPath]);
    } else if (App.isMacOS) {
      await Process.run('open', [folderPath]);
    } else if (App.isLinux) {
      // Try different file managers commonly found on Linux
      try {
        await Process.run('xdg-open', [folderPath]);
      } catch (e) {
        // Fallback to other common file managers
        try {
          await Process.run('nautilus', [folderPath]);
        } catch (e) {
          try {
            await Process.run('dolphin', [folderPath]);
          } catch (e) {
            try {
              await Process.run('thunar', [folderPath]);
            } catch (e) {
              // Last resort: use the URL launcher with file:// protocol
              await launchUrlString('file://$folderPath');
            }
          }
        }
      }
    } else {
      await launchUrlString('file://$folderPath');
    }
  } catch (e, s) {
    Log.error("Open Folder", "Failed to open comic folder: $e", s);
    // Show error message to user
    if (App.rootContext.mounted) {
      App.rootContext.showMessage(message: "Failed to open folder: $e");
    }
  }
}

const _folderChannel = MethodChannel("venera/method_channel");

void _showFolderPathDialog(String path) {
  // 应用私有目录（Android/data/...）系统是明确不让文件管理器进的，
  // 光甩一句「打不开」用户只会反复点。这里把原因和两条出路说清楚。
  final isAppPrivate =
      path.contains('/Android/data/') || path.contains('/Android/obb/');
  showDialog(
    context: App.rootContext,
    builder: (context) {
      return ContentDialog(
        title: "Open Folder".tl,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isAppPrivate) ...[
              Text(
                "Android doesn't let file managers browse this app folder. "
                        "Copy the path, or move the storage path to a public "
                        "folder in settings."
                    .tl,
                style: ts.s12,
              ),
              const SizedBox(height: 12),
            ],
            Text("Folder path".tl),
            const SizedBox(height: 8),
            SelectableText(
              path,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ],
        ),
        actions: [
          FilledButton.tonal(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: path));
              context.pop();
              App.rootContext.showMessage(message: "Copied".tl);
            },
            child: Text("Copy path".tl),
          ),
        ],
      );
    },
  );
}

void showDeleteChaptersPopWindow(BuildContext context, LocalComic comic) {
  var chapters = <String>[];

  showPopUpWidget(
    context,
    PopUpWidgetScaffold(
      title: "Delete Chapters".tl,
      body: StatefulBuilder(
        builder: (context, setState) {
          return Column(
            children: [
              Expanded(
                child: ListView.builder(
                  itemCount: comic.downloadedChapters.length,
                  itemBuilder: (context, index) {
                    var id = comic.downloadedChapters[index];
                    var chapter = comic.chapters![id] ?? "Unknown Chapter";
                    return CheckboxListTile(
                      title: Text(chapter),
                      value: chapters.contains(id),
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            chapters.add(id);
                          } else {
                            chapters.remove(id);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FilledButton(
                      onPressed: () {
                        Future.delayed(const Duration(milliseconds: 200), () {
                          LocalManager().deleteComicChapters(comic, chapters);
                        });
                        App.rootContext.pop();
                      },
                      child: Text("Submit".tl),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// 本地页顶部的「下载中」横条。
///
/// 已下载的漫画在数据库里，下载中的还没有记录——原来看不到它们，只能去
/// 下载管理页翻。放在本地页顶部，语义上正好连起来：上面是正在进来的，
/// 下面是已经进来的。
class _DownloadingSection extends StatelessWidget {
  const _DownloadingSection();

  /// 点封面 = 暂停/继续。
  ///
  /// 队列里等着（不是用户按的暂停）的任务不吃这一下：它本来就在排队，点一下
  /// 就开始会绕过并发上限。交给调度器自己拉起来。
  void _toggle(DownloadTask task) {
    Haptics.tap();
    if (!task.isPaused) {
      task.pause();
    } else if (task.userPaused) {
      task.resume();
    }
    LocalManager().pumpQueue();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = LocalManager().downloadingTasks;
    if (tasks.isEmpty) {
      return const SizedBox();
    }
    // 卡片高度 = 封面 112 + 间距 + 两行文字。按系统字体缩放算，否则把
    // 字号调大之后横向列表会把底下的标题和速度裁掉一半。
    final textScale = MediaQuery.textScalerOf(context).scale(10) / 10;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text("Downloading".tl, style: ts.s14.bold),
              const SizedBox(width: 6),
              Text(
                "${tasks.length}",
                style: ts.s12.copyWith(
                  color: context.colorScheme.onSurface.toOpacity(0.6),
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () {
                  showPopUpWidget(context, const DownloadingPage());
                },
                child: Text("View all".tl, style: ts.s12),
              ),
            ],
          ),
          SizedBox(
            height: 112 + 4 + 33 * textScale + 6,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              itemCount: tasks.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final task = tasks[i];
                return DownloadingCard(
                  key: ValueKey(task),
                  task: task,
                  onCoverTap: () => _toggle(task),
                  onLongPress: () => openDownloadingDetail(context, task),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 本地漫画列表的一行。
///
/// 原来是封面网格，一眼只能看到标题。改成横排之后一行能说清三件事：占了多少
/// 空间、读到哪了、网源那边有没有新章节——这三个都是「要不要点进去」的判断
/// 网格模式下的一本书。
///
/// 详情行那套东西（进度条、体积、阅读位置）在 110 宽的格子里塞不下，只留
/// 最要紧的两项：封面上的阅读进度、标题下面一行「3/20」。体积仍在详情页里。
class _LocalComicGridTile extends StatefulWidget {
  const _LocalComicGridTile({
    super.key,
    required this.comic,
    required this.heroID,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
    required this.menu,
  });

  final LocalComic comic;

  final int heroID;

  final bool selected;

  final bool selecting;

  final VoidCallback onTap;

  final VoidCallback onLongPress;

  final List<MenuEntry> menu;

  @override
  State<_LocalComicGridTile> createState() => _LocalComicGridTileState();
}

class _LocalComicGridTileState extends State<_LocalComicGridTile> {
  late final Listenable _listenable = Listenable.merge([
    LocalInsights(),
    HistoryManager(),
  ]);

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return ListenableBuilder(
      listenable: _listenable,
      builder: (context, _) {
        final insights = LocalInsights();
        final progress = insights.progressOf(widget.comic);
        final update = insights.updateOf(widget.comic);
        return GestureDetector(
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(child: _buildCover(colors)),
                    if (widget.selected)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: colors.primary.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: colors.primary,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (update?.hasUpdate == true)
                      Positioned(
                        right: 6,
                        top: 6,
                        child: _UpdateBadge(count: update!.newChapters),
                      ),
                    if (!widget.selecting)
                      Positioned(
                        right: 2,
                        bottom: 2,
                        child: _buildMenuButton(colors),
                      ),
                    Positioned(
                      left: 6,
                      bottom: 6,
                      child: _buildProgressPill(colors, progress),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.comic.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ts.s12.bold,
              ),
              const SizedBox(height: 2),
              Text(
                progress.totalChapters > 0
                    ? "${progress.readChapters}/${progress.totalChapters}"
                    : "Unread".tl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ts.s10.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCover(ColorScheme colors) {
    return Hero(
      tag: "cover${widget.heroID}",
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colors.primaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: AnimatedImage(
          image: CachedImageProvider("file://${widget.comic.coverFile.path}"),
          cacheWidth: kCoverDecodeWidth,
          width: double.infinity,
          height: double.infinity,
        ),
      ),
    );
  }

  /// 封面左下角那一小块「3/20」，压在图上所以得自带底色。
  Widget _buildProgressPill(ColorScheme colors, ReadProgressInfo progress) {
    if (progress.totalChapters <= 0) {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: colors.scrim.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        "${progress.readChapters}/${progress.totalChapters}",
        style: ts.s10.copyWith(color: colors.surface),
      ),
    );
  }

  /// 长按是多选（和详情行一致），菜单就只能另开一个口子：封面右下角这个点。
  /// 全部塞进长按会和列表页的操作对不上。
  Widget _buildMenuButton(ColorScheme colors) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        final box = context.findRenderObject() as RenderBox?;
        if (box == null) return;
        showMenuX(context, box.localToGlobal(Offset.zero), widget.menu);
      },
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: colors.scrim.withValues(alpha: 0.45),
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.more_horiz, size: 14, color: colors.surface),
      ),
    );
  }
}

/// 依据，藏在详情页里就白做了。
class _LocalComicTile extends StatefulWidget {
  const _LocalComicTile({
    super.key,
    required this.comic,
    required this.heroID,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
    required this.menu,
  });

  final LocalComic comic;

  final int heroID;

  final bool selected;

  final bool selecting;

  final VoidCallback onTap;

  final VoidCallback onLongPress;

  final List<MenuEntry> menu;

  @override
  State<_LocalComicTile> createState() => _LocalComicTileState();
}

class _LocalComicTileState extends State<_LocalComicTile> {
  /// 体积 / 更新角标来自 [LocalInsights]，阅读进度来自 [HistoryManager]：
  /// 两个都会在列表打开期间变化，谁变就刷谁，不用整页重建。
  late final Listenable _listenable = Listenable.merge([
    LocalInsights(),
    HistoryManager(),
  ]);

  @override
  void initState() {
    super.initState();
    // 量体积要遍历目录，交给它自己的队列（并发 2、有缓存），这里只是登记。
    LocalInsights().requestSize(widget.comic);
  }

  @override
  void didUpdateWidget(covariant _LocalComicTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.comic, widget.comic)) {
      LocalInsights().requestSize(widget.comic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return ListenableBuilder(
      listenable: _listenable,
      builder: (context, _) {
        final insights = LocalInsights();
        final progress = insights.progressOf(widget.comic);
        final update = insights.updateOf(widget.comic);
        final size = insights.sizeOf(widget.comic);
        return Material(
          color: widget.selected
              ? colors.primary.withValues(alpha: 0.08)
              : Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildCover(context),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                widget.comic.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: ts.s14.bold,
                              ),
                            ),
                            if (update?.hasUpdate == true)
                              _UpdateBadge(count: update!.newChapters),
                          ],
                        ),
                        if (widget.comic.subtitle.isNotEmpty)
                          Text(
                            widget.comic.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: ts.s12.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                        const SizedBox(height: 7),
                        _buildProgressBar(context, progress),
                        const SizedBox(height: 5),
                        _buildMetaLine(context, progress, size),
                      ],
                    ),
                  ),
                  if (widget.selecting)
                    Padding(
                      padding: const EdgeInsets.only(left: 4, top: 20),
                      child: Checkbox(
                        value: widget.selected,
                        onChanged: (_) => widget.onTap(),
                      ),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: MenuButton(entries: widget.menu),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCover(BuildContext context) {
    final colors = context.colorScheme;
    return Hero(
      tag: "cover${widget.heroID}",
      child: Container(
        width: 58,
        height: 78,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colors.primaryContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: AnimatedImage(
          image: CachedImageProvider("file://${widget.comic.coverFile.path}"),
          cacheWidth: kCoverDecodeWidth,
          width: double.infinity,
          height: double.infinity,
        ),
      ),
    );
  }

  Widget _buildProgressBar(BuildContext context, ReadProgressInfo progress) {
    final colors = context.colorScheme;
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress.fraction,
              minHeight: 3,
              backgroundColor: colors.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation(
                progress.started ? colors.primary : colors.outlineVariant,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          progress.totalChapters > 0
              ? "${progress.readChapters}/${progress.totalChapters}"
              : "",
          style: ts.s10.copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _buildMetaLine(
    BuildContext context,
    ReadProgressInfo progress,
    int? size,
  ) {
    final colors = context.colorScheme;
    final muted = colors.onSurfaceVariant.toOpacity(0.8);
    final parts = <String>[
      _readingText(progress),
      size == null ? "--" : formatLocalSize(size),
    ];
    return Row(
      children: [
        Icon(Icons.history, size: 11, color: muted),
        const SizedBox(width: 3),
        Expanded(
          child: Text(
            parts.join("  ·  "),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ts.s10.copyWith(color: muted),
          ),
        ),
      ],
    );
  }

  String _readingText(ReadProgressInfo progress) {
    if (!progress.started) {
      return "Unread".tl;
    }
    final chapter = progress.chapterTitle ?? "E${progress.ep}";
    return "$chapter · P${progress.page}";
  }
}

/// 「网源有新章节」角标。
class _UpdateBadge extends StatelessWidget {
  const _UpdateBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return Tooltip(
      message: "New chapters".tl,
      child: Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: colors.error,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text(
          "+$count",
          style: TextStyle(
            fontSize: 10,
            height: 1.3,
            fontWeight: FontWeight.w600,
            color: colors.onError,
          ),
        ),
      ),
    );
  }
}

class _LocalEmptyHint extends StatelessWidget {
  const _LocalEmptyHint({required this.hasKeyword});

  final bool hasKeyword;

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 24),
      child: Column(
        children: [
          Icon(
            hasKeyword ? Icons.search_off : Icons.photo_library_outlined,
            size: 40,
            color: colors.onSurfaceVariant.toOpacity(0.5),
          ),
          const SizedBox(height: 12),
          Text(
            hasKeyword ? "No results".tl : "Local comic not found".tl,
            style: ts.s14.copyWith(color: colors.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
