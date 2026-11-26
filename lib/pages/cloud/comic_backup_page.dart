import 'dart:async';

import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/features/cloud_backup/cloud_backup.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/cloud_storage/remote_storage.dart';
import 'package:venera/pages/cloud/archive_transfer_dialog.dart';
import 'package:venera/pages/cloud/remote_location_fields.dart';
import 'package:venera/pages/cloud/storage_accounts_page.dart';

/// 把本地漫画打包成 CBZ 备份到网盘，并从云端恢复的管理页面。
///
/// 夸克与 WebDAV 共用这一套备份：当前目标存在 [BackupConfig.location]，
/// 历次用过的目标都会被记住，网盘失效时可以一键切过去继续备份。
class ComicBackupPage extends StatefulWidget {
  const ComicBackupPage({super.key});

  @override
  State<ComicBackupPage> createState() => _ComicBackupPageState();
}

class _ComicBackupPageState extends State<ComicBackupPage> {
  late BackupConfig _config;
  List<BackupFile> _backups = <BackupFile>[];
  bool _loading = false;
  String? _loadError;

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
          _loadError = null;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _loading = true;
        _loadError = null;
      });
    }
    try {
      final res = await ComicBackupManager.listBackups();
      if (!mounted) return;
      setState(() {
        _backups = res.error
            ? <BackupFile>[]
            : (res.dataOrNull ?? <BackupFile>[]);
        _loading = false;
        _loadError = res.error ? '读取云端备份失败，请检查网盘连接' : null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '读取云端备份失败：${describeCloudError(error)}';
      });
    }
  }

  StorageAccount? _accountOf(RemoteLocation location) =>
      RemoteStorageAccounts.instance.account(location.accountId);

  String _targetTitle(RemoteLocation location) {
    final account = _accountOf(location);
    return '${account?.name ?? '账号不可用'} · ${storageProviderLabel(account)}';
  }

  /// 优先用可用的夸克账号：夸克是国内场景下最常用的备份目标。
  StorageAccount? _preferredQuarkAccount() {
    for (final account in RemoteStorageAccounts.instance.accounts) {
      if (account.backend == StorageBackend.openlist &&
          (account.driver == 'Quark' || account.driver == 'QuarkOpen') &&
          !account.authorizationIsKnownInvalid) {
        return account;
      }
    }
    return null;
  }

  Future<void> _switchTarget(
    RemoteLocation location, {
    bool offerRebackup = true,
  }) async {
    try {
      final next = await switchBackupTarget(location);
      if (!mounted) return;
      setState(() {
        _config = next;
        _loadError = null;
      });
      context.showMessage(message: '已切换备份网盘');
      unawaited(_loadBackups());
    } catch (error) {
      if (mounted) {
        context.showMessage(message: '切换备份网盘失败：${describeCloudError(error)}');
      }
      return;
    }
    if (offerRebackup && mounted) await _offerRebackup();
  }

  Future<void> _offerRebackup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => ContentDialog(
        title: '已切换备份网盘',
        content: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Text('现在把本地漫画备份到新网盘吗？新网盘上已有的同名备份会自动跳过。'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('稍后'),
          ),
          FilledButton(
            style: actionButtonStyle,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('选择漫画并备份'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _startBackup();
  }

  Future<void> _showTargetSheet() async {
    final destinations = _config.destinations;
    final choice = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '选择备份网盘',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
            ),
            if (destinations.isEmpty) const ListTile(title: Text('还没有保存过备份位置')),
            for (final destination in destinations)
              ListTile(
                leading: Icon(
                  _config.location != null &&
                          destination.accountId ==
                              _config.location!.accountId &&
                          destination.directory == _config.location!.directory
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(_targetTitle(destination)),
                subtitle: Text('目录：${destination.directory}'),
                trailing:
                    destination.accountId == _config.location?.accountId &&
                        destination.directory == _config.location?.directory
                    ? const Text('当前')
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(destination),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('选择其他网盘或目录…'),
              onTap: () => Navigator.of(sheetContext).pop('other'),
            ),
            ListTile(
              leading: const Icon(Icons.manage_accounts_outlined),
              title: const Text('管理网盘账号'),
              onTap: () => Navigator.of(sheetContext).pop('manage'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice is RemoteLocation) {
      if (choice.accountId == _config.location?.accountId &&
          choice.directory == _config.location?.directory) {
        return;
      }
      await _switchTarget(choice);
      return;
    }
    if (choice == 'other') {
      await _showLocationDialog();
      return;
    }
    if (choice == 'manage') {
      await context.to(() => StorageAccountsPage());
      if (!mounted) return;
      setState(() => _config = BackupConfig.fromSettings());
      unawaited(_loadBackups());
    }
  }

  Future<void> _showLocationDialog() async {
    final current = _config.location;
    StorageAccount? chosenAccount = current == null
        ? _preferredQuarkAccount()
        : _accountOf(current);
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
    await _switchTarget(
      RemoteLocation(
        accountId: chosenAccount!.id,
        directory: directories.first,
      ),
    );
  }

  Future<void> _clearConfig() async {
    try {
      await clearBackupTarget();
      if (!mounted) return;
      setState(() {
        _config = BackupConfig.fromSettings();
        _backups = <BackupFile>[];
        _loadError = null;
      });
      context.showMessage(message: '已清除备份位置');
    } catch (_) {
      if (mounted) context.showMessage(message: '清除备份配置失败');
    }
  }

  Future<void> _reauthorize(StorageAccount account) async {
    try {
      final saved = await showStorageAccountEditor(context, initial: account);
      if (!mounted) return;
      setState(() => _config = BackupConfig.fromSettings());
      if (saved == null) return;
      if (saved.statusMessage != null) {
        context.showMessage(message: '重新授权未通过：${saved.statusMessage}');
      } else {
        context.showMessage(message: '授权已更新');
        unawaited(_loadBackups());
      }
    } catch (error) {
      if (mounted) {
        context.showMessage(message: '重新授权失败：${describeCloudError(error)}');
      }
    }
  }

  /// 备份/恢复失败且原因指向登录失效时，给出「重新授权 / 切换网盘」的出口。
  Future<void> _handleTargetFailure() async {
    final location = _config.location;
    final account = location == null ? null : _accountOf(location);
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => ContentDialog(
        title: '网盘拒绝访问',
        content: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '「${account?.name ?? '当前网盘'}」返回了登录/授权失效，继续重试也不会成功。'
            '可以先重新授权；如果一时修不好，就切换到另一个网盘继续备份。',
          ),
        ),
        actions: [
          if (account != null)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop('relogin'),
              child: const Text('重新授权'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('switch'),
            child: const Text('切换网盘'),
          ),
          FilledButton(
            style: actionButtonStyle,
            onPressed: () => Navigator.of(dialogContext).pop('close'),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'relogin' && account != null) {
      await _reauthorize(account);
    } else if (action == 'switch') {
      await _showTargetSheet();
    }
  }

  Widget _buildLocationSection() {
    final location = _config.location;
    if (location == null) {
      final quark = _preferredQuarkAccount();
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('尚未设置备份位置。夸克和 WebDAV 共用这一套备份，之后随时可以切换。'),
            const SizedBox(height: 12),
            if (quark != null) ...[
              Button.filled(
                onPressed: () => _switchTarget(
                  RemoteLocation(
                    accountId: quark.id,
                    directory: '/venera_backup/',
                  ),
                  offerRebackup: false,
                ),
                child: Text('使用夸克网盘「${quark.name}」'),
              ),
              const SizedBox(height: 8),
            ],
            Button.outlined(
              onPressed: _showLocationDialog,
              child: const Text('选择网盘和目录'),
            ),
          ],
        ),
      );
    }
    final account = _accountOf(location);
    final invalid = account?.authorizationIsKnownInvalid == true;
    final alternatives = _config.alternatives;
    final errorColor = Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  invalid
                      ? Icons.cloud_off_outlined
                      : Icons.cloud_done_outlined,
                  color: invalid ? errorColor : null,
                ),
                title: Text(_targetTitle(location)),
                subtitle: Text('目录：${location.directory}'),
                trailing: invalid
                    ? Text('授权失效', style: TextStyle(color: errorColor))
                    : null,
              ),
              if (invalid) ...[
                Text(
                  account?.statusMessage ?? '当前网盘授权已失效，备份会失败。',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: errorColor),
                ),
                const SizedBox(height: 8),
              ],
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (invalid && account != null)
                    Button.filled(
                      onPressed: () => _reauthorize(account),
                      child: const Text('重新授权'),
                    ),
                  Button.outlined(
                    onPressed: _showTargetSheet,
                    child: Text(
                      alternatives.isEmpty
                          ? '切换网盘'
                          : '切换网盘（${alternatives.length}）',
                    ),
                  ),
                  Button.text(
                    onPressed: _showLocationDialog,
                    child: const Text('更改目录'),
                  ),
                  Button.text(
                    onPressed: _clearConfig,
                    child: const Text('清除配置'),
                  ),
                ],
              ),
            ],
          ),
        ),
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
      final result = await showArchiveTransferDialog(
        context,
        batch: batch,
        title: '备份进度',
      );
      if (!mounted || result == null) return;
      if (result.authorizationFailed) {
        await _handleTargetFailure();
      } else if (result.hasFailures) {
        context.showMessage(message: '${result.failed} 部漫画备份失败，可重试或更换网盘');
      } else if (result.success > 0 || result.skipped > 0) {
        context.showMessage(
          message: '备份完成：成功 ${result.success}，跳过 ${result.skipped}',
        );
      }
      await _loadBackups();
    } catch (_) {
      if (mounted) context.showMessage(message: '创建备份任务失败');
    }
  }

  Future<void> _startRestore(BackupFile file) async {
    try {
      final batch = ComicBackupManager.createRestoreBatch(<BackupFile>[file]);
      final result = await showArchiveTransferDialog(
        context,
        batch: batch,
        title: '恢复进度',
      );
      if (!mounted || result == null) return;
      if (result.authorizationFailed) await _handleTargetFailure();
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
                    '把本地漫画打包成 CBZ 备份到网盘。夸克和 WebDAV 共用这一套备份，'
                    '哪个可用就往哪个传；备份目录会自动加入在线漫画库，上传完成后即可在发现页直接阅读。'
                    '已有同名备份不会被覆盖。',
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Button.filled(
                    onPressed: _startBackup,
                    child: const Text('上传本地漫画到网盘'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _config.isValid
                        ? '当前目标：${_targetTitle(_config.location!)}'
                        : '未设置备份位置',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(child: _sectionTitle('云端备份')),
          if (_loadError != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_loadError!),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          TextButton(
                            onPressed: _loadBackups,
                            child: const Text('重试'),
                          ),
                          TextButton(
                            onPressed: _showTargetSheet,
                            child: const Text('切换网盘'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
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
