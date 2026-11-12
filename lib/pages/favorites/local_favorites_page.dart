part of 'favorites_page.dart';

const _localAllFolderLabel = '^_^[%local_all%]^_^';

/// 「已阅」虚拟文件夹在 UI 层的指代名，实际存储用
/// [LocalFavoritesManager.readFolderName] 表。
const _localReadFolderLabel = '^_^[%local_read%]^_^';

/// 「本地」虚拟文件夹的指代名。
///
/// 它不是一张收藏夹表，而是**本地库的投影**：库里有几本就显示几本，包括
/// 从来没收藏过的书。所以既不用迁移数据，也不会出现「挪走的收藏回不来、
/// 新下的书又进不去」这种不同步。
///
/// 哨兵名沿用 1.4.55 的取值：它被写进了 implicitData（上次选中的分类），
/// 改字符串等于让老用户升级后回落到「未选择」。
const _localDownloadedFolderLabel = '^_^[%local_downloaded%]^_^';

/// If the number of comics in a folder exceeds this limit, it will be
/// fetched asynchronously.
const _asyncDataFetchLimit = 500;

class _LocalFavoritesPage extends StatefulWidget {
  const _LocalFavoritesPage({required this.folder, super.key});

  final String folder;

  @override
  State<_LocalFavoritesPage> createState() => _LocalFavoritesPageState();
}

class _LocalFavoritesPageState extends State<_LocalFavoritesPage> {
  late _FavoritesPageState favPage;

  late List<FavoriteItem> comics;

  String? networkSource;
  String? networkFolder;

  Map<Comic, bool> selectedComics = {};

  var selectedLocalFolders = <String>{};

  late List<String> added = [];

  String keyword = "";
  bool searchHasUpper = false;

  bool searchMode = false;

  bool multiSelectMode = false;

  int? lastSelectedIndex;

  bool get isAllFolder => widget.folder == _localAllFolderLabel;

  bool get isReadFolder => widget.folder == _localReadFolderLabel;

  bool get isDownloadedFolder => widget.folder == _localDownloadedFolderLabel;

  /// 自建分类才有的操作（重命名 / 排序 / 导出 / 删除分类）。
  bool get isNormalFolder =>
      !isAllFolder && !isReadFolder && !isDownloadedFolder;

  /// 当前页面对应的真实表名。「已阅」用的是内置表，不能拿 widget.folder
  /// （那是 UI 哨兵名）去当表名查。「本地」没有表，它读的是本地库，凡是
  /// 需要表名的收藏操作都得先判 [isDownloadedFolder] 绕开。
  String get localTable {
    if (isReadFolder) return LocalFavoritesManager.readFolderName;
    return widget.folder;
  }

  LocalFavoritesManager get manager => LocalFavoritesManager();

  bool isLoading = false;

  /// 加载期间收到的变更通知。丢弃的话，页面会停在「开始加载那一刻」的快照：
  /// 大收藏夹异步读库要几百毫秒，这期间在别处取消的收藏会重新冒出来。
  bool _reloadPending = false;

  late String readFilterSelect;

  late String sortSelect;

  /// 按当前排序方式整理待显示列表
  List<FavoriteItem> applySort(List<FavoriteItem> list) {
    if (sortSelect == titleSortAZ) {
      return sortByTitleAZ(list, (e) => e.title);
    } else if (sortSelect == titleSortZA) {
      return sortByTitleZA(list, (e) => e.title);
    }
    return list;
  }

  var searchResults = <FavoriteItem>[];

  void updateSearchResult() {
    setState(() {
      if (keyword.trim().isEmpty) {
        searchResults = comics;
      } else {
        searchResults = [];
        for (var comic in comics) {
          if (matchKeyword(keyword, comic) ||
              matchKeywordT(keyword, comic) ||
              matchKeywordS(keyword, comic)) {
            searchResults.add(comic);
          }
        }
      }
    });
  }

  void _runPendingReload() {
    if (_reloadPending) {
      _reloadPending = false;
      updateComics();
    }
  }

  void updateComics() {
    // 导入同步、新建/排序分类这些 .then 回调没有 mounted 判断，统一在这里挡住。
    if (!mounted) {
      return;
    }
    if (isLoading) {
      _reloadPending = true;
      return;
    }
    if (isReadFolder) {
      comics = manager.getFolderComics(LocalFavoritesManager.readFolderName);
    } else if (isDownloadedFolder) {
      comics = localLibraryItems();
    } else if (isAllFolder) {
      var totalComics = manager.totalComics;
      if (totalComics < _asyncDataFetchLimit) {
        comics = manager.getAllComics();
      } else {
        isLoading = true;
        manager
            .getAllComicsAsync()
            .minTime(const Duration(milliseconds: 200))
            .then<void>((value) {
              if (!mounted) {
                return;
              }
              setState(() {
                isLoading = false;
                comics = value;
              });
              _runPendingReload();
            }, onError: (Object e, StackTrace s) {
              // 没有错误分支时 isLoading 永远不复位，页面就停在转圈上。
              Log.error("Favorites", "Failed to load all comics: $e\n$s");
              if (!mounted) {
                return;
              }
              setState(() {
                isLoading = false;
              });
              _runPendingReload();
            });
      }
    } else {
      var folderComics = manager.folderComics(widget.folder);
      if (folderComics < _asyncDataFetchLimit) {
        comics = manager.getFolderComics(widget.folder);
      } else {
        isLoading = true;
        manager
            .getFolderComicsAsync(widget.folder)
            .minTime(const Duration(milliseconds: 200))
            .then<void>((value) {
              if (!mounted) {
                return;
              }
              setState(() {
                isLoading = false;
                comics = value;
              });
              _runPendingReload();
            }, onError: (Object e, StackTrace s) {
              Log.error("Favorites", "Failed to load folder comics: $e\n$s");
              if (!mounted) {
                return;
              }
              setState(() {
                isLoading = false;
              });
              _runPendingReload();
            });
      }
    }
    setState(() {});
  }

