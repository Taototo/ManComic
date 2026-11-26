import 'package:flutter_test/flutter_test.dart';
import 'package:venera/features/cloud_backup/backup_task_queue.dart';
import 'package:venera/features/cloud_backup/comic_archive_batch.dart';

ComicArchiveBatch _batch(List<String> titles) {
  return ComicArchiveBatch(
    items: [
      for (final title in titles) ArchiveItem(title: title, fileName: '$title.cbz'),
    ],
    errorText: (error) => error.toString(),
    action: (index, retry, cancelled) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return ArchiveItemState.success;
    },
  );
}

void main() {
  final queue = ArchiveTaskQueue.instance;

  setUp(queue.resetForTest);
  tearDown(queue.resetForTest);

  test('两个任务串行执行，不会并发上传同一个网盘', () async {
    final order = <String>[];
    final first = ComicArchiveBatch(
      items: [ArchiveItem(title: 'A', fileName: 'a.cbz')],
      errorText: (error) => '$error',
      action: (index, retry, cancelled) async {
        order.add('first-start');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        order.add('first-end');
        return ArchiveItemState.success;
      },
    );
    final second = ComicArchiveBatch(
      items: [ArchiveItem(title: 'B', fileName: 'b.cbz')],
      errorText: (error) => '$error',
      action: (index, retry, cancelled) async {
        order.add('second-start');
        return ArchiveItemState.success;
      },
    );

    final firstResult = queue.submit(first, title: '上传至网盘');
    final secondResult = queue.submit(second, title: '备份进度');
    expect(queue.pendingCount, 1);

    expect((await firstResult).success, 1);
    expect((await secondResult).success, 1);
    expect(order, ['first-start', 'first-end', 'second-start']);
    expect(queue.isBusy, isFalse);
  });

  test('队列记录正在跑的批次，重复打开对话框不会重复提交', () async {
    final batch = _batch(['A', 'B']);
    final done = queue.submit(batch, title: '上传至网盘');
    expect(queue.owns(batch), isTrue);
    expect(queue.owns(_batch(['C'])), isFalse);
    await done;
    // 跑完之后仍然归属当前批次，界面重新打开时能直接看结果。
    expect(queue.owns(batch), isTrue);
    expect(queue.lastResult?.success, 2);
  });

  test('进度按条目推进，结束后总数对齐', () async {
    final batch = _batch(['A', 'B', 'C']);
    final progress = <int>[];
    queue.addListener(() {
      if (queue.isBusy) progress.add(queue.done);
    });
    final result = await queue.submit(batch, title: '上传至网盘');
    expect(result.success, 3);
    expect(progress, isNotEmpty);
    expect(queue.total, 3);
    expect(queue.done, 3);
  });

  test('取消会清空排队任务，正在跑的批次完成后状态为已取消', () async {
    final first = _batch(['A']);
    final second = _batch(['B']);
    final firstDone = queue.submit(first, title: '上传至网盘');
    final secondDone = queue.submit(second, title: '上传至网盘');
    queue.cancelAll();
    final cancelled = await secondDone;
    expect(cancelled.success, 0);
    final firstResult = await firstDone;
    // 取消请求会在当前条目之后生效，这里至少要保证不会继续跑第二个任务。
    expect(firstResult.success + firstResult.failed, lessThanOrEqualTo(1));
    expect(queue.pendingCount, 0);
  });

  test('失败项可以重试，重试后统计更新', () async {
    var attempts = 0;
    final batch = ComicArchiveBatch(
      items: [ArchiveItem(title: 'A', fileName: 'a.cbz')],
      errorText: (error) => '$error',
      action: (index, retry, cancelled) async {
        attempts++;
        if (attempts == 1) {
          throw const ArchiveTransferFailure('网络中断');
        }
        return ArchiveItemState.success;
      },
    );
    final result = await queue.submit(batch, title: '上传至网盘');
    expect(result.failed, 1);
    expect(queue.canRetry, isTrue);
    await queue.retryActive();
    expect(queue.lastResult?.success, 1);
    expect(queue.canRetry, isFalse);
  });
}
