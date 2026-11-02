import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sliver_tools/sliver_tools.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/image_favorites_card.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/consts.dart';
import 'package:venera/foundation/favorites.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/home_modules.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/comic_source_page.dart';
import 'package:venera/pages/downloading_page.dart';
import 'package:venera/pages/follow_updates_page.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/image_provider/history_image_provider.dart';
import 'package:venera/pages/history_page.dart';
import 'package:venera/pages/reader/reader.dart';
import 'package:venera/pages/image_favorites_page/image_favorites_page.dart';
import 'package:venera/pages/search_page.dart';
import 'package:venera/utils/data_sync.dart';
import 'package:venera/utils/import_comic.dart';
import 'package:venera/utils/translations.dart';

import 'local_comics_page.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    var widget = SmoothCustomScrollView(
      slivers: [
        SliverPadding(padding: EdgeInsets.only(top: context.padding.top)),
        const _SearchBar(),
        for (final module in HomeModules.load()) buildModule(module.id),
        SliverPadding(padding: EdgeInsets.only(top: context.padding.bottom)),
      ],
    );
    return context.width > changePoint ? widget.paddingHorizontal(8) : widget;
  }

  /// 按设置里的顺序与显隐拼装首页模块
  Widget buildModule(String id) {
    return switch (id) {
      'continue_reading' => const _ContinueReading(),
      'sync_data' => const _SyncDataWidget(),
      'history' => const _History(),
      'follow_updates' => const FollowUpdatesWidget(),
      'comic_source' => const _ComicSourceWidget(),
      'local' => const _Local(),
      'image_favorites' => const ImageFavorites(),
      'random_pick' => const _RandomPick(),
      _ => const SliverToBoxAdapter(child: SizedBox.shrink()),
    };
  }
}

