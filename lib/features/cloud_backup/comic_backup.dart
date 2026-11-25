import 'package:crypto/crypto.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/res.dart';
import 'package:venera/network/cloud_storage/remote_storage.dart';
import 'package:venera/utils/cbz.dart';
import 'package:venera/utils/io.dart';

import 'comic_archive_batch.dart';

/// 漫画归档备份的目标配置，仅支持已登录的网盘账号。
///
/// 配置持久化在 `appdata.settings['backupRemoteLocation']`。
class BackupConfig {
  BackupConfig({this.location, required this.remotePath});

  /// 目标网盘位置；为 null 表示未配置。
  final RemoteLocation? location;

  /// 备份根目录（通常由 [location] 派生）。
  final String remotePath;

  /// 是否配置了可用的网盘账号。
  bool get isValid => location != null;

  /// 目标身份标识，用于判断备份文件是否来自当前账号与目录。
  String get targetIdentity =>
      '${location!.accountId}|${location!.directory}';

  /// 从设置中读取备份配置。
  static BackupConfig fromSettings() {
    final raw = appdata.settings['backupRemoteLocation'];
    RemoteLocation? location;
    if (raw is Map) {
      final parsed = RemoteLocation.fromJson(raw);
      if (parsed.accountId.isNotEmpty) location = parsed;
    }
    return BackupConfig(
      location: location,
      remotePath: location?.directory ?? '/',
    );
  }

  /// 把备份文件名拼成完整的远端路径。
  String remoteFilePath(String fileName) =>
      '${normalizeRemoteDirectory(location?.directory ?? remotePath)}$fileName';

  /// 保存备份配置到设置并落盘。
  static Future<void> saveToSettings(BackupConfig config) async {
    if (config.isValid) {
      appdata.settings['backupRemoteLocation'] = config.location!.toJson();
    } else {
      appdata.settings['backupRemoteLocation'] = null;
    }
    await appdata.saveData(false);
  }

  /// 清除备份配置并落盘。
  static Future<void> clearSettings() async {
    appdata.settings['backupRemoteLocation'] = null;
    await appdata.saveData(false);
  }
}

/// 网盘上的一个 CBZ 备份文件。
class BackupFile {
  const BackupFile({
    required this.name,
    required this.size,
    required this.modified,
    this.targetIdentity,
  });

  /// 文件名。
  final String name;

  /// 文件大小（字节）。
  final int size;

  /// 最后修改时间。
  final DateTime modified;

  /// 该文件所属的目标身份，可能为空。
  final String? targetIdentity;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BackupFile &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          size == other.size &&
          modified == other.modified;

  @override
  int get hashCode => Object.hash(name, size, modified, targetIdentity);
}

/// 网盘文件操作抽象，便于注入替身实现。
abstract class ComicBackupOps {
  /// 测试连通性。
  Future<void> test(BackupConfig config);

  /// 列出备份目录中的文件。
  Future<List<BackupFile>> list(BackupConfig config);

  /// 判断远端路径是否存在。
  Future<bool> exists(BackupConfig config, String remotePath);

  /// 确保备份目录存在。
  Future<void> ensureDirectory(BackupConfig config);

  /// 上传本地文件。
  Future<void> uploadFile(
    BackupConfig config,
    String localPath,
    String remotePath,
  );

  /// 下载远端文件到本地。
  Future<void> downloadFile(
    BackupConfig config,
    String remotePath,
    String localPath,
  );

  /// 删除远端文件。
  Future<void> deleteFile(BackupConfig config, String remotePath);
}

/// 基于 [RemoteStorageAccounts] 的网盘操作实现。
class _RemoteComicBackupOps implements ComicBackupOps {
  static final _active = <RemoteFileStore>{};

  /// 取消所有正在进行的传输。
  static Future<void> cancelActive() =>
      Future.wait(_active.map((store) => store.cancelAll()));

