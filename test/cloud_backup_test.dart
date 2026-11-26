import 'package:flutter_test/flutter_test.dart';
import 'package:venera/features/cloud_backup/cloud_backup.dart';
import 'package:venera/network/cloud_storage/models.dart';
import 'package:venera/network/cloud_storage/remote_file_store.dart';

void main() {
  group('夸克网盘备份核心', () {
    test('备份位置序列化保留账号与目录', () {
      final config = BackupConfig(
        location: const RemoteLocation(accountId: 'acc-1', directory: 'comics'),
        remotePath: '/comics',
      );
      expect(config.isValid, isTrue);
      expect(config.targetIdentity, 'acc-1|comics');
      expect(config.remoteFilePath('a.cbz'), '/comics/a.cbz');
    });

    test('未配置备份位置时目标身份不抛异常（仅访问受 isValid 保护）', () {
      final config = BackupConfig(location: null, remotePath: '/');
      expect(config.isValid, isFalse);
    });

    test('夸克与 WebDAV 共存于同一份备份目标列表', () {
      final base = BackupConfig(
        location: const RemoteLocation(
          accountId: 'quark-1',
          directory: '/venera_backup/',
        ),
        remotePath: '/venera_backup/',
        destinations: const [
          RemoteLocation(accountId: 'quark-1', directory: '/venera_backup/'),
          RemoteLocation(accountId: 'webdav-1', directory: '/backup'),
        ],
      );
      expect(base.destinations.length, 2);
      expect(base.alternatives.map((item) => item.accountId), ['webdav-1']);

      // 切到 WebDAV：两个目标都保留，当前目标换成 WebDAV。
      final switched = BackupConfig.withActiveTarget(
        base,
        const RemoteLocation(accountId: 'webdav-1', directory: '/backup'),
      );
      expect(switched.location?.accountId, 'webdav-1');
      expect(switched.targetIdentity, 'webdav-1|/backup/');
      expect(switched.destinations.length, 2);
      expect(switched.alternatives.map((item) => item.accountId), ['quark-1']);

      // 再切回夸克同样保留两个目标，不会丢掉 WebDAV。
      final back = BackupConfig.withActiveTarget(
        switched,
        const RemoteLocation(
          accountId: 'quark-1',
          directory: '/venera_backup/',
        ),
      );
      expect(back.location?.accountId, 'quark-1');
      expect(back.destinations.length, 2);
    });

    test('重复目标不会重复登记', () {
      final config = BackupConfig(
        location: const RemoteLocation(accountId: 'acc-1', directory: '/a/'),
        remotePath: '/a/',
        destinations: const [
          RemoteLocation(accountId: 'acc-1', directory: '/a'),
          RemoteLocation(accountId: 'acc-1', directory: '/a/'),
        ],
      );
      expect(config.destinations.length, 1);
    });

    test('移除当前目标时自动切到剩下的第一个', () {
      final base = BackupConfig(
        location: const RemoteLocation(accountId: 'webdav-1', directory: '/b/'),
        remotePath: '/b/',
        destinations: const [
          RemoteLocation(accountId: 'quark-1', directory: '/a/'),
          RemoteLocation(accountId: 'webdav-1', directory: '/b/'),
        ],
      );
      final removed = BackupConfig.withoutDestination(
        base,
        const RemoteLocation(accountId: 'webdav-1', directory: '/b/'),
      );
      expect(removed.location?.accountId, 'quark-1');
      expect(removed.destinations.length, 1);

      final emptied = BackupConfig.withoutDestination(
        removed,
        const RemoteLocation(accountId: 'quark-1', directory: '/a/'),
      );
      expect(emptied.isValid, isFalse);
      expect(emptied.destinations, isEmpty);
    });

    test('授权失效与网络错误能被区分开', () {
      expect(
        isStorageAuthorizationError(
          const RemoteStorageException('登录已失效，请重新登录', code: 'unauthorized'),
        ),
        isTrue,
      );
      expect(isStorageAuthorizationError('Cookie 已过期，请重新授权'), isTrue);
      expect(
        isStorageAuthorizationError('Get "https://drive.quark.cn": EOF'),
        isFalse,
      );
      expect(isStorageAuthorizationError('format_type is null!'), isFalse);
      // 标题里刚好有 401 不算授权失败，别把普通错误误判成登录过期。
      expect(isStorageAuthorizationError('401号漫画: 网络中断'), isFalse);
      expect(isStorageAuthorizationError('HTTP 401'), isTrue);
    });

    test('备份结果标记授权类失败', () async {
      final batch = ComicArchiveBatch(
        items: [ArchiveItem(title: 'A', fileName: 'a.cbz')],
        action: (index, retry, cancelled) async {
          throw const RemoteStorageException('401 Unauthorized', code: '401');
        },
        errorText: (error) => error.toString(),
      );
      await batch.run();
      final result = BackupResult.fromBatch(batch);
      expect(result.failed, 1);
      expect(result.authorizationFailed, isTrue);
      batch.dispose();
    });

    test('备份批次按顺序执行并记录状态', () async {
      final batch = ComicArchiveBatch(
        items: [
          ArchiveItem(title: 'A', fileName: 'a.cbz'),
          ArchiveItem(title: 'B', fileName: 'b.cbz'),
        ],
        action: (index, retry, cancelled) async {
          if (index == 1) {
            throw ArchiveTransferFailure('网络错误');
          }
          return ArchiveItemState.success;
        },
        errorText: (error) => error.toString(),
      );
      await batch.run();
      expect(batch.items[0].state, ArchiveItemState.success);
      expect(batch.items[1].state, ArchiveItemState.failed);
      expect(batch.items[1].canRetry, isTrue);
      expect(batch.hasRetryableFailures, isTrue);
      batch.dispose();
    });

    test('备份批次取消后剩余项保持待处理', () async {
      final started = [];
      late final ComicArchiveBatch batch;
      batch = ComicArchiveBatch(
        items: [
          ArchiveItem(title: 'A', fileName: 'a.cbz'),
          ArchiveItem(title: 'B', fileName: 'b.cbz'),
        ],
        action: (index, retry, cancelled) async {
          started.add(index);
          if (index == 0) batch.cancel();
          return ArchiveItemState.success;
        },
        errorText: (error) => error.toString(),
      );
      await batch.run();
      expect(started, [0]);
      expect(batch.items[1].state, ArchiveItemState.pending);
      batch.dispose();
    });
  });
}