class _SearchBar extends StatelessWidget {
  const _SearchBar();

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        height: App.isMobile ? 52 : 46,
        width: double.infinity,
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Material(
          color: context.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(32),
          child: InkWell(
            borderRadius: BorderRadius.circular(32),
            onTap: () {
              context.to(() => const SearchPage());
            },
            child: Row(
              children: [
                const SizedBox(width: 16),
                const Icon(Icons.search),
                const SizedBox(width: 8),
                Text('Search'.tl, style: ts.s16),
                const Spacer(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 首页顶部的「继续阅读」卡片：直接回到上次读到的章节与页码
class _ContinueReading extends StatefulWidget {
  const _ContinueReading();

  @override
  State<_ContinueReading> createState() => _ContinueReadingState();
}

class _ContinueReadingState extends State<_ContinueReading> {
  History? _item;

  void _reload() {
    if (!mounted) return;
    final recent = HistoryManager().getRecent();
    setState(() {
      _item = recent.isEmpty ? null : recent.first;
    });
  }

  @override
  void initState() {
    super.initState();
    final recent = HistoryManager().getRecent();
    _item = recent.isEmpty ? null : recent.first;
    HistoryManager().addListener(_reload);
  }

  @override
  void dispose() {
    HistoryManager().removeListener(_reload);
    super.dispose();
  }

  void _continueRead() {
    final item = _item;
    if (item == null) return;
    context.to(
      () => ReaderWithLoading(
        id: item.id,
        sourceKey: item.type.sourceKey,
        initialEp: item.ep,
        initialPage: item.page,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = _item;
    if (item == null) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final colors = context.colorScheme;
    final maxPage = item.maxPage ?? 0;
    final progress = maxPage > 0
        ? (item.page / maxPage).clamp(0.0, 1.0)
        : null;
    final epText = item.group != null
        ? "Group ${item.group} · Chapter ${item.ep}"
        : "Chapter ${item.ep}";
    return SliverToBoxAdapter(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: _continueRead,
          child: Container(
            margin: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  colors.primaryContainer.withValues(alpha: 0.55),
                  colors.surfaceContainerHigh.withValues(alpha: 0.85),
                ],
              ),
              border: Border.all(
                color: colors.primary.withValues(alpha: 0.20),
                width: 0.8,
              ),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image(
                    image: HistoryImageProvider(item),
                    width: 52,
                    height: 70,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 52,
                      height: 70,
                      color: colors.surfaceContainerHighest,
                      child: Icon(
                        Icons.image_not_supported_outlined,
                        size: 18,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.play_circle_fill_rounded,
                            size: 14,
                            color: colors.primary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            "Continue reading".tl,
                            style: ts.s12.withColor(colors.primary),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ts.s14.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        maxPage > 0
                            ? "$epText · ${item.page}/$maxPage"
                            : epText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ts.s10.withColor(colors.onSurfaceVariant),
                      ),
                      if (progress != null) ...[
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 3,
                            backgroundColor:
                                colors.onSurfaceVariant.withValues(alpha: 0.15),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  color: colors.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SyncDataWidget extends StatefulWidget {
  const _SyncDataWidget();

  @override
  State<_SyncDataWidget> createState() => _SyncDataWidgetState();
}

class _SyncDataWidgetState extends State<_SyncDataWidget>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    DataSync().addListener(update);
    WidgetsBinding.instance.addObserver(this);
    lastCheck = DateTime.now();
  }

  void update() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    super.dispose();
    DataSync().removeListener(update);
    WidgetsBinding.instance.removeObserver(this);
  }

  late DateTime lastCheck;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      if (DateTime.now().difference(lastCheck) > const Duration(minutes: 10)) {
        lastCheck = DateTime.now();
        DataSync().downloadData();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (!DataSync().isEnabled) {
      child = const SliverPadding(padding: EdgeInsets.zero);
    } else if (DataSync().isUploading || DataSync().isDownloading) {
      child = SliverToBoxAdapter(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.primary,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListTile(
            leading: const Icon(Icons.sync),
            title: Text('Syncing Data'.tl),
            trailing: const CircularProgressIndicator(strokeWidth: 2)
                .fixWidth(18)
                .fixHeight(18),
          ),
        ),
      );
    } else {
      child = SliverToBoxAdapter(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ListTile(
            leading: const Icon(Icons.sync),
            title: Text('Sync Data'.tl),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (DataSync().lastError != null)
                  InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () {
                      showDialogMessage(
                        App.rootContext,
                        "Error".tl,
                        DataSync().lastError!,
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: context.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: Colors.red,
                            size: 18,
                          ),
                          const SizedBox(width: 4),
                          Text('Error'.tl, style: ts.s12),
                        ],
                      ),
                    ),
                  ).paddingRight(4),
                IconButton(
                  icon: const Icon(Icons.cloud_upload_outlined),
                  onPressed: () async {
                    DataSync().uploadData();
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.cloud_download_outlined),
                  onPressed: () async {
                    DataSync().downloadData();
                  },
                ),
              ],
            ),
          ),
        ),
      );
    }
    return SliverAnimatedPaintExtent(
      duration: const Duration(milliseconds: 200),
      child: child,
    );
  }
}

class _History extends StatefulWidget {
  const _History();

  @override
  State<_History> createState() => _HistoryState();
}

class _HistoryState extends State<_History> {
  late int count;

  void onHistoryChange() {
    if (mounted) {
      setState(() {
        count = HistoryManager().count();
      });
    }
  }

  @override
  void initState() {
    count = HistoryManager().count();
    HistoryManager().addListener(onHistoryChange);
    super.initState();
  }

  @override
  void dispose() {
    HistoryManager().removeListener(onHistoryChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 首页历史模块仅显示入口与数量，不展示明细
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            context.to(() => const HistoryPage());
          },
          child: SizedBox(
            height: 56,
            child: Row(
              children: [
                Center(
                  child: Text('History'.tl, style: ts.s18),
                ),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(count.toString(), style: ts.s12),
                ),
                const Spacer(),
                const Icon(Icons.arrow_right),
              ],
            ),
          ).paddingHorizontal(16),
        ),
      ),
    );
  }
}

class _Local extends StatefulWidget {
  const _Local();

  @override
  State<_Local> createState() => _LocalState();
}

class _LocalState extends State<_Local> {
  late List<LocalComic> local;
  late int count;

  void onLocalComicsChange() {
    setState(() {
      local = LocalManager().getRecent();
      count = LocalManager().count;
    });
  }

  @override
  void initState() {
    local = LocalManager().getRecent();
    count = LocalManager().count;
    LocalManager().addListener(onLocalComicsChange);
    super.initState();
  }