  Future<T> _run<T>(
    BackupConfig config,
    Future<T> Function(RemoteFileStore store) action,
  ) async {
    final accounts = RemoteStorageAccounts.instance;
    final store = accounts.storeFor(config.location!.accountId);
    _active.add(store);
    try {
      return await action(store);
    } finally {
      _active.remove(store);
      accounts.release(store);
    }
  }

  @override
  Future<void> test(BackupConfig config) =>
      _run(config, (store) => store.list(config.remotePath));

  @override
  Future<List<BackupFile>> list(BackupConfig config) async =>
      (await _run(config, (store) => store.list(config.remotePath)))
          .where((entry) => !entry.isDirectory)
          .map(
            (entry) => BackupFile(
              name: entry.name,
              size: entry.size ?? 0,
              modified: DateTime.fromMillisecondsSinceEpoch(
                entry.modifiedAt ?? 0,
              ),
            ),
          )
          .toList();

  @override
  Future<bool> exists(BackupConfig config, String remotePath) async =>
      (await _run(
        config,
        (store) => store.list(config.remotePath),
      )).any((entry) => entry.name == remotePath.split('/').last);

  @override
  Future<void> ensureDirectory(BackupConfig config) =>
      _run(config, (store) => store.mkdir(config.remotePath));

  @override
  Future<void> uploadFile(
    BackupConfig config,
    String localPath,
    String remotePath,
  ) => _run(config, (store) => store.upload(localPath, remotePath));

  @override
  Future<void> downloadFile(
    BackupConfig config,
    String remotePath,
    String localPath,
  ) => _run(config, (store) => store.download(remotePath, localPath));

  @override
  Future<void> deleteFile(BackupConfig config, String remotePath) =>
      _run(config, (store) => store.delete(remotePath));
}

/// 备份或恢复的汇总结果。
class BackupResult {
  const BackupResult({
    required this.success,
    required this.skipped,
    required this.failed,
    this.errors = const [],
  });

  /// 成功数。
  final int success;

  /// 跳过数（远端已存在）。
  final int skipped;

  /// 失败数。
  final int failed;

  /// 错误描述列表。
  final List<String> errors;

  /// 由批次统计生成结果。
  factory BackupResult.fromBatch(ComicArchiveBatch batch) => BackupResult(
    success: batch.count(ArchiveItemState.success),
    skipped: batch.count(ArchiveItemState.skipped),
    failed: batch.count(ArchiveItemState.failed),
    errors: [
      for (final item in batch.items)
        if (item.error != null)
          '${item.title}: ${batch.errorText(item.error!)}',
    ],
  );
}

/// 本地漫画的网盘归档备份与恢复管理器。
class ComicBackupManager {
  const ComicBackupManager._();

  /// 可注入的网盘操作实现，便于测试。
  static ComicBackupOps ops = _RemoteComicBackupOps();

  /// 恢复默认操作实现。
  static void resetOps() {
    ops = _RemoteComicBackupOps();
  }

  /// 可注入的导出实现，默认调用 [CBZ.export]。
  static Future<void> Function(LocalComic comic, String outputPath)? exportComic;

  /// 可注入的导入实现，默认调用 [CBZ.import]。
  static Future<LocalComic> Function(String filePath)? importComic;

  /// 可注入的入库实现，默认调用 `LocalManager().add`。
  static Future<void> Function(LocalComic comic)? registerImportedComic;

  /// 当前配置快照。
  static BackupConfig get config => BackupConfig.fromSettings();

  static int _taskEpoch = 0;

  /// 取消所有正在进行的备份/恢复任务。
  static Future<void> cancelActiveTasks() async {
    _taskEpoch++;
    await _RemoteComicBackupOps.cancelActive();
  }

