import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/cloud_library.dart';

void main() {
  group('CloudUploadTask 的进度', () {
    test('总量为 0 时只有完成才算 1', () {
      final task = CloudUploadTask(
        comicId: 'a',
        sourceKey: 's',
        directory: 'dir',
        title: 't',
      );
      expect(task.progress, 0);
      task.status = CloudUploadStatus.done;
      expect(task.progress, 1);
    });

    test('按已处理文件数算比例，并夹在 0 到 1 之间', () {
      final task = CloudUploadTask(
        comicId: 'a',
        sourceKey: 's',
        directory: 'dir',
        title: 't',
        uploaded: 37,
        total: 100,
      );
      expect(task.progress, closeTo(0.37, 1e-9));

      // 远端已有文件也算「处理过」，理论上不该超过总量，
      // 但真超了也不能让进度条画到框外。
      task.uploaded = 120;
      expect(task.progress, 1);
    });
  });

  group('CloudUploadTask 持久化', () {
    test('往返之后字段不丢', () {
      final task = CloudUploadTask(
        comicId: '123456',
        sourceKey: 'copymanga',
        directory: '某漫画',
        title: '某漫画',
        status: CloudUploadStatus.failed,
        uploaded: 12,
        total: 300,
        error: 'timeout',
      );
      final round = CloudUploadTask.fromJson(task.toJson())!;
      expect(round.comicId, task.comicId);
      expect(round.sourceKey, task.sourceKey);
      expect(round.directory, task.directory);
      expect(round.title, task.title);
      expect(round.status, CloudUploadStatus.failed);
      expect(round.uploaded, 12);
      expect(round.total, 300);
      expect(round.error, 'timeout');
      expect(round.key, task.key);
    });

    test('缺关键字段的旧记录直接丢弃，不猜', () {
      expect(CloudUploadTask.fromJson({"title": "只有标题"}), isNull);
      expect(
        CloudUploadTask.fromJson({"comicId": "1", "directory": "d"}),
        isNotNull,
      );
    });

    test('无法识别的状态退回待传，避免卡在 running', () {
      final task = CloudUploadTask.fromJson({
        "comicId": "1",
        "directory": "d",
        "status": "some-future-state",
      })!;
      expect(task.status, CloudUploadStatus.pending);
    });
  });
}