  @override
  void dispose() {
    LocalManager().removeListener(onLocalComicsChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            context.to(() => const LocalComicsPage());
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 56,
                child: Row(
                  children: [
                    Center(
                      child: Text('Local'.tl, style: ts.s18),
                    ),
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(count.toString(), style: ts.s12),
                    ),
                    const Spacer(),
                    const Icon(Icons.arrow_right),
                  ],
                ),
              ).paddingHorizontal(16),
              if (local.isNotEmpty)
                SizedBox(
                  height: 136,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: local.length,
                    itemBuilder: (context, index) {
                      final heroID = local[index].id.hashCode;
                      return SimpleComicTile(
                        comic: local[index],
                        heroID: heroID,
                        onTap: () {
                          context.to(
                            () => ComicPage(
                              id: local[index].id,
                              sourceKey: local[index].sourceKey,
                              cover: local[index].cover,
                              title: local[index].title,
                              heroID: heroID,
                            ),
                          );
                        },
                      ).paddingHorizontal(8).paddingVertical(2);
                    },
                  ),
                ).paddingHorizontal(8),
              Row(
                children: [
                  if (LocalManager().downloadingTasks.isNotEmpty)
                    Button.outlined(
                      child: Row(
                        children: [
                          if (LocalManager().downloadingTasks.first.isPaused)
                            const Icon(Icons.pause_circle_outline, size: 18)
                          else
                            const _AnimatedDownloadingIcon(),
                          const SizedBox(width: 8),
                          Text("@a Tasks".tlParams({
                            'a': LocalManager().downloadingTasks.length,
                          })),
                        ],
                      ),
                      onPressed: () {
                        showPopUpWidget(context, const DownloadingPage());
                      },
                    ),
                  const Spacer(),
                  Button.filled(
                    onPressed: import,
                    child: Text("Import".tl),
                  ),
                ],
              ).paddingHorizontal(16).paddingVertical(8),
            ],
          ),
        ),
      ),
    );
  }

  void import() {
    showDialog(
      barrierDismissible: false,
      context: App.rootContext,
      builder: (context) {
        return const _ImportComicsWidget();
      },
    );
  }
}

class _ImportComicsWidget extends StatefulWidget {
  const _ImportComicsWidget();

  @override
  State<_ImportComicsWidget> createState() => _ImportComicsWidgetState();
}

class _ImportComicsWidgetState extends State<_ImportComicsWidget> {
  int type = 0;

  bool loading = false;

  var key = GlobalKey();

  var height = 200.0;

  var folders = LocalFavoritesManager().folderNames;

  String? selectedFolder;

  bool copyToLocalFolder = true;

  bool cancelled = false;

  @override
  void dispose() {
    loading = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String info = [
      "Select a directory which contains the comic files.".tl,
      "Select a directory which contains the comic directories.".tl,
      "Select an archive file (cbz, zip, 7z, cb7)".tl,
      "Select a directory which contains multiple archive files.".tl,
      "Select an EhViewer database and a download folder.".tl,
      "Scan the current local path and restore the local database.".tl,
    ][type];
    List<String> importMethods = [
      "Single Comic".tl,
      "Multiple Comics".tl,
      "An archive file".tl,
      "Multiple archive files".tl,
      "EhViewer downloads".tl,
      "Restore local downloads".tl,
    ];

    return ContentDialog(
      dismissible: !loading,
      title: "Import Comics".tl,
      content: loading
          ? SizedBox(
              width: 600,
              height: height,
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            )
          : RadioGroup<int>(
              groupValue: type,
              onChanged: (value) {
                setState(() {
                  type = value ?? type;
                  if (type == 5) {
                    selectedFolder = null;
                  }
                });
              },
              child: Column(
                key: key,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(width: 600),
                  ...List.generate(importMethods.length, (index) {
                    return RadioListTile<int>(
                      title: Text(importMethods[index]),
                      value: index,
                    );
                  }),
                  if (type != 4 && type != 5)
                    ListTile(
                      title: Text("Add to favorites".tl),
                      trailing: Select(
                        current: selectedFolder,
                        values: folders,
                        minWidth: 112,
                        onTap: (v) {
                          setState(() {
                            selectedFolder = folders[v];
                          });
                        },
                      ),
                    ).paddingHorizontal(8),
                  if (!App.isIOS &&
                      !App.isMacOS &&
                      type != 2 &&
                      type != 3 &&
                      type != 5)
                    CheckboxListTile(
                        enabled: true,
                        title: Text("Copy to app local path".tl),
                        value: copyToLocalFolder,
                        onChanged: (v) {
                          setState(() {
                            copyToLocalFolder = !copyToLocalFolder;
                          });
                        }).paddingHorizontal(8),
                  const SizedBox(height: 8),
                  Text(info).paddingHorizontal(24),
                ],
              ),
          ),
      actions: [
        Button.text(
          child: Row(
            children: [
              Icon(
                Icons.help_outline,
                size: 18,
                color: context.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text("help".tl),
            ],
          ),
          onPressed: () {
            launchUrlString(
                "https://github.com/venera-app/venera/blob/master/doc/import_comic.md");
          },
        ).fixWidth(90).paddingRight(8),
        Button.filled(
          isLoading: loading,
          onPressed: selectAndImport,
          child: Text("Select".tl),
        )
      ],
    );
  }

