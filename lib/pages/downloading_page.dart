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
  /// 已挂上监听的任务。多任务并发下，顶部速度要覆盖全部在跑的任务，
  /// 不能只盯第一个。
  final List<DownloadTask> _listened = [];

  @override
  void initState() {
    LocalManager().addListener(update);
    _syncListeners();
    super.initState();
  }

  @override
  void dispose() {
    LocalManager().removeListener(update);
    for (var task in _listened) {
      task.removeListener(update);
    }
    super.dispose();
  }

  void _syncListeners() {
    final tasks = LocalManager().downloadingTasks;
    for (var task in List.of(_listened)) {
      if (!tasks.contains(task)) {
        task.removeListener(update);
        _listened.remove(task);
      }
    }
    for (var task in tasks) {
      if (!_listened.contains(task)) {
        task.addListener(update);
        _listened.add(task);
      }
    }
  }

  void update() {
    if (!mounted) {
      return;
    }
    _syncListeners();
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

  /// 容量文案。总量是估算的（逐页拉取时无法预知后面几页多大），所以
  /// 前面加个「≈」，别让用户把它当精确值。
  String get _sizeText {
    if (task.downloadedBytes <= 0) {
      return "--";
    }
    final downloaded = bytesToReadableString(task.downloadedBytes);
    if (task.totalBytes <= task.downloadedBytes) {
      return downloaded;
    }
    return "$downloaded / ≈${bytesToReadableString(task.totalBytes)}";
  }

  @override
  Widget build(BuildContext context) {
    final errorText = task.isError ? task.message : null;
    return InkWell(
      key: ValueKey(task),
      // 支持边下边看之后，任务行不点一下太浪费：点进去直接读已下好的部分。
      onTap: () => openDownloadingTask(context, task),
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
                        _sizeText,
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
                    const SizedBox(width: 8),
                    Text(
                      "${(task.progress * 100).toStringAsFixed(0)}%",
                      style: ts.s12.bold,
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