  /// 本地库的投影：把 [LocalComic] 包成 [FavoriteItem]，好让这页现成的
  /// 网格、搜索、筛选、多选原样复用。
  ///
  /// 封面直接给 `file://` 绝对路径——[comic.coverFile] 就在磁盘上，走这条路
  /// 不用发网络请求（CachedImageProvider 对 file:// 是直接读文件）。
  List<FavoriteItem> localLibraryItems() {
    List<LocalComic> all;
    try {
      // 只要标题、封面、时间，走轻量查询：整本章节 JSON 在这里用不上，
      // 而每次下载完成都会触发一次刷新（LocalManager 通知）。
      all = LocalManager().getComicSummaries(LocalSortType.timeDesc);
    } catch (e, s) {
      // 本地库还没初始化好（启动早期 / 测试环境）时当空库处理。
      Log.error("Favorites", "Failed to read local library: $e\n$s");
      return [];
    }
    return all
        .map(
          (comic) => FavoriteItem(
            id: comic.id,
            name: comic.title,
            author: comic.subtitle,
            type: comic.comicType,
            tags: comic.tags,
            coverPath: "file://${comic.coverFile.path}",
            favoriteTime: comic.createdAt,
          ),
        )
        .toList();
  }

  List<FavoriteItem> filterComics(List<FavoriteItem> curComics) {
    return curComics.where((comic) {
      // 直接用条目自己的 type。以前从 `sourceKey.hashCode` 反推，导入手工
      // 导入的书（local 是 value=0 的特例）和源已卸载的收藏（sourceKey 会
      // 退化成 "Unknown:N"）永远查不到历史，于是「已完成」筛出来是空的、
      // 「未完成」里却还挂着已读完的书。
      var history = HistoryManager().find(comic.id, comic.type);
      if (readFilterSelect == "UnCompleted") {
        return history == null || history.page != history.maxPage;
      } else if (readFilterSelect == "Completed") {
        return history != null && history.page == history.maxPage;
      }
      return true;
    }).toList();
  }

  bool matchKeyword(String keyword, FavoriteItem comic) {
    var list = keyword.split(" ");
    for (var k in list) {
      if (k.isEmpty) continue;
      if (checkKeyWordMatch(k, comic.title, false) ||
          titleMatchesQuery(comic.title, k, normalized: !searchHasUpper)) {
        continue;
      } else if (comic.subtitle != null &&
          checkKeyWordMatch(k, comic.subtitle!, false)) {
        continue;
      } else if (comic.tags.any((tag) {
        if (checkKeyWordMatch(k, tag, true)) {
          return true;
        } else if (tag.contains(':') &&
            checkKeyWordMatch(k, tag.split(':')[1], true)) {
          return true;
        } else if (App.locale.languageCode != 'en' &&
            checkKeyWordMatch(k, tag.translateTagsToCN, true)) {
          return true;
        }
        return false;
      })) {
        continue;
      } else if (checkKeyWordMatch(k, comic.author, true)) {
        continue;
      }
      return false;
    }
    return true;
  }

  bool checkKeyWordMatch(String keyword, String compare, bool needEqual) {
    String temp = compare;
    // 没有大写的话, 就转成小写比较, 避免搜索需要注意大小写
    if (!searchHasUpper) {
      temp = temp.toLowerCase();
    }
    if (needEqual) {
      return keyword == temp;
    }
    return temp.contains(keyword);
  }

  // Convert keyword to traditional Chinese to match comics
  bool matchKeywordT(String keyword, FavoriteItem comic) {
    if (!OpenCC.hasChineseSimplified(keyword)) {
      return false;
    }
    keyword = OpenCC.simplifiedToTraditional(keyword);
    return matchKeyword(keyword, comic);
  }

  // Convert keyword to simplified Chinese to match comics
  bool matchKeywordS(String keyword, FavoriteItem comic) {
    if (!OpenCC.hasChineseTraditional(keyword)) {
      return false;
    }
    keyword = OpenCC.traditionalToSimplified(keyword);
    return matchKeyword(keyword, comic);
  }

  @override
  void initState() {
    readFilterSelect =
        appdata.implicitData["local_favorites_read_filter"] ??
        readFilterList[0];
    sortSelect =
        appdata.implicitData["local_favorites_sort"] ?? titleSortDefault;
    favPage = context.findAncestorStateOfType<_FavoritesPageState>()!;
    if (isNormalFolder) {
      var (a, b) = LocalFavoritesManager().findLinked(widget.folder);
      networkSource = a;
      networkFolder = b;
    } else {
      networkSource = null;
      networkFolder = null;
    }
    comics = [];
    updateComics();
    LocalFavoritesManager().addListener(updateComics);
    if (isDownloadedFolder) {
      // 「本地」分类读的是本地库，下完一本 / 删掉一本都得跟着刷新。
      LocalManager().addListener(updateComics);
    }
    super.initState();
  }

  @override
  void dispose() {
    // 控制器要释放：切分类会重建这个 State，不释放就每次漏一个。
    scrollController.dispose();
    LocalFavoritesManager().removeListener(updateComics);
    if (isDownloadedFolder) {
      LocalManager().removeListener(updateComics);
    }
    super.dispose();
  }

  void selectAll() {
    setState(() {
      // 只选「看得见」的那些。网格渲染的是 filterComics(comics)，全选却遍历
      // 原始 comics 的话，切到「未读」再全选删除会把已读的一起删掉。
      var visible = searchMode ? searchResults : filterComics(comics);
      selectedComics = visible.asMap().map((k, v) => MapEntry(v, true));
    });
  }

  void invertSelection() {
    setState(() {
      // 同上：反选只反转可见项，并丢掉被筛掉的旧选中，避免「看不见却被删」。
      var visible = searchMode ? searchResults : filterComics(comics);
      var next = <FavoriteItem, bool>{};
      for (var c in visible) {
        if (!selectedComics.containsKey(c)) {
          next[c] = true;
        }
      }
      selectedComics = next;
    });
  }