  void selectAndImport() async {
    height = key.currentContext!.size!.height;

    setState(() {
      loading = true;
    });
    var importer = ImportComic(
        selectedFolder: selectedFolder, copyToLocal: copyToLocalFolder);
    var result = switch (type) {
      0 => await importer.directory(true),
      1 => await importer.directory(false),
      2 => await importer.cbz(),
      3 => await importer.multipleCbz(),
      4 => await importer.ehViewer(),
      5 => await importer.localDownloads(),
      int() => true,
    };
    if (result) {
      context.pop();
    } else {
      setState(() {
        loading = false;
      });
    }
  }
}

class _ComicSourceWidget extends StatefulWidget {
  const _ComicSourceWidget();

  @override
  State<_ComicSourceWidget> createState() => _ComicSourceWidgetState();
}

class _ComicSourceWidgetState extends State<_ComicSourceWidget> {
  int get _sourceCount => ComicSource.all().length;

  void onComicSourceChange() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void initState() {
    ComicSourceManager().addListener(onComicSourceChange);
    super.initState();
  }

  @override
  void dispose() {
    ComicSourceManager().removeListener(onComicSourceChange);
    super.dispose();
  }

  int get _availableUpdates {
    int c = 0;
    ComicSourceManager().availableUpdates.forEach((key, version) {
      var source = ComicSource.find(key);
      if (source != null) {
        if (compareSemVer(version, source.version)) {
          c++;
        }
      }
    });
    return c;
  }

  @override
  Widget build(BuildContext context) {
    // 首页漫画源模块仅显示入口与数量，不展示明细
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            context.to(() => const ComicSourcePage());
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 56,
                child: Row(
                  children: [
                    Center(
                      child: Text('Comic Source'.tl, style: ts.s18),
                    ),
                    Container(
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(_sourceCount.toString(), style: ts.s12),
                    ),
                    const Spacer(),
                    const Icon(Icons.arrow_right),
                  ],
                ),
              ).paddingHorizontal(16),
              if (_availableUpdates > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: context.colorScheme.outlineVariant,
                      width: 0.6,
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.update,
                        color: context.colorScheme.primary,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        "@c updates".tlParams({
                          'c': _availableUpdates,
                        }),
                        style: ts.withColor(context.colorScheme.primary),
                      ),
                    ],
                  ),
                )
                    .toAlign(Alignment.centerLeft)
                    .paddingHorizontal(16)
                    .paddingBottom(8),
            ],
          ),
        ),
      ),
    );
  }
}

class _AnimatedDownloadingIcon extends StatefulWidget {
  const _AnimatedDownloadingIcon();

  @override
  State<_AnimatedDownloadingIcon> createState() =>
      __AnimatedDownloadingIconState();
}

class __AnimatedDownloadingIconState extends State<_AnimatedDownloadingIcon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      lowerBound: -1,
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.primary,
                width: 2,
              ),
            ),
          ),
          clipBehavior: Clip.hardEdge,
          child: Transform.translate(
            offset: Offset(0, 18 * _controller.value),
            child: Icon(
              Icons.arrow_downward,
              size: 16,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        );
      },
    );
  }
}

class ImageFavorites extends StatefulWidget {
  const ImageFavorites({super.key});

  @override
  State<ImageFavorites> createState() => _ImageFavoritesState();
}

class _ImageFavoritesState extends State<ImageFavorites> {
  ImageFavoritesComputed? imageFavoritesCompute;

  void refreshImageFavorites() async {
    try {
      imageFavoritesCompute =
          await ImageFavoriteManager.computeImageFavorites();
      if (mounted) {
        setState(() {});
      }
    } catch (e, stackTrace) {
      Log.error("Unhandled Exception", e.toString(), stackTrace);
    }
  }

