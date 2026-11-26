import 'package:venera/foundation/appdata.dart';
import 'package:venera/network/cloud_storage/remote_storage.dart';

import 'comic_backup.dart';

/// 切换备份目标：写入新位置，并把「自动创建的备份库」跟着搬过去。
///
/// 旧目标上自动创建的在线漫画库会被移除——如果那个网盘已经失效，留着它
/// 只会在发现页反复报错。用户自己建的库不受影响。
Future<BackupConfig> switchBackupTarget(RemoteLocation location) async {
  final previous = BackupConfig.fromSettings();
  final next = BackupConfig.withActiveTarget(previous, location);
  await BackupConfig.saveToSettings(next);
  if (previous.isValid && previous.targetIdentity != next.targetIdentity) {
    await removeBackupLibraryIfOwned(previous);
  }
  try {
    await ensureBackupLibrary(next);
  } catch (_) {
    // 库登记失败不影响备份本身，下次刷新时还会再试。
  }
  return next;
}

/// 清除备份配置，并移除自动创建的备份库。
Future<void> clearBackupTarget() async {
  final previous = BackupConfig.fromSettings();
  await removeBackupLibraryIfOwned(previous);
  await BackupConfig.clearSettings();
}

/// 把备份目录登记成一个在线漫画库，这样上传到夸克的 CBZ 会立刻出现在
/// 发现页，用户不必再去「在线漫画库」里手动添加同一个目录。
///
/// 幂等：已经存在「同账号 + 同目录」的库时直接复用，不会重复创建。
/// [BackupConfig.saveToSettings] 之后调用即可。
Future<RemoteLibrary?> ensureBackupLibrary(BackupConfig config) async {
  if (!config.isValid) return null;
  final accounts = RemoteStorageAccounts.instance;
  final location = config.location!;
  final directory = location.directory;
  final existing = accounts.libraries.where(
    (library) =>
        library.accountId == location.accountId &&
        library.directories.contains(directory),
  );
  if (existing.isNotEmpty) return existing.first;
  final account = accounts.accounts.where(
    (item) => item.id == location.accountId,
  );
  final name = account.isNotEmpty ? '${account.first.name}备份' : '夸克备份';
  return accounts.saveLibrary(
    RemoteLibrary(
      id: '',
      sourceKey: '',
      accountId: location.accountId,
      directories: [directory],
      name: name,
      autoRefresh: true,
      refreshIntervalMinutes: 360,
    ),
  );
}

/// 清除备份配置时是否要一并移除自动创建的库。
///
/// 只移除名字为「xx备份」且目录正好是备份目录的库，避免误删用户自己建的库。
Future<void> removeBackupLibraryIfOwned(BackupConfig config) async {
  if (!config.isValid) return;
  final accounts = RemoteStorageAccounts.instance;
  final location = config.location!;
  final owned = accounts.libraries
      .where(
        (library) =>
            library.accountId == location.accountId &&
            library.directories.length == 1 &&
            library.directories.first == location.directory &&
            library.name.endsWith('备份'),
      )
      .toList();
  for (final library in owned) {
    await accounts.removeLibrary(library.id);
  }
  // settings 兜底：即便 accounts 尚未完成初始化，也不能留下悬空配置。
  final raw = appdata.settings['remoteLibraries'];
  if (raw is List) {
    appdata.settings['remoteLibraries'] = raw.where((item) {
      if (item is! Map) return true;
      final id = item['id']?.toString();
      return owned.every((library) => library.id != id);
    }).toList();
    await appdata.saveData(false);
  }
}
