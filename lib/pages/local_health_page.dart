import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local_health.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

/// 本地书库体检。
///
/// 进页面就开始扫，扫完把四类结果分开展示：残留目录（可挪进回收站）、失效
/// 记录（可删记录）、记录与磁盘不符（可按磁盘重写）、对不上章节表的目录
/// （只报告）。
///
/// 所有「动盘」的操作都摆在同一屏上，且都能反悔：残留目录进回收站而不是直接
/// 删；删记录本来就不碰文件。清空回收站是唯一不可逆的按钮，所以单独放一行、
/// 单独二次确认。
class LocalHealthPage extends StatefulWidget {
  const LocalHealthPage({super.key, this.initialReport});

  /// 测试用：直接给一份报告，跳过真实扫描。
  ///
  /// 扫描要读本地库和整个磁盘，widget 测试里没有这两样；而这一页真正容易
  /// 出问题的是「四类结果同时出现时窄屏会不会溢出」，那部分不需要真实数据。
  @visibleForTesting
  final LocalHealthReport? initialReport;

  static void show(BuildContext context) {
    context.to(() => const LocalHealthPage());
  }

  @override
  State<LocalHealthPage> createState() => _LocalHealthPageState();
}

class _LocalHealthPageState extends State<LocalHealthPage> {
  LocalHealthReport? _report;

  int _done = 0;

  int _total = 0;

