import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/components/downloading_card.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

class DownloadingPage extends StatefulWidget {
  const DownloadingPage({super.key});

  @override
  State<DownloadingPage> createState() => _DownloadingPageState();
}

class _DownloadingPageState extends State<DownloadingPage> {
  /// 顶部汇总只按秒刷新。
  ///
  /// 以前是把每个任务都挂成监听：N 个任务每秒各 notify 一次 → 页面 setState
  /// 一次 → `ListView` 里 N 个卡片全部重建，等于每秒 N² 次 build。任务一多
  /// 这一页就卡得不能看。现在页面只跟「任务增删」走，速度汇总交给一个 ticker，
  /// 单张卡的进度由卡片自己刷。
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    LocalManager().addListener(_onTasksChanged);
    _onTasksChanged();
  }

  @override
  void dispose() {
    LocalManager().removeListener(_onTasksChanged);
    _ticker?.cancel();
    super.dispose();
  }

  void _onTasksChanged() {
    if (!mounted) {
      return;
    }
    var hasRunning = LocalManager().downloadingTasks.any((e) => !e.isPaused);
    if (hasRunning && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) {
          return;
        }
        // 全部停下（下完 / 出错 / 被暂停）就把 ticker 收掉，别留个空转的
        // 定时器一直重建这一页。
        if (!LocalManager().downloadingTasks.any((e) => !e.isPaused)) {
          _ticker?.cancel();
          _ticker = null;
        }
        setState(() {});
      });
    } else if (!hasRunning) {
      _ticker?.cancel();
      _ticker = null;
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final tasks = LocalManager().downloadingTasks;
    return PopUpWidgetScaffold(
      title: "Downloading".tl,
      body: tasks.isEmpty
          ? Center(
              child: Text(
                "No download tasks".tl,
                style: ts.s14,
              ),
            )
          : ListView.builder(
              itemCount: tasks.length + 1,
              itemBuilder: (BuildContext context, int i) {
                if (i == 0) {
                  return buildTop(tasks);
                }
                final task = tasks[i - 1];
                return _DownloadTaskTile(
                  key: ValueKey(task),
                  task: task,
                );
              },
            ),
    );
  }

  Widget buildTop(List<DownloadTask> tasks) {
    var speed = 0;
    var running = 0;
    for (var task in tasks) {
      if (!task.isPaused) {
        running++;
        speed += task.speed;
      }
    }
    final pending =
        tasks.where((e) => e.isPaused && !e.isError && !e.userPaused).length;
    final paused = tasks.where((e) => e.userPaused).length;
    final failed = tasks.where((e) => e.isError).length;

    // 状态摘要：并发之后「第一个任务在干什么」已经不能代表整体，
    // 得把正在跑/排队/暂停/失败分别说清楚，否则用户看到 3 个任务
    // 却只有一个在走进度条，会以为坏了。
    final parts = <String>[
      if (running > 0) "@n downloading".tlParams({"n": running}),
      if (pending > 0) "@n queued".tlParams({"n": pending}),
      if (paused > 0) "@n paused".tlParams({"n": paused}),
      if (failed > 0) "@n failed".tlParams({"n": failed}),
    ];

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  running > 0
                      ? "${bytesToReadableString(speed)}/s"
                      : LocalManager().allPaused
                          ? "Paused".tl
                          : "Queued".tl,
                  style: ts.s18.bold,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  parts.isEmpty
                      ? "@n tasks".tlParams({"n": tasks.length})
                      : parts.join(" · "),
                  style: ts.s12,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LocalManager().allPaused ? Icons.play_arrow : Icons.pause,
                  size: 18,
                ),
                const SizedBox(width: 4),
                Text(LocalManager().allPaused ? "Start".tl : "Pause".tl),
              ],
            ),
            onPressed: () {
              if (LocalManager().allPaused) {
                LocalManager().resumeAll();
              } else {
                LocalManager().pauseAll();
              }
            },
          ),
        ],
      ),
    );
  }
}

