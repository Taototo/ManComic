import 'package:flutter_test/flutter_test.dart';
import 'package:venera/features/cloud_backup/cloud_backup.dart';
import 'package:venera/network/cloud_storage/models.dart';

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