  @override
  void initState() {
    refreshImageFavorites();
    ImageFavoriteManager().addListener(refreshImageFavorites);
    super.initState();
  }

  @override
  void dispose() {
    ImageFavoriteManager().removeListener(refreshImageFavorites);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool hasData =
        imageFavoritesCompute != null && !imageFavoritesCompute!.isEmpty;
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.6,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            context.to(
              () => const ImageFavoritesPage()
            );
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 56,
                child: Row(
                  children: [
                    Center(
                      child: Text('Image Favorites'.tl, style: ts.s18),
                    ),
                    if (hasData)
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color:
                              Theme.of(context).colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          imageFavoritesCompute!.count.toString(),
                          style: ts.s12,
                        ),
                      ),
                    const Spacer(),
                    const Icon(Icons.arrow_right),
                  ],
                ),
              ).paddingHorizontal(16),
              if (hasData)
                _ImageFavCardStack(
                  comics: imageFavoritesCompute!.allComics,
                ).paddingBottom(4),
            ],
          ),
        ),
      ),
    );
  }

}

/// 首页「今天读什么」：从收藏和历史里随机抽一本。
///
/// 收藏夹堆了几百本、或者翻来翻去不知道看哪本时，抽一张比翻列表轻松。
/// 抽中的卡带一次「翻出来」的缩放+微旋转动效，点一下直接进详情页。
class _RandomPick extends StatefulWidget {
  const _RandomPick();

  @override
  State<_RandomPick> createState() => _RandomPickState();
}

class _RandomPickState extends State<_RandomPick> {
  List<Comic> _pool = const [];

  Comic? _picked;

  /// 换一张时递增，用作 AnimatedSwitcher 的 key，触发翻牌动效
  int _seed = 0;

  @override
  void initState() {
    super.initState();
    _loadPool();
  }

  Future<void> _loadPool() async {
    final map = <String, Comic>{};
    try {
      for (final comic in await LocalFavoritesManager().getAllComicsAsync()) {
        if (comic.sourceKey == 'local') continue;
        map['${comic.sourceKey}/${comic.id}'] = comic;
      }
    } catch (e) {
      Log.error("RandomPick", "Failed to load favorites: $e");
    }
    try {
      for (final comic in HistoryManager().getAll()) {
        if (comic.sourceKey == 'local') continue;
        map.putIfAbsent('${comic.sourceKey}/${comic.id}', () => comic);
      }
    } catch (e) {
      Log.error("RandomPick", "Failed to load history: $e");
    }
    if (!mounted) return;
    setState(() {
      _pool = map.values.toList();
      _picked = _pick();
    });
  }

  Comic? _pick() {
    if (_pool.isEmpty) return null;
    if (_pool.length == 1) return _pool.first;
    final random = Random();
    var next = _pool[random.nextInt(_pool.length)];
    // 别连续抽到同一本
    var guard = 0;
    while (_picked != null &&
        next.id == _picked!.id &&
        next.sourceKey == _picked!.sourceKey &&
        guard++ < 8) {
      next = _pool[random.nextInt(_pool.length)];
    }
    return next;
  }

  void _draw() {
    setState(() {
      _picked = _pick();
      _seed++;
      HapticFeedback.selectionClick();
    });
  }

  void _open(Comic comic) {
    App.mainNavigatorKey?.currentContext?.to(
      () => ComicPage(
        id: comic.id,
        sourceKey: comic.sourceKey,
        cover: comic.cover,
        title: comic.title,
      ),
    );
  }