class _DownloadTaskTile extends StatefulWidget {
  const _DownloadTaskTile({required this.task, super.key});

  final DownloadTask task;

  @override
  State<_DownloadTaskTile> createState() => _DownloadTaskTileState();
}

class _DownloadTaskTileState extends State<_DownloadTaskTile> {
  late DownloadTask task;

  @override
  void initState() {
    task = widget.task;
    task.addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    task.removeListener(update);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _DownloadTaskTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task != widget.task) {
      task.removeListener(update);
      task = widget.task;
      task.addListener(update);
    }
  }

  void update() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  String get _statusLabel {
    if (task.isError) {
      return "Failed".tl;
    }
    if (!task.isPaused) {
      return "Downloading".tl;
    }
    return task.userPaused ? "Paused".tl : "Queued".tl;
  }

  Color _statusColor(BuildContext context) {
    if (task.isError) {
      return context.colorScheme.error;
    }
    if (!task.isPaused) {
      return context.colorScheme.primary;
    }
    return context.colorScheme.onSurface.toOpacity(0.6);
  }

  /// 剩余百分比。
  ///
  /// 整本体积只能靠已下页外推，长条图多的漫画会凭空多出几个 G；把它摆在
  /// 用户眼前只会让人怀疑下载算错了。进度本身是按页数算的，稳定可靠，
  /// 所以这里只报剩余百分比，不报体积。
  String get _remainingText {
    final left = ((1 - task.progress.clamp(0.0, 1.0)) * 100).round();
    return "@a% left".tlParams({"a": left});
  }

  @override
  Widget build(BuildContext context) {
    final errorText = task.isError ? task.message : null;
    return InkWell(
      key: ValueKey(task),
      // 点整行进本地详情页：这里能看到这本书的章节、已经下好的部分和来源，
      // 比直接甩进阅读器更好退出来。想马上读的话，详情页有「继续阅读」。
      onTap: () => openDownloadingDetail(context, task),
      child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DownloadingCard(
            task: task,
            width: 78,
            coverHeight: 104,
            ringSize: 40,
            showTitle: false,
            enableTap: false,
          ),
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
                        task.title,
                        style: Theme.of(context).textTheme.bodyMedium,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    MenuButton(
                      entries: [
                        if (task.isError)
                          MenuEntry(
                            icon: Icons.refresh,
                            text: "Retry".tl,
                            onClick: () {
                              task.resume();
                              LocalManager().pumpQueue();
                            },
                          ),
                        if (!task.isPaused)
                          MenuEntry(
                            icon: Icons.pause,
                            text: "Pause".tl,
                            onClick: () {
                              task.pause();
                              LocalManager().pumpQueue();
                            },
                          )
                        else
                          MenuEntry(
                            icon: Icons.play_arrow,
                            text: "Start".tl,
                            onClick: () {
                              task.resume();
                              LocalManager().pumpQueue();
                            },
                          ),
                        MenuEntry(
                          icon: Icons.vertical_align_top,
                          text: "Move To First".tl,
                          onClick: () {
                            LocalManager().moveToFirst(task);
                          },
                        ),
                        MenuEntry(
                          icon: Icons.close,
                          text: "Cancel".tl,
                          onClick: () {
                            task.cancel();
                          },
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _statusLabel,
                        style: ts.s12.copyWith(color: _statusColor(context)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        _remainingText,
                        style: ts.s12,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: task.progress,
                    minHeight: 4,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: !task.isPaused && task.speed > 0
                          ? Text(
                              "${bytesToReadableString(task.speed)}/s",
                              style: ts.s12.copyWith(
                                color: context.colorScheme.primary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            )
                          : Text(
                              errorText ?? task.message,
                              style: ts.s12.copyWith(
                                color: errorText != null
                                    ? context.colorScheme.error
                                    : null,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }
}
