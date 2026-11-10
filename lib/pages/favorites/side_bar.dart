part of 'favorites_page.dart';

class _LeftBar extends StatefulWidget {
  const _LeftBar({
    this.favPage,
    this.onSelected,
    this.withAppbar = false,
    this.onGlassBackground = false,
  });

  final _FavoritesPageState? favPage;

  final VoidCallback? onSelected;

  final bool withAppbar;

  /// 侧栏是浮在玻璃上的抽屉（而不是贴着页面的实色栏）。
  ///
  /// 玻璃再实也是半透的，默认继承来的文字颜色在浅色主题下只有 87%
  /// alpha，压到背后的封面上就散了。这个开关把这里所有前景色提到满值，
  /// 并给选中态加重底色，保证字和图标始终压在自家的底板上。
  final bool onGlassBackground;

  @override
  State<_LeftBar> createState() => _LeftBarState();
}

class _LeftBarState extends State<_LeftBar> implements FolderList {
  late _FavoritesPageState favPage;

  var folders = <String>[];

  var networkFolders = <String>[];

  void findNetworkFolders() {
    networkFolders.clear();
    var all = ComicSource.all()
        .where((e) => e.favoriteData != null)
        .map((e) => e.favoriteData!.key)
        .toList();
    var settings = appdata.settings['favorites'] as List;
    for (var p in settings) {
      if (all.contains(p) && !networkFolders.contains(p)) {
        networkFolders.add(p);
      }
    }
  }