  bool downloadComic(FavoriteItem c) {
    var source = c.type.comicSource;
    if (source != null) {
      // 「已经下好了」必须按章节表核对，不能只看库里有没有这条记录：
      // isDownloaded 两参数时下过一话就返回 true，于是补章的入口静默失效，
      // 界面还照样弹「Download started」——用户以为在补，其实队列里没有。
      var local = LocalManager().find(c.id, c.type);
      if (local != null && local.chapters != null) {
        var ids = local.chapters!.ids;
        if (ids.isNotEmpty &&
            local.downloadedChapters.toSet().containsAll(ids)) {
          return false;
        }
      }
      LocalManager().addTask(
        ImagesDownloadTask(source: source, comicId: c.id, comicTitle: c.title),
      );
      return true;
    }
    return false;
  }

  void downloadSelected() {
    int count = 0;
    for (var c in selectedComics.keys) {
      if (downloadComic(c as FavoriteItem)) {
        count++;
      }
    }
    if (count > 0) {
      context.showMessage(
        message: "Added @c comics to download queue.".tlParams({"c": count}),
      );
    }
  }

  var scrollController = ScrollController();

  /// 顶栏接管了标题和操作按钮时，页面自己那条 SliverAppbar 就不画了。
  ///
  /// 之前两条栏是同时存在的：玻璃顶栏（文件夹 / 搜索 / 设置）下面再压一条
  /// 实色横杠（≡ / 文件夹名 / 排序 / 多选 / 搜索 / 更多），同一屏里两个搜索
  /// 图标各管各的，顶上还多一条硬边。现在标题和按钮全部交给顶栏，页面只剩
  /// 内容——和主页、推荐页一致。
  bool get _headersInTopBar => favPage.topBar != null;

  /// 排序 / 已阅筛选被动过时，顶栏那颗按钮要有个「开着」的样子。
  bool get _filterActive =>
      readFilterSelect != readFilterList[0] || sortSelect != titleSortDefault;

