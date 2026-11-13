import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/history.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/pages/comic_details_page/comic_page.dart';
import 'package:venera/pages/local_comic_page.dart';
import 'package:venera/utils/translations.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  @override
  void initState() {
    HistoryManager().addListener(onUpdate);
    super.initState();
  }

  @override
  void dispose() {
    HistoryManager().removeListener(onUpdate);
    super.dispose();
  }

  void onUpdate() {
    setState(() {
      comics = HistoryManager().getAll();
      if (multiSelectMode) {
        selectedComics.removeWhere((comic, _) => !comics.contains(comic));
        if (selectedComics.isEmpty) {
          multiSelectMode = false;
        }
      }
    });
  }

  var comics = HistoryManager().getAll();
  var controller = FlyoutController();

  bool multiSelectMode = false;
  Map<History, bool> selectedComics = {};

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

  /// 这条历史对应的 ComicType。
  ///
  /// 源站卸载之后 `sourceKey` 会变成 `Unknown:<type>`，所以不能直接拿
  /// `sourceKey.hashCode` 当类型——那样删的/清的会是另一个「源」。
  ComicType _typeOf(History comic) {
    if (comic.sourceKey.startsWith("Unknown")) {
      return ComicType(int.parse(comic.sourceKey.split(':')[1]));
    }
    if (comic.sourceKey == 'local') {
      return ComicType.local;
    }
    return ComicType(comic.sourceKey.hashCode);
  }

  /// 从列表里移出这一条，**不动阅读进度**。
  ///
  /// 用户删的是「列表里的这一行」，不是「我读过这本书」。想连进度一起清，
  /// 用 [_forgetHistory]（菜单里的「清除阅读进度」）。
  void _removeHistory(History comic) {
    HistoryManager().hide(comic.id, _typeOf(comic));
  }

  /// 真正忘掉：列表 + 进度 + 已读标记一起删。
  void _forgetHistory(History comic) {
    showConfirmDialog(
      context: context,
      title: "Clear Progress".tl,
      content: "This deletes where you stopped in this comic and the chapters marked as read. It cannot be undone."
          .tl,
      confirmText: "Clear".tl,
      btnColor: context.colorScheme.error,
      onConfirm: () {
        HistoryManager().forget(comic.id, _typeOf(comic));
      },
    );
  }

  /// 连阅读进度一起清空。清列表本身不再碰进度，所以这条路要单独走、还要
  /// 再确认一次——它删掉的东西（读到第几页、哪些话读过）没有回收站。
  void _clearWithProgress() {
    showConfirmDialog(
      context: context,
      title: "Clear progress too".tl,
      content:
          "This deletes where you stopped in every comic and the chapters marked as read. It cannot be undone."
              .tl,
      confirmText: "Clear".tl,
      btnColor: context.colorScheme.error,
      onConfirm: () {
        HistoryManager().clearHistory(withProgress: true);
      },
    );
  }

  void _refreshHistory(History comic) async {
    var result = await HistoryManager().refreshHistoryInfo(comic);
    if (result) {
      if (mounted) {
        App.rootContext.showMessage(message: "Refresh Success".tl);
      }
    } else {
      if (mounted) {
        App.rootContext.showMessage(message: "Refresh Failed".tl);
      }
    }
  }

  void _refreshAllHistories() async {
    bool isCanceled = false;
    void onCancel() {
      isCanceled = true;
    }

    var loadingController = showLoadingDialog(
      App.rootContext,
      withProgress: true,
      cancelButtonText: "Cancel".tl,
      onCancel: onCancel,
      message: "Refreshing Histories".tl,
    );

    int success = 0;
    int failed = 0;
    int skipped = 0;

    await for (var progress
        in HistoryManager().refreshAllHistoriesStream()) {
      if (isCanceled) {
        return;
      }
      if (progress.total > 0) {
        loadingController.setProgress(progress.current / progress.total);
      }
      success = progress.success;
      failed = progress.failed;
      skipped = progress.skipped;
    }

    loadingController.close();

    if (mounted) {
      App.rootContext.showMessage(
        message:
            "Refresh Completed: Success @success, Failed @failed, Skipped @skipped"
                .tlParams({
          'success': success,
          'failed': failed,
          'skipped': skipped,
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    List<Widget> selectActions = [
      IconButton(
          icon: const Icon(Icons.select_all),
          tooltip: "Select All".tl,
          onPressed: selectAll
      ),
      IconButton(
          icon: const Icon(Icons.deselect),
          tooltip: "Deselect".tl,
          onPressed: deSelect
      ),
      IconButton(
          icon: const Icon(Icons.flip),
          tooltip: "Invert Selection".tl,
          onPressed: invertSelection
      ),
      IconButton(
        icon: const Icon(Icons.delete),
        tooltip: "Delete".tl,
        onPressed: selectedComics.isEmpty
            ? null
            : () {
                final comicsToDelete = List<History>.from(selectedComics.keys);
                setState(() {
                  multiSelectMode = false;
                  selectedComics.clear();
                });

                // 一次事务批量隐藏，别逐条 notifyListeners（几百条选中会把
                // 整页重建几百遍）。
                HistoryManager().hideAll([
                  for (final comic in comicsToDelete)
                    ComicID(_typeOf(comic), comic.id),
                ]);
              },
      ),
    ];

    List<Widget> normalActions = [
      IconButton(
        icon: const Icon(Icons.refresh),
        tooltip: 'Refresh All Histories'.tl,
        onPressed: _refreshAllHistories,
      ),
      IconButton(
        icon: const Icon(Icons.checklist),
        tooltip: multiSelectMode ? "Exit Multi-Select".tl : "Multi-Select".tl,
        onPressed: () {
          setState(() {
            multiSelectMode = !multiSelectMode;
          });
        },
      ),
      Tooltip(
        message: 'Clear History'.tl,
        child: Flyout(
          controller: controller,
          flyoutBuilder: (context) {
            return FlyoutContent(
              title: 'Clear History'.tl,
              // 宽度写死：这一整段不换行的话 IntrinsicWidth 会把浮层撑到屏幕
              // 外面去（FlyoutContent 只有 minWidth，没有 maxWidth）。
              content: SizedBox(
                width: 260,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "History only records what you opened. Clearing it keeps your reading progress and read marks."
                          .tl,
                    ),
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        foregroundColor: context.colorScheme.error,
                      ),
                      onPressed: () {
                        context.pop();
                        Future.microtask(_clearWithProgress);
                      },
                      child: Text("Clear progress too".tl),
                    ),
                  ],
                ),
              ),
              actions: [
                Button.outlined(
                  onPressed: () {
                    HistoryManager().clearUnfavoritedHistory();
                    App.rootContext.showMessage(
                      message: "History cleared, reading progress kept".tl,
                    );
                    context.pop();
                  },
                  child: Text('Clear Unfavorited'.tl),
                ),
                const SizedBox(width: 4),
                Button.filled(
                  color: context.colorScheme.error,
                  onPressed: () {
                    HistoryManager().clearHistory();
                    App.rootContext.showMessage(
                      message: "History cleared, reading progress kept".tl,
                    );
                    context.pop();
                  },
                  child: Text('Clear'.tl),
                ),
              ],
            );
          },
          child: IconButton(
            icon: const Icon(Icons.clear_all),
            onPressed: () {
              controller.show();
            },
          ),
        ),
      ),
    ];

    return PopScope(
      canPop: !multiSelectMode,
      onPopInvokedWithResult: (didPop, result) {
        if (multiSelectMode) {
          setState(() {
            multiSelectMode = false;
            selectedComics.clear();
          });
        }
      },
      child: Scaffold(
        body: SmoothCustomScrollView(
          slivers: [
            SliverAppbar(
              leading: Tooltip(
                message: multiSelectMode ? "Cancel".tl : "Back".tl,
                child: IconButton(
                  onPressed: () {
                    if (multiSelectMode) {
                      setState(() {
                        multiSelectMode = false;
                        selectedComics.clear();
                      });
                    } else {
                      context.pop();
                    }
                  },
                  icon: multiSelectMode
                      ? const Icon(Icons.close)
                      : const Icon(Icons.arrow_back),
                ),
              ),
              title: multiSelectMode
                  ? Text(selectedComics.length.toString())
                  : Text('History'.tl),
              actions: multiSelectMode ? selectActions : normalActions,
            ),
            SliverGridComics(
              comics: comics,
              selections: selectedComics,
              onLongPressed: null,
              onTap: (c, heroID) {
                final history = c as History;
                if (multiSelectMode) {
                  setState(() {
                    if (selectedComics.containsKey(history)) {
                      selectedComics.remove(history);
                    } else {
                      selectedComics[history] = true;
                    }
                    if (selectedComics.isEmpty) {
                      multiSelectMode = false;
                    }
                  });
                  return;
                }
                // 已经下到本地的书直接进本地详情页。以前一律跳源站详情页，
                // 明明内容就在手机上，却还要联网、还要等源站响应。
                final local = _localComicOf(history);
                if (local != null) {
                  LocalComicPage.open(context, local, heroID: heroID);
                  return;
                }
                context.to(
                  () => ComicPage(
                    id: history.id,
                    sourceKey: history.sourceKey,
                    cover: history.cover,
                    title: history.title,
                    heroID: heroID,
                  ),
                );
              },
              badgeBuilder: (c) {
                return ComicSource.find(c.sourceKey)?.name;
              },
              menuBuilder: (c) {
                return [
                  MenuEntry(
                    icon: Icons.refresh,
                    text: 'Refresh Info'.tl,
                    onClick: () {
                      _refreshHistory(c as History);
                    },
                  ),
                  MenuEntry(
                    icon: Icons.remove,
                    text: 'Remove'.tl,
                    color: context.colorScheme.error,
                    onClick: () {
                      _removeHistory(c as History);
                    },
                  ),
                  MenuEntry(
                    icon: Icons.restart_alt,
                    text: 'Clear Progress'.tl,
                    color: context.colorScheme.error,
                    onClick: () {
                      _forgetHistory(c as History);
                    },
                  ),
                ];
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 这条历史对应的本地漫画（没有下载过就是 null）。
  LocalComic? _localComicOf(History h) {
    try {
      return LocalManager().find(h.id, h.type);
    } catch (e, s) {
      Log.error("History", "Failed to look up local comic: $e\n$s");
      return null;
    }
  }

  String getDescription(History h) {
    var res = "";
    if (h.ep >= 1) {
      res += "Chapter @ep".tlParams({
        "ep": h.ep,
      });
    }
    if (h.page >= 1) {
      if (h.ep >= 1) {
        res += " - ";
      }
      res += "Page @page".tlParams({
        "page": h.page,
      });
    }
    return res;
  }
}