  @override
  void initState() {
    favPage =
        widget.favPage ??
        context.findAncestorStateOfType<_FavoritesPageState>()!;
    favPage.folderList = this;
    folders = LocalFavoritesManager().folderNames;
    findNetworkFolders();
    appdata.settings.addListener(updateFolders);
    LocalFavoritesManager().addListener(updateFolders);
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
    appdata.settings.removeListener(updateFolders);
    LocalFavoritesManager().removeListener(updateFolders);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        border: Border(
          right: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Column(
        children: [
          if (widget.withAppbar)
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  const CloseButton(),
                  const SizedBox(width: 8),
                  Text("Folders".tl, style: ts.s18),
                ],
              ),
            ).paddingTop(context.padding.top),
          Expanded(
            child: ListView.builder(
              padding: widget.withAppbar
                  ? EdgeInsets.zero
                  : EdgeInsets.only(top: context.padding.top),
              // Local 标题 + 全部 + 自建分类 + 已阅 + 已下载（三个内置项固定在
              // 本地分组底部）+ Network 标题 + 网络收藏
              itemCount: folders.length + networkFolders.length + 5,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return buildLocalTitle();
                }
                index--;
                if (index == 0) {
                  return buildLocalFolder(_localAllFolderLabel);
                }
                index--;
                if (index < folders.length) {
                  return buildLocalFolder(folders[index]);
                }
                index -= folders.length;
                if (index == 0) {
                  return buildLocalFolder(
                    _localReadFolderLabel,
                    withTopGap: true,
                  );
                }
                index--;
                if (index == 0) {
                  return buildLocalFolder(_localDownloadedFolderLabel);
                }
                index--;
                if (index == 0) {
                  return buildNetworkTitle();
                }
                index--;
                return buildNetworkFolder(networkFolders[index]);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget buildLocalTitle() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(Icons.local_activity, color: context.colorScheme.secondary),
          const SizedBox(width: 12),
          Text(
            "Local".tl,
            style: widget.onGlassBackground
                ? TextStyle(color: context.colorScheme.onSurface)
                : null,
          ),
          const Spacer(),
          MenuButton(
            entries: [
              MenuEntry(
                icon: Icons.add,
                text: 'Create Folder'.tl,
                onClick: () {
                  newFolder().then((value) {
                    setState(() {
                      folders = LocalFavoritesManager().folderNames;
                    });
                  });
                },
              ),
              MenuEntry(
                icon: Icons.reorder,
                text: 'Sort'.tl,
                onClick: () {
                  sortFolders().then((value) {
                    setState(() {
                      folders = LocalFavoritesManager().folderNames;
                    });
                  });
                },
              ),
            ],
          ),
        ],
      ).paddingHorizontal(16),
    );
  }

  Widget buildNetworkTitle() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud, color: context.colorScheme.secondary),
          const SizedBox(width: 12),
          Text(
            "Network".tl,
            style: widget.onGlassBackground
                ? TextStyle(color: context.colorScheme.onSurface)
                : null,
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              showPopUpWidget(App.rootContext, setFavoritesPagesWidget());
            },
          ),
        ],
      ).paddingHorizontal(16),
    );
  }

  Widget buildLocalFolder(String name, {bool withTopGap = false}) {
    bool isSelected = name == favPage.folder && !favPage.isNetwork;
    int count = 0;
    if (name == _localAllFolderLabel) {
      count = LocalFavoritesManager().totalComics;
    } else if (name == _localReadFolderLabel) {
      count = LocalFavoritesManager().readCount();
    } else if (name == _localDownloadedFolderLabel) {
      count = LocalFavoritesManager().downloadedCount();
    } else {
      count = LocalFavoritesManager().folderComics(name);
    }
    var folderName = switch (name) {
      _localAllFolderLabel => "All".tl,
      _localReadFolderLabel => "Finished Reading".tl,
      _localDownloadedFolderLabel => "Downloaded".tl,
      _ => getFavoriteDataOrNull(name)?.title ?? name,
    };
    bool isAll = name == _localAllFolderLabel;
    bool isRead = name == _localReadFolderLabel;
    bool isDownloaded = name == _localDownloadedFolderLabel;
    // 自建分类整体缩进一层，与「全部」「已阅」「已下载」这三个内置项区分开
    bool isBuiltin = isAll || isRead || isDownloaded;
    var leadingIcon = switch (name) {
      _localAllFolderLabel => Icons.apps,
      _localReadFolderLabel => Icons.done_all,
      _localDownloadedFolderLabel => Icons.download_done,
      _ => Icons.folder_outlined,
    };
    // 选中时图标与文字都用主题色；未选中时图标用次要色。
    // 玻璃抽屉上未选中项也要给实色，否则半透明黑字压在背后的封面上会散。
    Color? fgColor;
    if (isSelected) {
      fgColor = context.colorScheme.primary;
    } else if (isRead || isDownloaded) {
      fgColor = context.colorScheme.onSurfaceVariant;
    } else if (widget.onGlassBackground) {
      fgColor = context.colorScheme.onSurface;
    }
    var iconColor = isSelected
        ? context.colorScheme.primary
        : ((isRead || isDownloaded)
              ? context.colorScheme.onSurfaceVariant.toOpacity(0.8)
              : context.colorScheme.onSurfaceVariant);
    // 玻璃上的选中底板要比贴页面时重一档，否则「选中了哪一项」看不出来
    final selectedAlpha = widget.onGlassBackground ? 0.72 : 0.36;
    return Padding(
      padding: EdgeInsets.only(top: withTopGap ? 4 : 0),
      child: InkWell(
        onTap: () {
          if (isSelected) {
            return;
          }
          favPage.setFolder(false, name);
          widget.onSelected?.call();
        },
        child: Container(
          height: 42,
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: isSelected
                ? context.colorScheme.primaryContainer.toOpacity(selectedAlpha)
                : null,
            border: Border(
              left: BorderSide(
                color: isSelected
                    ? context.colorScheme.primary
                    : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          padding: EdgeInsets.only(left: isBuiltin ? 16 : 34),
          child: Row(
            children: [
              Icon(leadingIcon, size: 16, color: iconColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  folderName,
                  style: TextStyle(color: fgColor),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                margin: EdgeInsets.only(right: 8),
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: isSelected
                      ? context.colorScheme.primaryContainer.toOpacity(0.6)
                      : context.colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  count.toString(),
                  style: TextStyle(
                    fontSize: 11,
                    color: isSelected
                        ? context.colorScheme.onPrimaryContainer
                        : context.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget buildNetworkFolder(String key) {
    var data = getFavoriteDataOrNull(key);
    if (data == null) {
      return const SizedBox();
    }
    bool isSelected = key == favPage.folder && favPage.isNetwork;
    return InkWell(
      onTap: () {
        if (isSelected) {
          return;
        }
        favPage.setFolder(true, key);
        widget.onSelected?.call();
      },
      child: Container(
        height: 42,
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: isSelected
              ? context.colorScheme.primaryContainer
                  .toOpacity(widget.onGlassBackground ? 0.72 : 0.36)
              : null,
          border: Border(
            left: BorderSide(
              color: isSelected
                  ? context.colorScheme.primary
                  : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        padding: const EdgeInsets.only(left: 16),
        child: Text(
          data.title,
          style: widget.onGlassBackground
              ? TextStyle(color: context.colorScheme.onSurface)
              : null,
        ),
      ),
    );
  }

  @override
  void update() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void updateFolders() {
    if (!mounted) return;
    setState(() {
      folders = LocalFavoritesManager().folderNames;
      findNetworkFolders();
    });
  }
}