  void openFilterDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return _LocalFavoritesFilterDialog(
          initReadFilterSelect: readFilterSelect,
          initSortSelect: sortSelect,
          updateConfig: (readFilter, sort) {
            setState(() {
              readFilterSelect = readFilter;
              sortSelect = sort;
            });
            updateComics();
          },
        );
      },
    );
  }

  void enterSelectMode() {
    setState(() {
      multiSelectMode = true;
      selectedComics.clear();
    });
  }

  void enterSearchMode() {
    setState(() {
      keyword = "";
      searchMode = true;
      updateSearchResult();
    });
  }

  /// 与网络收藏夹同步（只有「链接到网络源」的文件夹才有）。
  ///
  /// 原来这颗按钮点开的是一个 [Flyout]，而 Flyout 必须挂在被点的那个图标
  /// 下面，顶栏那套图标位给不了它这个宿主。这里改成弹窗，内容一字未动。
  void openSyncDialog() {
    if (networkSource == null) {
      return;
    }
    final key = GlobalKey<_SelectUpdatePageNumState>();
    showDialog(
      context: context,
      builder: (context) {
        return ContentDialog(
          title: "Sync".tl,
          content: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _SelectUpdatePageNum(
              networkSource: networkSource!,
              networkFolder: networkFolder,
              key: key,
            ),
          ),
          actions: [
            Button.filled(
              child: Text("Update".tl),
              onPressed: () {
                final pageNum = key.currentState?.updatePageNum;
                context.pop();
                if (pageNum == null) {
                  return;
                }
                importNetworkFolder(
                  networkSource!,
                  pageNum,
                  widget.folder,
                  networkFolder!,
                ).then((value) {
                  updateComics();
                });
              },
            ),
          ],
        );
      },
    );
  }

  /// 三点菜单。文件夹管理的低频动作都收在这里，顶栏只留高频图标。
  ///
  /// 「已阅」「已下载」是内置分类，不提供重命名/排序/导出/删除等文件夹管理。
  List<MenuEntry> buildMoreMenu() {
    return [
      // 与网络源同步。只有「链接到网络源」的文件夹才有，而且是个低频动作，
      // 放在菜单里比在顶栏占一颗图标划算（顶栏已经被 6 颗图标挤满了）。
      if (networkSource != null && !isAllFolder)
        MenuEntry(
          icon: Icons.sync,
          text: "Sync".tl,
          onClick: openSyncDialog,
        ),
      // 智能书架入口收进三点菜单，顶栏只留高频操作
      MenuEntry(
        icon: Icons.auto_awesome_motion_outlined,
        text: "Smart shelf".tl,
        onClick: () {
          context.to(() => const SmartShelfPage());
        },
      ),
      if (isNormalFolder) ...[
        MenuEntry(
          icon: Icons.edit_outlined,
          text: "Rename".tl,
          onClick: () {
            showInputDialog(
              context: App.rootContext,
              title: "Rename".tl,
              hintText: "New Name".tl,
              onConfirm: (value) {
                var err = validateFolderName(value.toString());
                if (err != null) {
                  return err;
                }
                LocalFavoritesManager().rename(
                  widget.folder,
                  value.toString(),
                );
                favPage.folderList?.updateFolders();
                favPage.setFolder(false, value.toString());
                return null;
              },
            );
          },
        ),
        MenuEntry(
          icon: Icons.reorder,
          text: "Reorder".tl,
          onClick: () {
            context
                .to(() {
                  return _ReorderComicsPage(widget.folder, (
                    comics,
                  ) {
                    this.comics = comics;
                  });
                })
                .then((value) {
                  if (mounted) {
                    setState(() {});
                  }
                });
          },
        ),
        MenuEntry(
          icon: Icons.upload_file,
          text: "Export".tl,
          onClick: () {
            var json = LocalFavoritesManager().folderToJson(widget.folder);
            saveFile(
              data: utf8.encode(json),
              filename: "${widget.folder}.json",
            );
          },
        ),
        MenuEntry(
          icon: Icons.update,
          text: "Update Comics Info".tl,
          onClick: () {
            updateComicsInfo(widget.folder).then((newComics) {
              if (mounted) {
                setState(() {
                  comics = newComics;
                });
              }
            });
          },
        ),
        MenuEntry(
          icon: Icons.delete_outline,
          text: "Delete Folder".tl,
          color: context.colorScheme.error,
          isDanger: true,
          onClick: () {
            showConfirmDialog(
              context: App.rootContext,
              title: "Delete".tl,
              content: "Delete folder '@f' ?".tlParams({
                "f": widget.folder,
              }),
              btnColor: context.colorScheme.error,
              onConfirm: () {
                favPage.setFolder(false, null);
                LocalFavoritesManager().deleteFolder(widget.folder);
                favPage.folderList?.updateFolders();
              },
            );
          },
        ),
      ],
    ];
  }

  /// 交给玻璃顶栏的图标位。顺序按使用频率：筛选 → 多选 → 搜索 → 更多。
  ///
  /// 这里**没有**「文件夹」入口：它已经在顶栏的全局图标位上了（见
  /// [MainPage] 的 paneActions），再放一个就是同一件事两颗图标。
  /// 「同步」也挪进了三点菜单——手机宽度只够 6 颗图标，它最不值钱。
  List<PaneActionEntry> buildTopBarActions(BuildContext context) {
    final primary = context.colorScheme.primary;
    return [
      PaneActionEntry(
        icon: Icons.sort_rounded,
        label: "Filter".tl,
        color: _filterActive ? primary : null,
        onTap: openFilterDialog,
      ),
      PaneActionEntry(
        icon: Icons.checklist_rtl,
        label: "Select".tl,
        onTap: enterSelectMode,
      ),
      PaneActionEntry(
        icon: Icons.search,
        label: "Search".tl,
        onTap: enterSearchMode,
      ),
      PaneActionEntry(
        icon: Icons.more_horiz,
        label: "More".tl,
        onTapWithAnchor: (context, anchor) {
          showMenuX(context, anchor.topLeft, buildMoreMenu());
        },
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    var title = favPage.folder ?? "Unselected".tl;
    if (title == _localAllFolderLabel) {
      title = "All".tl;
    } else if (title == _localReadFolderLabel) {
      title = "Finished Reading".tl;
    } else if (title == _localDownloadedFolderLabel) {
      title = "Local comics".tl;
    }

    Widget body = SmoothCustomScrollView(
      controller: scrollController,
      slivers: [
        if (!searchMode && !multiSelectMode && !_headersInTopBar)
          SliverAppbar(
            pinned: false,
            style: context.width < changePoint
                ? AppbarStyle.shadow
                : AppbarStyle.blur,
            leading: Tooltip(
              message: "Folders".tl,
              child: context.width <= _kTwoPanelChangeWidth
                  ? IconButton(
                      icon: const Icon(Icons.menu),
                      color: context.colorScheme.primary,
                      onPressed: favPage.showFolderSelector,
                    )
                  : const SizedBox(),
            ),
            title: GestureDetector(
              onTap: context.width < _kTwoPanelChangeWidth
                  ? favPage.showFolderSelector
                  : null,
              child: Text(title),
            ),
            // 按钮全部走同一批方法：顶栏那一排图标调用的是同一份，
            // 只是换了宿主（这一条栏只在没有顶栏时才会出现）。
            actions: [
              Tooltip(
                message: "Filter".tl,
                child: IconButton(
                  icon: const Icon(Icons.sort_rounded),
                  color: _filterActive
                      ? context.colorScheme.primaryContainer
                      : null,
                  onPressed: openFilterDialog,
                ),
              ),
              Tooltip(
                message: "Select".tl,
                child: IconButton(
                  icon: const Icon(Icons.checklist_rtl),
                  onPressed: enterSelectMode,
                ),
              ),
              Tooltip(
                message: "Search".tl,
                child: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: enterSearchMode,
                ),
              ),
              MenuButton(entries: buildMoreMenu()),
            ],
          )
        else if (multiSelectMode)
          SliverAppbar(
            style: context.width < changePoint
                ? AppbarStyle.shadow
                : AppbarStyle.blur,
            leading: Tooltip(
              message: "Cancel".tl,
              child: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    multiSelectMode = false;
                    selectedComics.clear();
                  });
                },
              ),
            ),
            title: Text(
              "Selected @c comics".tlParams({"c": selectedComics.length}),
            ),
            actions: [
              MenuButton(
                entries: [
                  if (isNormalFolder)
                    MenuEntry(
                      icon: Icons.done_all,
                      text: "Mark as Read".tl,
                      onClick: () {
                        showConfirmDialog(
                          context: context,
                          title: "Mark as Read".tl,
                          content: "Move @c comics to \"Finished Reading\"?"
                              .tlParams({"c": selectedComics.length}),
                          onConfirm: () {
                            LocalFavoritesManager().batchMoveToRead(
                              widget.folder,
                              selectedComics.keys
                                  .map((e) => e as FavoriteItem)
                                  .toList(),
                            );
                            updateComics();
                            _cancel();
                          },
                        );
                      },
                    ),
                  if (isReadFolder)
                    MenuEntry(
                      icon: Icons.drive_file_move,
                      text: "Move to folder".tl,
                      onClick: () => favoriteOption('moveFromRead'),
                    ),
                  if (isNormalFolder)
                    MenuEntry(
                      icon: Icons.drive_file_move,
                      text: "Move to folder".tl,
                      onClick: () => favoriteOption('move'),
                    ),
                  MenuEntry(
                    icon: Icons.select_all,
                    text: "Select All".tl,
                    onClick: selectAll,
                  ),
                  MenuEntry(
                    icon: Icons.deselect,
                    text: "Deselect".tl,
                    onClick: _cancel,
                  ),
                  MenuEntry(
                    icon: Icons.flip,
                    text: "Invert Selection".tl,
                    onClick: invertSelection,
                  ),
                  // 「本地」里的书已经在磁盘上了，再点「下载」只会全部落空。
                  if (!isDownloadedFolder)
                    MenuEntry(
                      icon: Icons.download,
                      text: "Download".tl,
                      onClick: downloadSelected,
                    ),
                  // 删除是危险操作，固定放在菜单最后。
                  // 内置分类里也要能删：失效里全是打不开的书，删掉才是主要
                  // 出路；已阅同理。
                  if (!isAllFolder)
                    MenuEntry(
                      icon: Icons.delete_outline,
                      text: "Delete Comic".tl,
                      color: context.colorScheme.error,
                      isDanger: true,
                      onClick: () {
                        showConfirmDialog(
                          context: context,
                          title: "Delete".tl,
                          content: isDownloadedFolder
                              ? "Delete @c local comics and files?".tlParams({
                                  "c": selectedComics.length,
                                })
                              : "Delete @c comics?".tlParams({
                                  "c": selectedComics.length,
                                }),
                          btnColor: context.colorScheme.error,
                          onConfirm: () {
                            _deleteComicWithId();
                          },
                        );
                      },
                    ),
                ],
              ),
            ],
          )
        else if (searchMode)
          SliverAppbar(
            style: context.width < changePoint
                ? AppbarStyle.shadow
                : AppbarStyle.blur,
            leading: Tooltip(
              message: "Cancel".tl,
              child: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  setState(() {
                    setState(() {
                      searchMode = false;
                    });
                  });
                },
              ),
            ),
            title: TextField(
              autofocus: true,
              decoration: InputDecoration(
                hintText: "Search".tl,
                border: UnderlineInputBorder(),
              ),
              onChanged: (v) {
                keyword = v;
                searchHasUpper = keyword.contains(RegExp(r'[A-Z]'));
                updateSearchResult();
              },
            ).paddingBottom(8).paddingRight(8),
          ),
        // 正常状态下页面没有自己的标题栏了，留白要自己付：付成 sliver 内部
        // 的 padding，往上滑的时候封面才能穿到玻璃顶栏后面去。
        if (!searchMode && !multiSelectMode && _headersInTopBar)
          SliverPadding(
            padding: EdgeInsets.only(top: context.padding.top),
          ),
        if (!isLoading &&
            !searchMode &&
            isDownloadedFolder &&
            comics.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 72, 24, 0),
              child: Column(
                children: [
                  Icon(
                    Icons.download_done,
                    size: 44,
                    color: context.colorScheme.onSurfaceVariant.toOpacity(0.4),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    "No local comics".tl,
                    style: ts.s14.withColor(
                      context.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (isLoading)
          SliverToBoxAdapter(
            child: SizedBox(
              height: 200,
              child: const Center(child: FiveDotLoadingAnimation()),
            ),
          )
        else
          SliverGridComics(
            comics: applySort(
              searchMode ? searchResults : filterComics(comics),
            ),
            selections: selectedComics,
            builtInMenuActions: kComicMenuActionsFavorite,
            menuBuilder: (c) {
              // 菜单顺序按使用频率排：读 → 下载 → 选择 → 归类 → 删除。
              // 这里不再重复「详情」「换源」——长按预览卡上已经是按钮；
              // 也不再有「加入收藏」——书本来就在收藏夹里。删除单独成组。
              return [
                if (appdata.settings["onClickFavorite"] == "viewDetail")
                  MenuEntry(
                    icon: Icons.menu_book_outlined,
                    text: "Read".tl,
                    onClick: () {
                      App.mainNavigatorKey?.currentContext?.to(
                        () =>
                            ReaderWithLoading(id: c.id, sourceKey: c.sourceKey),
                      );
                    },
                  ),
                if (!isDownloadedFolder)
                  MenuEntry(
                    icon: Icons.download,
                    text: "Download".tl,
                    onClick: () {
                      var started = downloadComic(c as FavoriteItem);
                      context.showMessage(
                        message:
                            started ? "Download started".tl : "Downloaded".tl,
                      );
                    },
                  ),
                MenuEntry(
                  icon: Icons.check,
                  text: "Select".tl,
                  onClick: () {
                    setState(() {
                      if (!multiSelectMode) {
                        multiSelectMode = true;
                      }
                      if (selectedComics.containsKey(c as FavoriteItem)) {
                        selectedComics.remove(c);
                        _checkExitSelectMode();
                      } else {
                        selectedComics[c] = true;
                      }
                      lastSelectedIndex = comics.indexOf(c);
                    });
                  },
                ),
                if (isNormalFolder)
                  MenuEntry(
                    icon: Icons.done_all,
                    text: "Mark as Read".tl,
                    onClick: () {
                      LocalFavoritesManager().moveToRead(
                        widget.folder,
                        c as FavoriteItem,
                      );
                      updateComics();
                    },
                  ),
                if (isReadFolder)
                  MenuEntry(
                    icon: Icons.drive_file_move,
                    text: "Move to folder".tl,
                    onClick: () {
                      setState(() {
                        selectedComics.clear();
                        selectedComics[c as FavoriteItem] = true;
                        multiSelectMode = true;
                      });
                      favoriteOption('moveFromRead');
                    },
                  ),
                if (isDownloadedFolder)
                  MenuEntry(
                    icon: Icons.folder_open,
                    text: "Open Folder".tl,
                    onClick: () {
                      var comic = c as FavoriteItem;
                      var local = LocalManager().find(comic.id, comic.type);
                      if (local != null) {
                        openComicFolder(local);
                      }
                    },
                  ),
                if (!isAllFolder)
                  MenuEntry(
                    icon: Icons.delete_outline,
                    text: "Delete".tl,
                    color: context.colorScheme.error,
                    isDanger: true,
                    onClick: () {
                      var comic = c as FavoriteItem;
                      if (isDownloadedFolder) {
                        var local = LocalManager().find(comic.id, comic.type);
                        if (local == null) {
                          return;
                        }
                        showConfirmDialog(
                          context: context,
                          title: "Delete".tl,
                          content: "Delete @c local comics and files?"
                              .tlParams({"c": 1}),
                          btnColor: context.colorScheme.error,
                          onConfirm: () {
                            LocalManager().batchDeleteComics([local]);
                            updateComics();
                          },
                        );
                        return;
                      }
                      LocalFavoritesManager().deleteComicWithId(
                        localTable,
                        comic.id,
                        comic.type,
                      );
                    },
                  ),
              ];
            },
            onTap: (c, heroID) {
              if (multiSelectMode) {
                setState(() {
                  if (selectedComics.containsKey(c as FavoriteItem)) {
                    selectedComics.remove(c);
                    _checkExitSelectMode();
                  } else {
                    selectedComics[c] = true;
                  }
                  lastSelectedIndex = comics.indexOf(c);
                });
              } else if (appdata.settings["onClickFavorite"] == "viewDetail") {
                // 「本地」分类里的书进本地详情页：章节就是磁盘上的文件，能
                // 直接读、能打开文件夹、能导出。在线详情页那一套（下载 /
                // 点赞 / 评论 / 换源）对手机里的书不成立。
                //
                // 其余分类维持原样：收藏的是「源站上的那本书」，详情仍然去
                // 源上看（新章节、评论都在那边）。只有确实下到本地的，才有
                // 资格走本地页。
                final local = isDownloadedFolder
                    ? LocalManager().find(c.id, (c as FavoriteItem).type)
                    : null;
                if (local != null) {
                  final ctx = App.mainNavigatorKey?.currentContext;
                  if (ctx != null) {
                    LocalComicPage.open(ctx, local, heroID: heroID);
                  }
                  return;
                }
                App.mainNavigatorKey?.currentContext?.to(
                  () => ComicPage(
                    id: c.id,
                    sourceKey: c.sourceKey,
                    cover: c.cover,
                    title: c.title,
                    heroID: heroID,
                  ),
                );
              } else {
                // 阅读走 ReaderWithLoading，那边本来就是本地优先（下载过的
                // 章节直接读磁盘），所以这里不用再分叉。
                App.mainNavigatorKey?.currentContext?.to(
                  () => ReaderWithLoading(id: c.id, sourceKey: c.sourceKey),
                );
              }
            },
            // 长按不覆写：走默认的「预览 + 菜单」。
            //
            // 之前这里把长按改成了「在其他源搜索」，结果单本的删除 / 移动分类
            // / 标记已读 / 下载全部失去入口 —— 那些动作只存在于长按菜单里，
            // 等于为了一个换源入口牺牲了整张菜单。换源现在放在预览面板的
            // 「换源」按钮上，长按后一眼就能看到，两步可达。
          ),
      ],
    );
    body = AppScrollBar(
      // 拇指的轨道要从玻璃顶栏下沿开始。顶栏模式下页面没有自己的标题栏，
      // 起算点就是顶栏的位移；搜索 / 多选时页面里还有一条 pinned 的表头，
      // 再往下让 52。
      topPadding:
          context.padding.top + ((searchMode || multiSelectMode) ? 52 : 0),
      controller: scrollController,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
        child: body,
      ),
    );
    final topBar = favPage.topBar;
    if (topBar != null) {
      // 顶栏接管标题和按钮。搜索 / 多选这种临时状态由页面自己那条表头负责，
      // 这时候顶栏一侧清空，免得两处各显示一份。
      final inline = searchMode || multiSelectMode;
      body = FavoritesTopBarScope(
        controller: topBar,
        title: inline ? null : title,
        actions: inline ? const [] : buildTopBarActions(context),
        child: body,
      );
    }
    return PopScope(
      canPop: !multiSelectMode && !searchMode,
      onPopInvokedWithResult: (didPop, result) {
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedComics.clear();
          });
        } else if (searchMode) {
          setState(() {
            searchMode = false;
            keyword = "";
            updateComics();
          });
        }
      },
      child: body,
    );
  }

  void favoriteOption(String option) {
    var targetFolders = LocalFavoritesManager().folderNames
        .where((folder) => folder != favPage.folder)
        .toList();

    showPopUpWidget(
      App.rootContext,
      StatefulBuilder(
        builder: (context, setState) {
          return PopUpWidgetScaffold(
            title: isReadFolder
                ? "Finished Reading".tl
                : favPage.folder ?? "Unselected".tl,
            body: Padding(
              padding: EdgeInsets.only(bottom: context.padding.bottom + 16),
              child: Container(
                constraints: const BoxConstraints(
                  maxHeight: 700,
                  maxWidth: 500,
                ),
                child: Column(
                  children: [
                    Expanded(
                      child: ListView.builder(
                        itemCount: targetFolders.length + 1,
                        itemBuilder: (context, index) {
                          if (index == targetFolders.length) {
                            return SizedBox(
                              height: 36,
                              child: Center(
                                child: TextButton(
                                  onPressed: () {
                                    newFolder().then((v) {
                                      setState(() {
                                        targetFolders = LocalFavoritesManager()
                                            .folderNames
                                            .where(
                                              (folder) =>
                                                  folder != favPage.folder,
                                            )
                                            .toList();
                                      });
                                    });
                                  },
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.add, size: 20),
                                      const SizedBox(width: 4),
                                      Text("New Folder".tl),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }
                          var folder = targetFolders[index];
                          var disabled = false;
                          if (selectedLocalFolders.isNotEmpty) {
                            if (added.contains(folder) &&
                                !added.contains(selectedLocalFolders.first)) {
                              disabled = true;
                            } else if (!added.contains(folder) &&
                                added.contains(selectedLocalFolders.first)) {
                              disabled = true;
                            }
                          }
                          return CheckboxListTile(
                            title: Row(
                              children: [
                                Text(folder),
                                const SizedBox(width: 8),
                              ],
                            ),
                            value: selectedLocalFolders.contains(folder),
                            onChanged: disabled
                                ? null
                                : (v) {
                                    setState(() {
                                      // 一本漫画只能属于一个分类，
                                      // 移动目标只能选一个。
                                      selectedLocalFolders.clear();
                                      if (v!) {
                                        selectedLocalFolders.add(folder);
                                      }
                                    });
                                  },
                          );
                        },
                      ),
                    ),
                    Center(
                      child: FilledButton(
                        onPressed: () {
                          if (selectedLocalFolders.isEmpty) {
                            return;
                          }
                          if (option == 'move') {
                            var comics = selectedComics.keys
                                .map((e) => e as FavoriteItem)
                                .toList();
                            for (var f in selectedLocalFolders) {
                              LocalFavoritesManager().batchMoveFavorites(
                                favPage.folder as String,
                                f,
                                comics,
                              );
                            }
                          } else if (option == 'moveFromRead') {
                            var comics = selectedComics.keys
                                .map((e) => e as FavoriteItem)
                                .toList();
                            for (var f in selectedLocalFolders) {
                              for (var comic in comics) {
                                LocalFavoritesManager().moveFromRead(f, comic);
                              }
                            }
                          }
                          App.rootContext.pop();
                          updateComics();
                          _cancel();
                        },
                        child: Text("Move".tl),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _checkExitSelectMode() {
    if (selectedComics.isEmpty) {
      setState(() {
        multiSelectMode = false;
      });
    }
  }

  void _cancel() {
    setState(() {
      selectedComics.clear();
      multiSelectMode = false;
    });
  }

  void _deleteComicWithId() {
    if (isDownloadedFolder) {
      _deleteLocalComics();
      return;
    }
    var toBeDeleted = selectedComics.keys
        .map((e) => e as FavoriteItem)
        .toList();
    LocalFavoritesManager().batchDeleteComics(localTable, toBeDeleted);
    _cancel();
  }

  /// 「本地」分类里的删除 = 删本地库（连磁盘文件一起）。
  ///
  /// 这个分类就是本地库本身，把条目藏起来却留着文件，只会变成用户看不见的
  /// 占用。真要保留文件可以去存储管理里清。
  ///
  /// 但要区分两种书：**从网络源下载的**清掉磁盘副本后书还在源站，收藏和
  /// 历史都该留着（可以重新下）；**手工导入的**只在本地存在，连库记录一起
  /// 删。以前这里统一用默认参数，把下载书的收藏记录和阅读历史顺手删了，
  /// 而确认框只写「删除本地漫画和文件」——用户没预期丢这些东西。
  void _deleteLocalComics() {
    var localComics = selectedComics.keys
        .map((e) => e as FavoriteItem)
        .map((e) => LocalManager().find(e.id, e.type))
        .whereType<LocalComic>()
        .toList();
    _cancel();
    if (localComics.isEmpty) {
      return;
    }
    var imported =
        localComics.where((c) => c.comicType == ComicType.local).toList();
    var downloaded =
        localComics.where((c) => c.comicType != ComicType.local).toList();
    if (imported.isNotEmpty) {
      LocalManager().batchDeleteComics(imported);
    }
    if (downloaded.isNotEmpty) {
      // removeFileOnDisk: true, removeFavoriteAndHistory: false
      LocalManager().batchDeleteComics(downloaded, true, false);
    }
    updateComics();
  }
}

class _ReorderComicsPage extends StatefulWidget {
  const _ReorderComicsPage(this.name, this.onReorder);

  final String name;

  final void Function(List<FavoriteItem>) onReorder;

  @override
  State<_ReorderComicsPage> createState() => _ReorderComicsPageState();
}

class _ReorderComicsPageState extends State<_ReorderComicsPage> {
  final _key = GlobalKey();
  var reorderWidgetKey = UniqueKey();
  final _scrollController = ScrollController();
  late var comics = LocalFavoritesManager().getFolderComics(widget.name);
  bool changed = false;

  static int _floatToInt8(double x) {
    return (x * 255.0).round() & 0xff;
  }

  Color lightenColor(Color color, double lightenValue) {
    int red = (_floatToInt8(color.r) + ((255 - color.r) * lightenValue))
        .round();
    int green = (_floatToInt8(color.g) * 255 + ((255 - color.g) * lightenValue))
        .round();
    int blue = (_floatToInt8(color.b) * 255 + ((255 - color.b) * lightenValue))
        .round();

    return Color.fromARGB(_floatToInt8(color.a), red, green, blue);
  }

  @override
  void dispose() {
    if (changed) {
      // Delay to ensure navigation is completed
      Future.delayed(const Duration(milliseconds: 200), () {
        LocalFavoritesManager().reorder(comics, widget.name);
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var type = appdata.settings['comicDisplayMode'];
    var tiles = comics.map((e) {
      var comicSource = e.type.comicSource;
      return ComicTile(
        key: Key(e.hashCode.toString()),
        enableLongPressed: false,
        comic: Comic(
          e.name,
          e.coverPath,
          e.id,
          e.author,
          e.tags,
          type == 'detailed'
              ? "${e.time} | ${comicSource?.name ?? "Unknown"}"
              : "${e.type.comicSource?.name ?? "Unknown"} | ${e.time}",
          comicSource?.key ?? (e.type == ComicType.local ? "local" : "Unknown"),
          null,
          null,
        ),
      );
    }).toList();
    return Scaffold(
      appBar: Appbar(
        title: Text("Reorder".tl),
        actions: [
          Tooltip(
            message: "Information".tl,
            child: IconButton(
              icon: const Icon(Icons.info_outline),
              onPressed: () {
                showInfoDialog(
                  context: context,
                  title: "Reorder".tl,
                  content: "Long press and drag to reorder.".tl,
                );
              },
            ),
          ),
          Tooltip(
            message: "Reverse".tl,
            child: IconButton(
              icon: const Icon(Icons.swap_vert),
              onPressed: () {
                setState(() {
                  comics = comics.reversed.toList();
                  changed = true;
                });
              },
            ),
          ),
        ],
      ),
      body: ReorderableBuilder<FavoriteItem>(
        key: reorderWidgetKey,
        scrollController: _scrollController,
        longPressDelay: App.isDesktop
            ? const Duration(milliseconds: 100)
            : const Duration(milliseconds: 500),
        onReorder: (reorderFunc) {
          changed = true;
          setState(() {
            comics = reorderFunc(comics);
          });
          widget.onReorder(comics);
        },
        dragChildBoxDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: lightenColor(
            Theme.of(context).splashColor.withAlpha(255),
            0.2,
          ),
        ),
        builder: (children) {
          return GridView(
            key: _key,
            controller: _scrollController,
            gridDelegate: SliverGridDelegateWithComics(),
            children: children,
          );
        },
        children: tiles,
      ),
    );
  }
}

class _SelectUpdatePageNum extends StatefulWidget {
  const _SelectUpdatePageNum({
    required this.networkSource,
    this.networkFolder,
    super.key,
  });

  final String? networkFolder;
  final String networkSource;

  @override
  State<_SelectUpdatePageNum> createState() => _SelectUpdatePageNumState();
}

class _SelectUpdatePageNumState extends State<_SelectUpdatePageNum> {
  int updatePageNum = 9999999;

  String get _allPageText => 'All'.tl;

  List<String> get pageNumList => [
    '1',
    '2',
    '3',
    '5',
    '10',
    '20',
    '50',
    '100',
    '200',
    _allPageText,
  ];

  @override
  void initState() {
    updatePageNum =
        appdata.implicitData["local_favorites_update_page_num"] ?? 9999999;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    var source = ComicSource.find(widget.networkSource);
    var sourceName = source?.name ?? widget.networkSource;
    var text = "The folder is Linked to @source".tlParams({
      "source": sourceName,
    });
    if (widget.networkFolder != null && widget.networkFolder!.isNotEmpty) {
      text += "\n${"Source Folder".tl}: ${widget.networkFolder}";
    }

    return Column(
      children: [
        Row(children: [Text(text)]),
        Row(
          children: [
            Text("Update the page number by the latest collection".tl),
            Spacer(),
            Select(
              current: updatePageNum.toString() == '9999999'
                  ? _allPageText
                  : updatePageNum.toString(),
              values: pageNumList,
              minWidth: 48,
              onTap: (index) {
                setState(() {
                  updatePageNum = int.parse(
                    pageNumList[index] == _allPageText
                        ? '9999999'
                        : pageNumList[index],
                  );
                  appdata.implicitData["local_favorites_update_page_num"] =
                      updatePageNum;
                  appdata.writeImplicitData();
                });
              },
            ),
          ],
        ),
      ],
    );
  }
}

class _LocalFavoritesFilterDialog extends StatefulWidget {
  const _LocalFavoritesFilterDialog({
    required this.initReadFilterSelect,
    required this.initSortSelect,
    required this.updateConfig,
  });

  final String initReadFilterSelect;
  final String initSortSelect;

  /// (readFilter, sortSelect)
  final Function(String, String) updateConfig;

  @override
  State<_LocalFavoritesFilterDialog> createState() =>
      _LocalFavoritesFilterDialogState();
}

const readFilterList = ['All', 'UnCompleted', 'Completed'];

/// 收藏排序选项
const sortOptionList = [titleSortDefault, titleSortAZ, titleSortZA];

String _sortLabel(String value) => switch (value) {
  titleSortAZ => "Name A-Z",
  titleSortZA => "Name Z-A",
  _ => "Default",
};

class _LocalFavoritesFilterDialogState
    extends State<_LocalFavoritesFilterDialog> {
  List<String> optionTypes = ['Filter'];
  late var readFilter = widget.initReadFilterSelect;
  late var sortSelect = widget.initSortSelect;
  @override
  Widget build(BuildContext context) {
    Widget tabBar = Material(
      borderRadius: BorderRadius.circular(8),
      child: AppTabBar(
        key: PageStorageKey(optionTypes),
        tabs: optionTypes.map((e) => Tab(text: e.tl, key: Key(e))).toList(),
      ),
    ).paddingTop(context.padding.top);
    return ContentDialog(
      content: DefaultTabController(
        length: 2,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            tabBar,
            TabViewBody(
              children: [
                Column(
                  children: [
                    ListTile(
                      title: Text("Filter reading status".tl),
                      trailing: Select(
                        current: readFilter.tl,
                        values: readFilterList.map((e) => e.tl).toList(),
                        minWidth: 64,
                        onTap: (index) {
                          setState(() {
                            readFilter = readFilterList[index];
                          });
                        },
                      ),
                    ),
                    ListTile(
                      title: Text("Sort".tl),
                      trailing: Select(
                        current: _sortLabel(sortSelect).tl,
                        values: sortOptionList
                            .map((e) => _sortLabel(e).tl)
                            .toList(),
                        minWidth: 96,
                        onTap: (index) {
                          setState(() {
                            sortSelect = sortOptionList[index];
                          });
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () {
            appdata.implicitData["local_favorites_read_filter"] = readFilter;
            appdata.implicitData["local_favorites_sort"] = sortSelect;
            appdata.writeImplicitData();
            if (mounted) {
              Navigator.pop(context);
              widget.updateConfig(readFilter, sortSelect);
            }
          },
          child: Text("Confirm".tl),
        ),
      ],
    );
  }
}