  bool _scanning = true;

  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    final preset = widget.initialReport;
    if (preset != null) {
      _report = preset;
      _scanning = false;
      return;
    }
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _report = null;
      _cancelled = false;
      _done = 0;
      _total = 0;
    });
    LocalHealthReport report;
    try {
      report = await LocalLibraryHealth.scan(
        onProgress: (done, total) {
          if (!mounted) {
            return;
          }
          setState(() {
            _done = done;
            _total = total;
          });
        },
        isCancelled: () => _cancelled || !mounted,
      );
    } catch (e, s) {
      Log.error("LocalHealth", "Scan failed: $e", s);
      if (!mounted) {
        return;
      }
      setState(() {
        _scanning = false;
        _report = LocalHealthReport.empty;
      });
      context.showMessage(message: "Scan failed".tl);
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _report = report;
      _scanning = false;
    });
  }

  Future<void> _quarantine(List<OrphanDir> dirs) async {
    final dialog = showLoadingDialog(context, barrierDismissible: false);
    final result = await LocalLibraryHealth.quarantine(dirs);
    dialog.close();
    if (!mounted) {
      return;
    }
    if (result.failed.isEmpty) {
      context.showMessage(
        message: "Moved @a folders to the recycle bin".tlParams({
          "a": result.moved.length,
        }),
      );
    } else {
      context.showMessage(
        message: "Moved @a, @b failed".tlParams({
          "a": result.moved.length,
          "b": result.failed.length,
        }),
      );
    }
    await _scan();
  }

  void _confirmQuarantine(List<OrphanDir> dirs) {
    final bytes = dirs.fold<int>(0, (sum, e) => sum + e.bytes);
    showConfirmDialog(
      context: context,
      title: "Move to recycle bin".tl,
      content:
          "Moved folders stay on the device until you empty the recycle bin. @a will be freed."
              .tlParams({"a": bytesToReadableString(bytes)}),
      confirmText: "Move".tl,
      onConfirm: () => _quarantine(dirs),
    );
  }

  void _confirmRemoveDead(List<DeadEntry> entries) {
    showConfirmDialog(
      context: context,
      title: "Remove records".tl,
      content:
          "Only the records are removed. @a books have no readable pages on this device."
              .tlParams({"a": entries.length}),
      confirmText: "Remove".tl,
      onConfirm: () {
        LocalLibraryHealth.removeDeadEntries(entries);
        _scan();
      },
    );
  }

  void _confirmRepair(List<StaleEntry> entries) {
    showConfirmDialog(
      context: context,
      title: "Repair records".tl,
      content:
          "Downloaded chapters will be rewritten to match what is actually on the device. Files are never deleted."
              .tl,
      confirmText: "Repair".tl,
      onConfirm: () {
        LocalLibraryHealth.repairStaleEntries(entries);
        _scan();
      },
    );
  }

  void _confirmEmptyTrash() {
    showConfirmDialog(
      context: context,
      title: "Empty recycle bin".tl,
      content: "This cannot be undone.".tl,
      confirmText: "Empty".tl,
      btnColor: context.colorScheme.error,
      onConfirm: () async {
        final dialog = showLoadingDialog(context, barrierDismissible: false);
        try {
          await LocalLibraryHealth.emptyTrash();
        } catch (e, s) {
          Log.error("LocalHealth", "Failed to empty trash: $e", s);
        }
        dialog.close();
        if (!mounted) {
          return;
        }
        await _scan();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // 一次算好再交给 builder：放在 itemBuilder 里算的话，每建一行都会把整个
    // 列表（几百个残留目录时更夸张）重新拼一遍。
    final rows = _scanning ? const <Widget>[] : _rows(context);
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(
          title: Text("Library health".tl),
          actions: [
            if (!_scanning)
              IconButton(
                tooltip: "Rescan".tl,
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _scan,
              ),
          ],
        ),
        if (_scanning)
          SliverFillRemaining(hasScrollBody: false, child: _buildScanning())
        else
          SliverList.builder(
            itemCount: rows.length,
            itemBuilder: (context, index) => rows[index],
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _buildScanning() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            _total > 0
                ? "Scanning @a / @b".tlParams({"a": _done, "b": _total})
                : "Scanning...".tl,
          ),
          if (_total > 0) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: 180,
              child: LinearProgressIndicator(
                value: (_done / _total).clamp(0.0, 1.0),
                minHeight: 3,
              ),
            ),
          ],
          const SizedBox(height: 8),
          TextButton(
            onPressed: () {
              setState(() {
                _cancelled = true;
              });
            },
            child: Text("Cancel".tl),
          ),
        ],
      ),
    );
  }

  List<Widget> _rows(BuildContext context) {
    final report = _report ?? LocalHealthReport.empty;
    final rows = <Widget>[];

    rows.add(_buildSummary(context, report));

    if (report.trashBytes > 0) {
      rows.add(
        _sectionHeader(
          context,
          title: "Recycle bin".tl,
          subtitle: "@a · @b batches".tlParams({
            "a": bytesToReadableString(report.trashBytes),
            "b": report.trashDirs,
          }),
          icon: Icons.recycling_rounded,
          action: TextButton(
            onPressed: _confirmEmptyTrash,
            child: Text("Empty".tl),
          ),
        ),
      );
    }

    if (report.orphans.isNotEmpty) {
      rows.add(
        _sectionHeader(
          context,
          title: "Leftover folders".tl,
          subtitle:
              "Folders on the device that no book in the library points to".tl,
          icon: Icons.folder_off_outlined,
          action: TextButton(
            onPressed: () => _confirmQuarantine(report.orphans),
            child: Text("Clean all".tl),
          ),
        ),
      );
      for (final orphan in report.orphans) {
        rows.add(
          ListTile(
            leading: Icon(
              Icons.folder_outlined,
              color: context.colorScheme.onSurfaceVariant,
            ),
            title: Text(
              orphan.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              "@a · @b pages".tlParams({
                "a": bytesToReadableString(orphan.bytes),
                "b": orphan.pages,
              }),
              style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
            ),
            trailing: IconButton(
              tooltip: "Move to recycle bin".tl,
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: () => _confirmQuarantine([orphan]),
            ),
          ),
        );
      }
    }

    if (report.deadEntries.isNotEmpty) {
      rows.add(
        _sectionHeader(
          context,
          title: "Broken records".tl,
          subtitle: "Books that stay in the list but cannot be opened".tl,
          icon: Icons.link_off_rounded,
          action: TextButton(
            onPressed: () => _confirmRemoveDead(report.deadEntries),
            child: Text("Clean all".tl),
          ),
        ),
      );
      for (final entry in report.deadEntries) {
        rows.add(
          ListTile(
            leading: Icon(
              Icons.broken_image_outlined,
              color: context.colorScheme.error,
            ),
            title: Text(
              entry.comic.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              entry.reason == DeadEntryReason.directoryMissing
                  ? "Folder is gone".tl
                  : "No pages on this device".tl,
              style: ts.s12.withColor(context.colorScheme.error),
            ),
            trailing: IconButton(
              tooltip: "Remove record".tl,
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _confirmRemoveDead([entry]),
            ),
          ),
        );
      }
    }

    if (report.staleEntries.isNotEmpty) {
      rows.add(
        _sectionHeader(
          context,
          title: "Records out of sync".tl,
          subtitle: "The downloaded chapter list does not match the device".tl,
          icon: Icons.rule_folder_outlined,
          action: TextButton(
            onPressed: () => _confirmRepair(report.staleEntries),
            child: Text("Repair all".tl),
          ),
        ),
      );
      for (final entry in report.staleEntries) {
        final missing = entry.missingFromDisk.length;
        final extra = entry.missingFromRecord.length;
        rows.add(
          ListTile(
            leading: Icon(
              Icons.inventory_2_outlined,
              color: context.useTextColor(Colors.orange),
            ),
            title: Text(
              entry.comic.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                "@a recorded / @b on device".tlParams({
                  "a": entry.recorded.length,
                  "b": entry.onDisk.length,
                }),
                if (missing > 0)
                  "@a claimed but missing".tlParams({"a": missing}),
                if (extra > 0) "@a found but unrecorded".tlParams({"a": extra}),
              ].join(" · "),
              style: ts.s12.withColor(context.useTextColor(Colors.orange)),
            ),
            trailing: IconButton(
              tooltip: "Repair".tl,
              icon: const Icon(Icons.build_circle_outlined),
              onPressed: () => _confirmRepair([entry]),
            ),
          ),
        );
      }
    }

    if (report.unrecognized.isNotEmpty) {
      rows.add(
        _sectionHeader(
          context,
          title: "Unrecognized folders".tl,
          subtitle:
              "Pages exist but do not match any chapter. Nothing is removed automatically."
                  .tl,
          icon: Icons.help_outline_rounded,
        ),
      );
      for (final entry in report.unrecognized) {
        rows.add(
          ListTile(
            leading: Icon(
              Icons.help_outline_rounded,
              color: context.colorScheme.onSurfaceVariant,
            ),
            title: Text(
              entry.comic.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              "@a folders do not match the chapter list".tlParams({
                "a": entry.dirs,
              }),
              style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
            ),
          ),
        );
      }
    }

    if (report.skippedInFlight > 0) {
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            "@a books are downloading and were skipped".tlParams({
              "a": report.skippedInFlight,
            }),
            style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    if (report.cancelled) {
      rows.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            "Scan cancelled".tl,
            style: ts.s12.withColor(context.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    return rows;
  }

  Widget _buildSummary(BuildContext context, LocalHealthReport report) {
    final colors = context.colorScheme;
    final clean = report.isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
        ),
        child: Row(
          children: [
            Icon(
              clean
                  ? Icons.verified_outlined
                  : Icons.health_and_safety_outlined,
              size: 30,
              color: clean
                  ? colors.primary
                  : context.useTextColor(Colors.orange),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    clean
                        ? "Library is clean".tl
                        : "@a issues found".tlParams({"a": report.issueCount}),
                    style: ts.s20.bold,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    clean
                        ? "@a books checked".tlParams({
                            "a": report.scannedEntries,
                          })
                        : [
                            if (report.orphans.isNotEmpty)
                              "@a can be freed".tlParams({
                                "a": bytesToReadableString(report.orphanBytes),
                              }),
                            "@a books checked".tlParams({
                              "a": report.scannedEntries,
                            }),
                          ].join(" · "),
                    style: ts.s12.withColor(colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    Widget? action,
  }) {
    final colors = context.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: ts.s16.bold)),
              if (action != null) action,
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 26, right: 8, bottom: 4),
            child: Text(
              subtitle,
              style: ts.s12.withColor(colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
