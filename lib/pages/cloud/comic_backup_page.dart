import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/features/cloud_backup/cloud_backup.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/cloud_storage/remote_storage.dart';
import 'package:venera/pages/cloud/remote_location_fields.dart';

/// 把本地漫画打包成 CBZ 备份到网盘，并从云端恢复的管理页面。
class ComicBackupPage extends StatefulWidget {
  const ComicBackupPage({super.key});

  @override
  State<ComicBackupPage> createState() => _ComicBackupPageState();
}

class _ComicBackupPageState extends State<ComicBackupPage> {
  late BackupConfig _config;
  List<BackupFile> _backups = <BackupFile>[];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _config = BackupConfig.fromSettings();
    unawaited(_loadBackups());
  }

  String _formatSize(int bytes) {
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        text,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      ),
    );
  }

  Future<void> _loadBackups() async {
    if (!_config.isValid) {
      if (mounted) {
        setState(() {
          _backups = <BackupFile>[];
          _loading = false;
        });
      }
      return;
    }
    if (mounted) setState(() => _loading = true);
    try {
      final res = await ComicBackupManager.listBackups();
      if (!mounted) return;
      setState(() {
        _backups = res.error ? <BackupFile>[] : (res.dataOrNull ?? <BackupFile>[]);
        _loading = false;
      });
      if (res.error) {
        context.showMessage(message: '获取云端备份失败，请检查网盘连接');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      context.showMessage(message: '获取云端备份失败');
    }
  }

  Future<void> _showLocationDialog() async {
    final current = _config.location;
    StorageAccount? chosenAccount = current == null
        ? null
        : RemoteStorageAccounts.instance.account(current.accountId);
    List<String> directories = current == null
        ? <String>[]
        : <String>[current.directory];

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return ContentDialog(
              title: '设置备份位置',
              content: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: RemoteLocationFields(
                  accountId: chosenAccount?.id,
                  directories: directories,
                  multiSelect: false,
                  onChanged: (account, selected) {
                    setDialogState(() {
                      chosenAccount = account;
                      directories = selected;
                    });
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  style: actionButtonStyle,
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
    if (saved != true || !mounted) return;

    if (chosenAccount == null || directories.isEmpty) {
      showCenterHint(context, '请选择网盘账号和目录');
      return;
    }
    try {
      final location = RemoteLocation(
        accountId: chosenAccount!.id,
        directory: directories.first,
      );
      final config = BackupConfig(
        location: location,
        remotePath: location.directory,
      );
      await BackupConfig.saveToSettings(config);
      // 备份目录同时登记成在线漫画库：上传完的 CBZ 立刻能在发现页读到。
      await ensureBackupLibrary(config);
      if (!mounted) return;
      setState(() => _config = BackupConfig.fromSettings());
      context.showMessage(message: '备份位置已保存，并已加入在线漫画库');
      unawaited(_loadBackups());
    } catch (_) {
      if (mounted) context.showMessage(message: '保存备份位置失败');
    }
  }

  Future<void> _clearConfig() async {
    try {
      await removeBackupLibraryIfOwned(_config);
      await BackupConfig.clearSettings();
      if (!mounted) return;
      setState(() => _config = BackupConfig.fromSettings());
      context.showMessage(message: '已清除备份位置');
      unawaited(_loadBackups());
    } catch (_) {
      if (mounted) context.showMessage(message: '清除备份配置失败');
    }
  }

  Widget _buildLocationSection() {
    final location = _config.location;
    if (location == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const Expanded(child: Text('尚未设置备份位置')),
            Button.filled(
              onPressed: _showLocationDialog,
              child: const Text('设置备份位置'),
            ),
          ],
        ),
      );
    }
    final accountName =
        RemoteStorageAccounts.instance.account(location.accountId)?.name ??
        '账号不可用';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.cloud_done_outlined),
            title: Text('账号：$accountName'),
            subtitle: Text('目录：${location.directory}'),
          ),
          Row(
            children: [
              Button.outlined(
                onPressed: _showLocationDialog,
                child: const Text('更改'),
              ),
              const SizedBox(width: 12),
              Button.text(
                onPressed: _clearConfig,
                child: const Text('清除配置'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<List<LocalComic>?> _pickLocalComics() async {
    final List<LocalComic> comics;
    try {
      comics = LocalManager().getComics(LocalSortType.name);
    } catch (_) {
      context.showMessage(message: '读取本地漫画失败');
      return null;
    }
    if (comics.isEmpty) {
      context.showMessage(message: '本地漫画库为空');
      return null;
    }
    final selected = <int>{};
    return showDialog<List<LocalComic>>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return ContentDialog(
              title: '选择本地漫画',
              content: SizedBox(
                height: 320,
                child: ListView.builder(
                  itemCount: comics.length,
                  itemBuilder: (context, index) {
                    final comic = comics[index];
                    return CheckboxListTile(
                      value: selected.contains(index),
                      title: Text(
                        comic.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onChanged: (value) {
                        setDialogState(() {
                          if (value == true) {
                            selected.add(index);
                          } else {
                            selected.remove(index);
                          }
                        });
                      },
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  child: const Text('取消'),
                ),
                FilledButton(
                  style: actionButtonStyle,
                  onPressed: () => Navigator.of(
                    ctx,
                  ).pop(selected.map((i) => comics[i]).toList()),
                  child: const Text('确定'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _startBackup() async {
    if (!_config.isValid) {
      context.showMessage(message: '请先设置备份位置');
      return;
    }
    final picked = await _pickLocalComics();
    if (!mounted || picked == null || picked.isEmpty) return;
    try {
      final batch = ComicBackupManager.createBackupBatch(picked);
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            _ArchiveTransferDialog(batch: batch, title: '备份进度'),
      );
    } catch (_) {
      if (mounted) context.showMessage(message: '创建备份任务失败');
    }
  }

  Future<void> _startRestore(BackupFile file) async {
    try {
      final batch = ComicBackupManager.createRestoreBatch(<BackupFile>[file]);
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            _ArchiveTransferDialog(batch: batch, title: '恢复进度'),
      );
    } catch (_) {
      if (mounted) context.showMessage(message: '创建恢复任务失败');
    }
  }

  Future<void> _confirmDelete(BackupFile file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return ContentDialog(
          title: '删除备份',
          content: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('确定要删除备份「${file.name}」吗？删除后无法恢复。'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              style: actionButtonStyle.copyWith(
                backgroundColor: WidgetStatePropertyAll(
                  Theme.of(dialogContext).colorScheme.error,
                ),
              ),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !mounted) return;
    try {
      final res = await ComicBackupManager.deleteBackup(file);
      if (!mounted) return;
      if (res.error) {
        context.showMessage(message: '删除备份失败，请检查网盘连接');
      } else {
        context.showMessage(message: '备份已删除');
        unawaited(_loadBackups());
      }
    } catch (_) {
      if (mounted) context.showMessage(message: '删除备份失败');
    }
  }

  Future<void> _showBackupActions(BackupFile file) async {
    final choice = await showDialog<String?>(
      context: context,
      builder: (dialogContext) {
        return ContentDialog(
          title: '备份操作',
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.restore),
                title: const Text('恢复到本地'),
                onTap: () => Navigator.of(dialogContext).pop('restore'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('删除'),
                onTap: () => Navigator.of(dialogContext).pop('delete'),
              ),
              ListTile(
                leading: const Icon(Icons.cancel_outlined),
                title: const Text('取消'),
                onTap: () => Navigator.of(dialogContext).pop(),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted) return;
    if (choice == 'restore') {
      await _startRestore(file);
    } else if (choice == 'delete') {
      await _confirmDelete(file);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: const Text('漫画备份'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _loadBackups,
          ),
        ],
      ),
      body: SmoothCustomScrollView(
        slivers: [
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    '把本地漫画打包成 CBZ 备份到夸克网盘。备份目录会自动加入在线漫画库，'
                    '上传完成后即可在发现页直接阅读；也可在下方恢复到本地。已有同名备份不会被覆盖。',
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(child: _sectionTitle('备份位置')),
          SliverToBoxAdapter(child: _buildLocationSection()),
          SliverToBoxAdapter(child: _sectionTitle('备份操作')),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Button.filled(
                onPressed: _startBackup,
                child: const Text('上传本地漫画到夸克'),
              ),
            ),
          ),
          SliverToBoxAdapter(child: _sectionTitle('云端备份')),
          if (_loading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else if (!_config.isValid)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Text('尚未设置备份位置，无法查看云端备份。'),
              ),
            )
          else if (_backups.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Text('暂无云端备份'),
              ),
            )
          else
            SliverList.builder(
              itemCount: _backups.length,
              itemBuilder: (context, index) {
                final file = _backups[index];
                return ListTile(
                  leading: const Icon(Icons.insert_drive_file_outlined),
                  title: Text(
                    file.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${_formatSize(file.size)} · ${file.modified.toString().substring(0, 16)}',
                  ),
                  trailing: const Icon(Icons.more_horiz),
                  onTap: () => _showBackupActions(file),
                );
              },
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
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
              TextButton(
                onPressed: batch.cancel,
                child: const Text('取消'),
              ),
            if (!batch.running)
              FilledButton(
                style: actionButtonStyle,
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
          ],
        );
      },
    );
  }
}
