import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/features/cloud_backup/cloud_backup.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/cloud_storage/remote_storage.dart';

import 'comic_backup_page.dart';

/// 展示备份 / 恢复进度；关闭时返回统计结果。
Future<BackupResult?> showArchiveTransferDialog(
  BuildContext context, {
  required ComicArchiveBatch batch,
  required String title,
}) {
  return showDialog<BackupResult>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ArchiveTransferDialog(batch: batch, title: title),
  );
}

/// 从本地漫画列表直接上传到网盘。
///
/// 入口在本地漫画的多选/长按菜单里：不经过备份页，选中就传；目标位置沿用
/// 「资源上载 → 漫画备份」里配置的那一个。
Future<void> uploadLocalComicsToCloud(
  BuildContext context,
  List<LocalComic> comics,
) async {
  if (comics.isEmpty) return;
  final config = BackupConfig.fromSettings();
  if (!config.isValid) {
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => ContentDialog(
        title: '尚未设置备份位置',
        content: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('上传前需要先选一个网盘和目录。去「资源上载 → 漫画备份」里设置后，再回来上传即可。'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: actionButtonStyle,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
    if (go == true && context.mounted) {
      await context.to(() => const ComicBackupPage());
    }
    return;
  }

  final account = RemoteStorageAccounts.instance.account(
    config.location!.accountId,
  );
  final batch = ComicBackupManager.createBackupBatch(comics);
  final result = await showArchiveTransferDialog(
    context,
    batch: batch,
    title: '上传至网盘',
  );
  if (!context.mounted || result == null) return;

  if (result.authorizationFailed) {
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => ContentDialog(
        title: '网盘拒绝访问',
        content: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '「${account?.name ?? '当前网盘'}」返回了登录/授权失效。可以先去备份页重新授权，或切换到另一个网盘。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('关闭'),
          ),
          FilledButton(
            style: actionButtonStyle,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('去处理'),
          ),
        ],
      ),
    );
    if (go == true && context.mounted) {
      await context.to(() => const ComicBackupPage());
    }
    return;
  }
  if (result.hasFailures) {
    context.showMessage(message: '${result.failed} 部漫画上传失败，可在备份页查看详情');
  } else {
    context.showMessage(
      message: '上传完成：成功 ${result.success}，跳过 ${result.skipped}',
    );
  }
}

/// 备份 / 恢复任务的传输进度对话框。
class _ArchiveTransferDialog extends StatefulWidget {
  const _ArchiveTransferDialog({required this.batch, required this.title});

  final ComicArchiveBatch batch;
  final String title;

  @override
  State<_ArchiveTransferDialog> createState() => _ArchiveTransferDialogState();
}

class _ArchiveTransferDialogState extends State<_ArchiveTransferDialog> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.batch.run());
  }

  @override
  void dispose() {
    widget.batch.dispose();
    super.dispose();
  }

  Widget _stateIcon(ArchiveItemState state) {
    switch (state) {
      case ArchiveItemState.success:
        return const Icon(Icons.check_circle, color: Colors.green);
      case ArchiveItemState.skipped:
        return const Icon(Icons.remove_circle_outline, color: Colors.grey);
      case ArchiveItemState.failed:
        return const Icon(Icons.error, color: Colors.red);
      case ArchiveItemState.cancelled:
        return const Icon(Icons.cancel, color: Colors.grey);
      case ArchiveItemState.working:
        return const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case ArchiveItemState.pending:
        return const Icon(Icons.schedule, color: Colors.grey);
    }
  }

  String _stateLabel(ArchiveItemState state) => switch (state) {
    ArchiveItemState.success => '成功',
    ArchiveItemState.skipped => '已跳过',
    ArchiveItemState.failed => '失败',
    ArchiveItemState.cancelled => '已取消',
    ArchiveItemState.working => '进行中',
    ArchiveItemState.pending => '等待中',
  };

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.batch,
      builder: (context, _) {
        final batch = widget.batch;
        final total = batch.items.length;
        final done =
            batch.count(ArchiveItemState.success) +
            batch.count(ArchiveItemState.skipped) +
            batch.count(ArchiveItemState.failed);
        final progress = total == 0
            ? 0.0
            : (done / total).clamp(0.0, 1.0).toDouble();
        final working = batch.items
            .where((item) => item.state == ArchiveItemState.working)
            .map((item) => item.title)
            .toList();
        final current = working.isNotEmpty
            ? working.join('、')
            : (batch.running ? '准备中…' : '—');

        return ContentDialog(
          title: widget.title,
          dismissible: !batch.running,
          content: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 8),
                Text('进度：$done / $total'),
                Text(
                  '当前：$current',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 300,
                  child: ListView.builder(
                    itemCount: batch.items.length,
                    itemBuilder: (context, index) {
                      final item = batch.items[index];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: _stateIcon(item.state),
                        title: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle:
                            item.state == ArchiveItemState.failed &&
                                item.error != null
                            ? Text(
                                '失败：${batch.errorText(item.error!)}',
                                maxLines: 2,
                              )
                            : Text(_stateLabel(item.state)),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            if (batch.hasRetryableFailures && !batch.running)
              TextButton(
                onPressed: () => unawaited(batch.run(retryFailed: true)),
                child: const Text('重试失败项'),
              ),
            if (batch.running)
              TextButton(onPressed: batch.cancel, child: const Text('取消')),
            if (!batch.running)
              FilledButton(
                style: actionButtonStyle,
                onPressed: () =>
                    Navigator.of(context).pop(BackupResult.fromBatch(batch)),
                child: const Text('关闭'),
              ),
          ],
        );
      },
    );
  }
}