  ImageProvider _providerOf(Comic comic) {
    if (comic is History) {
      return HistoryImageProvider(comic);
    }
    return CachedImageProvider(
      comic.cover,
      sourceKey: comic.sourceKey,
      cid: comic.id,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = context.colorScheme;
    final picked = _picked;
    return SliverToBoxAdapter(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: cs.outlineVariant, width: 0.6),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  Icon(Icons.casino_outlined, size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  Text('Today Picks'.tl, style: ts.s18),
                  const Spacer(),
                  if (picked != null)
                    IconButton(
                      onPressed: _draw,
                      tooltip: 'Draw again'.tl,
                      icon: const Icon(Icons.refresh, size: 20),
                    ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: picked == null
                  ? Container(
                      height: 78,
                      alignment: Alignment.center,
                      child: Text(
                        'Favorite or read something first'.tl,
                        style: ts.s14.withColor(cs.onSurfaceVariant),
                      ),
                    )
                  : AnimatedSwitcher(
                      duration: const Duration(milliseconds: 340),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeIn,
                      transitionBuilder: (child, animation) {
                        final scale = CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOutBack,
                        );
                        return FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(
                            scale: Tween<double>(begin: 0.86, end: 1.0)
                                .animate(scale),
                            child: RotationTransition(
                              turns: Tween<double>(begin: -0.012, end: 0.0)
                                  .animate(scale),
                              child: child,
                            ),
                          ),
                        );
                      },
                      child: KeyedSubtree(
                        key: ValueKey(_seed),
                        child: _buildCard(context, picked),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(BuildContext context, Comic comic) {
    final cs = context.colorScheme;
    final source = ComicSource.find(comic.sourceKey)?.name ?? comic.sourceKey;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => _open(comic),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 58,
                height: 78,
                child: AnimatedImage(
                  image: _providerOf(comic),
                  fit: BoxFit.cover,
                  cacheWidth: 240,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    comic.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: ts.s16.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    source,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts.s12.withColor(cs.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 20, color: cs.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// 首页图片收藏卡片堆：每张卡就是「图片收藏」页里的一个条目，
/// 长按后上下滑动切换，首尾循环。
class _ImageFavCardStack extends StatefulWidget {
  const _ImageFavCardStack({required this.comics});

  final List<ImageFavoritesComic> comics;

  @override
  State<_ImageFavCardStack> createState() => _ImageFavCardStackState();
}

class _ImageFavCardStackState extends State<_ImageFavCardStack>
    with SingleTickerProviderStateMixin {
  /// 卡片内容完全复用 [ImageFavoritesCard]（与图片收藏页同一份实现），
  /// 这里只固定外层高度：标题两行 54.4 + 缩略图条 145 + 底部行 22.4
  /// + 卡片外边距 16 ≈ 238，留一点余量给滑动时的露出。
  static const _cardHeight = 240.0;

  static const _switchThreshold = 16.0;

  int _index = 0;

  double _drag = 0;

  double _settleFrom = 0;

  double _settleTo = 0;

  VoidCallback? _onSettled;

  late final AnimationController _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 140),
  )..addStatusListener(_onSettleStatus);

  /// 长按 300ms 即可拖动（系统默认 500ms）。工厂函数只创建一次，
  /// 避免每帧重建 recognizer 打断进行中的手势。
  late final Map<Type, GestureRecognizerFactory> _gestures = {
    TapGestureRecognizer:
        GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
      () => TapGestureRecognizer(),
      (instance) {
        instance.onTap = () => _openComic(widget.comics[_index]);
      },
    ),
    LongPressGestureRecognizer:
        GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
      () => LongPressGestureRecognizer(
        duration: const Duration(milliseconds: 300),
        debugOwner: this,
      ),
      (instance) {
        instance
          ..onLongPressStart = (_) {
            HapticFeedback.selectionClick();
            setState(() {
              _drag = 0;
            });
          }
          ..onLongPressMoveUpdate = (details) {
            setState(() {
              _drag = details.offsetFromOrigin.dy
                  .clamp(-_cardHeight, _cardHeight)
                  .toDouble();
            });
          }
          ..onLongPressEnd = (_) => _handleLongPressEnd();
      },
    ),
  };

  void _openComic(ImageFavoritesComic comic) {
    App.mainNavigatorKey?.currentContext?.to(
      () => ComicPage(id: comic.id, sourceKey: comic.sourceKey),
    );
  }

  void _openReader(ImageFavoritesComic comic, ImageFavorite image) {
    App.rootContext.to(
      () => ReaderWithLoading(
        id: comic.id,
        sourceKey: comic.sourceKey,
        initialEp: image.ep,
        initialPage: image.page,
      ),
    );
  }

  @override
  void didUpdateWidget(covariant _ImageFavCardStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_index >= widget.comics.length) {
      _index = widget.comics.isEmpty ? 0 : widget.comics.length - 1;
    }
  }

  @override
  void dispose() {
    _settle.dispose();
    super.dispose();
  }

  void _onSettleStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      final done = _onSettled;
      _onSettled = null;
      done?.call();
    }
  }

  double get _offset {
    if (_settle.isAnimating) {
      final t = Curves.easeOutCubic.transform(_settle.value);
      return _settleFrom + (_settleTo - _settleFrom) * t;
    }
    return _drag;
  }

  void _animateTo(double target, VoidCallback onDone) {
    _settleFrom = _offset;
    _settleTo = target;
    _onSettled = onDone;
    _settle.forward(from: 0);
  }

  void _handleLongPressEnd() {
    final n = widget.comics.length;
    var target = _index;
    if (n > 1) {
      if (_drag <= -_switchThreshold) {
        target = (_index + 1) % n;
      } else if (_drag >= _switchThreshold) {
        target = (_index - 1 + n) % n;
      }
    }
    if (target != _index) {
      _animateTo(_drag < 0 ? -_cardHeight : _cardHeight, () {
        if (!mounted) return;
        HapticFeedback.lightImpact();
        setState(() {
          _index = target;
          _drag = 0;
        });
      });
    } else {
      _animateTo(0, () {
        if (!mounted) return;
        setState(() {
          _drag = 0;
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.comics.length;
    if (n == 0) {
      return const SizedBox(height: _cardHeight);
    }
    return AnimatedBuilder(
      animation: _settle,
      builder: (context, _) {
        final offset = _offset;
        // 上滑露出下一张、下滑露出上一张；首尾循环
        final behind = n <= 1
            ? null
            : (offset > 0 ? (_index - 1 + n) % n : (_index + 1) % n);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: _cardHeight,
              child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  // 注意：后卡必须始终在树上（1.2.3 的教训：动态增删
                  // Stack 子节点会让没有 key 的 element 错配，挂着手势的
                  // 前卡被销毁重建，长按一动就断）。这里用
                  // Visibility(maintainState) 让后卡静止时只保留状态、
                  // 不参与布局绘制，拖动时立即恢复，手势完全不受影响。
                  if (behind != null)
                    Positioned.fill(
                      key: const ValueKey('behind'),
                      child: Visibility(
                        visible: offset != 0,
                        maintainState: true,
                        maintainAnimation: true,
                        // 后卡随拖动从 94% 放大到 100%：像真的一叠卡片，
                        // 前卡被抽走时下一张自己顶上来，而不是突然跳到顶层。
                        child: Transform.scale(
                          alignment: Alignment.topCenter,
                          scale: 0.94 +
                              0.06 *
                                  (offset.abs() / 56).clamp(0.0, 1.0),
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: _buildCard(behind),
                          ),
                        ),
                      ),
                    ),
                  Positioned.fill(
                    key: const ValueKey('front'),
                    child: _buildFront(offset),
                  ),
                ],
              ),
            ),
            if (n > 1) ...[
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.swipe_vertical_rounded,
                    size: 13,
                    color: context.colorScheme.onSurfaceVariant.toOpacity(0.7),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    "Hold and swipe up or down to switch".tl,
                    style: TextStyle(
                      fontSize: 10,
                      color: context.colorScheme.onSurfaceVariant.toOpacity(0.7),
                    ),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildFront(double offset) {
    // 被抽走的过程中轻微缩小 + 旋转，离开得更有体积感。
    final progress = (offset.abs() / _cardHeight).clamp(0.0, 1.0);
    return RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: _gestures,
      // 前卡保持完全不透明，只做位移+微旋转：一旦半透明，
      // 下面那张卡的标题和标签就会透上来，两行字叠着看不清。
      child: Transform.translate(
        offset: Offset(0, offset),
        child: Transform.rotate(
          angle: offset / _cardHeight * 0.03,
          child: Transform.scale(
            alignment: Alignment.topCenter,
            scale: 1 - 0.05 * progress,
            child: Align(
              alignment: Alignment.topCenter,
              child: _buildCard(_index),
            ),
          ),
        ),
      ),
    );
  }

  /// 与图片收藏页完全一致的条目卡，只把点击行为接到首页的跳转上。
  Widget _buildCard(int index) {
    final comic = widget.comics[index];
    return ImageFavoritesCard(
      comic: comic,
      reserveTitleLines: 2,
      enableHero: false,
      // 前后两张卡位置完全重合，必须给前卡一层不透明底色，
      // 否则后卡的标题/标签会透出来和前卡文字叠在一起。
      backgroundColor: context.colorScheme.surface,
      onThumbTap: (image) => _openReader(comic, image),
    );
  }
}