  /// 测试当前配置指向的网盘是否可用。
  static Future<Res<bool>> testConnection(BackupConfig config) async {
    if (!config.isValid) {
      return const Res.error('Invalid backup configuration');
    }
    try {
      await ops.test(config);
      return const Res(true);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  /// 列出网盘备份目录中全部 CBZ 文件，按修改时间倒序。
  static Future<Res<List<BackupFile>>> listBackups() async {
    final config = BackupConfig.fromSettings();
    if (!config.isValid) {
      return const Res.error('Invalid backup configuration');
    }
    try {
      final files = await ops.list(config);
      final cbzFiles =
          files
              .where((file) => file.name.toLowerCase().endsWith('.cbz'))
              .map(
                (file) => BackupFile(
                  name: file.name,
                  size: file.size,
                  modified: file.modified,
                  targetIdentity: config.targetIdentity,
                ),
              )
              .toList()
            ..sort((a, b) => b.modified.compareTo(a.modified));
      return Res(cbzFiles);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  /// 把底层错误转成展示文本。
  static String _safeError(Object error, BackupConfig _) => error.toString();

  /// 创建备份批次，可用于逐项展示进度与重试。
  static ComicArchiveBatch createBackupBatch(List<LocalComic> comics) {
    final targets = List<LocalComic>.of(comics);
    final config = BackupConfig.fromSettings();
    final operations = ops;
    final epoch = _taskEpoch;
    final cache = App.cachePath;
    final exporter = exportComic;
    final items = [
      for (final comic in targets)
        ArchiveItem(title: comic.title, fileName: backupFileName(comic)),
    ];
    final uploadedDigests = <int, Digest>{};
    Set<String>? remoteNames;
    Future<void>? setup;
    Future<void> initialize() async {
      if (!config.isValid) {
        throw const ArchiveTransferFailure('Invalid backup configuration');
      }
      await operations.ensureDirectory(config);
      try {
        remoteNames = {
          for (final file in await operations.list(config)) file.name,
        };
      } catch (_) {
        remoteNames = null;
      }
    }

    return ComicArchiveBatch(
      items: items,
      errorText: (error) => _safeError(error, config),
      action: (index, retry, cancelled) async {
        bool stopped() => cancelled() || epoch != _taskEpoch;
        if (stopped()) return ArchiveItemState.cancelled;
        if (retry) setup = null;
        await (setup ??= initialize());
        if (stopped()) return ArchiveItemState.cancelled;
        final remote = config.remoteFilePath(items[index].fileName);
        final exists = retry || remoteNames == null
            ? await operations.exists(config, remote)
            : remoteNames!.contains(items[index].fileName);
        if (stopped()) return ArchiveItemState.cancelled;
        if (exists && !retry) return ArchiveItemState.skipped;
        final workspace = await Directory(cache).createTemp('comic-backup-');
        try {
          final file = File(FilePath.join(workspace.path, 'archive.cbz'));
          if (exists) {
            final expected = uploadedDigests[index];
            if (expected == null) {
              throw const ArchiveTransferFailure(
                'Remote archive conflicts with this transfer. No file was overwritten.',
              );
            }
            await operations.downloadFile(config, remote, file.path);
            if (await sha256.bind(file.openRead()).first != expected) {
              throw const ArchiveTransferFailure(
                'Remote archive conflicts with this transfer. No file was overwritten.',
              );
            }
            return ArchiveItemState.success;
          }
          if (exporter != null) {
            await exporter(targets[index], file.path);
          } else {
            await CBZ.export(targets[index], file.path);
          }
          if (stopped()) return ArchiveItemState.cancelled;
          uploadedDigests[index] = await sha256.bind(file.openRead()).first;
          if (stopped()) return ArchiveItemState.cancelled;
          await operations.uploadFile(config, file.path, remote);
          if (epoch != _taskEpoch) return ArchiveItemState.cancelled;
          remoteNames?.add(items[index].fileName);
          return ArchiveItemState.success;
        } finally {
          await workspace.deleteIgnoreError(recursive: true);
        }
      },
    );
  }

  /// 创建恢复批次，可用于逐项展示进度与重试。
  static ComicArchiveBatch createRestoreBatch(List<BackupFile> files) {
    final targets = List<BackupFile>.of(files);
    final config = BackupConfig.fromSettings();
    final operations = ops;
    final epoch = _taskEpoch;
    final cache = App.cachePath;
    final importer = importComic;
    final register = registerImportedComic;
    return ComicArchiveBatch(
      items: [
        for (final file in targets)
          ArchiveItem(title: file.name, fileName: file.name),
      ],
      errorText: (error) => _safeError(error, config),
      action: (index, retry, cancelled) async {
        bool stopped() => cancelled() || epoch != _taskEpoch;
        if (!config.isValid) {
          throw const ArchiveTransferFailure('Invalid backup configuration');
        }
        final backup = targets[index];
        if (backup.targetIdentity != null &&
            backup.targetIdentity != config.targetIdentity) {
          throw const ArchiveTransferFailure(
            'Backup target changed. Refresh the archive list.',
            retryAllowed: false,
          );
        }
        if (stopped()) return ArchiveItemState.cancelled;
        final workspace = await Directory(cache).createTemp('comic-restore-');
        var registering = false;
        try {
          final file = File(
            FilePath.join(workspace.path, sanitizeFileName(backup.name)),
          );
          await operations.downloadFile(
            config,
            config.remoteFilePath(backup.name),
            file.path,
          );
          if (stopped()) return ArchiveItemState.cancelled;
          final comic = importer != null
              ? await importer(file.path)
              : await CBZ.import(file);
          // 导入已经产生本地文件，后续失败不能再重试，否则会重复入库。
          registering = true;
          if (register != null) {
            await register(comic);
          } else {
            final manager = LocalManager();
            await manager.add(comic, manager.findValidId(comic.comicType));
          }
          return ArchiveItemState.success;
        } catch (error, stack) {
          if (registering) {
            Error.throwWithStackTrace(
              ArchiveTransferFailure(error.toString(), retryAllowed: false),
              stack,
            );
          }
          rethrow;
        } finally {
          await workspace.deleteIgnoreError(recursive: true);
        }
      },
    );
  }

  /// 备份一批漫画，返回成功/跳过/失败汇总。
  static Future<BackupResult> backup(
    List<LocalComic> comics, {
    void Function(int current, int total, String currentTitle)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final batch = createBackupBatch(comics);
    try {
      await batch.run(onProgress: onProgress, isCancelled: isCancelled);
      return BackupResult.fromBatch(batch);
    } finally {
      batch.dispose();
    }
  }

  /// 恢复一批备份，返回成功/跳过/失败汇总。
  static Future<BackupResult> restore(
    List<BackupFile> files, {
    void Function(int current, int total, String currentTitle)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final batch = createRestoreBatch(files);
    try {
      await batch.run(onProgress: onProgress, isCancelled: isCancelled);
      return BackupResult.fromBatch(batch);
    } finally {
      batch.dispose();
    }
  }

  /// 删除一个网盘备份文件。
  static Future<Res<bool>> deleteBackup(BackupFile file) async {
    final config = BackupConfig.fromSettings();
    if (!config.isValid) {
      return const Res.error('Invalid backup configuration');
    }
    if (file.targetIdentity != null &&
        file.targetIdentity != config.targetIdentity) {
      return const Res.error(
        'Backup target changed. Refresh the archive list.',
      );
    }
    try {
      await ops.deleteFile(config, config.remoteFilePath(file.name));
      return const Res(true);
    } catch (e) {
      return Res.error(e.toString());
    }
  }

  /// 生成备份文件名：清洗后的标题 + 当天日期 + `.cbz`。
  static String backupFileName(LocalComic comic) {
    final name = sanitizeFileName(comic.title);
    final now = DateTime.now();
    final timestamp =
        '${now.year}-${_twoDigits(now.month)}-${_twoDigits(now.day)}';
    return '${name}_$timestamp.cbz';
  }

  static String _twoDigits(int value) => value.toString().padLeft(2, '0');
}
