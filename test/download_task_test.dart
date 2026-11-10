import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';

void main() {
  group('下载体积估算', () {
    test('还没拿到图片列表时不给数字', () {
      expect(
        estimateTotalBytes(
          downloadedBytes: 0,
          downloadedCount: 0,
          totalCount: 0,
        ),
        0,
      );
    });

    test('一页都没下完时不给数字', () {
      expect(
        estimateTotalBytes(
          downloadedBytes: 0,
          downloadedCount: 0,
          totalCount: 120,
        ),
        0,
      );
    });

    test('按已完成页的平均值外推', () {
      // 10 页共 5MB → 平均 0.5MB/页 → 100 页约 50MB
      expect(
        estimateTotalBytes(
          downloadedBytes: 5 * 1024 * 1024,
          downloadedCount: 10,
          totalCount: 100,
        ),
        50 * 1024 * 1024,
      );
    });

    test('全部下完时等于真实总量', () {
      // 最后一张图可能比平均大很多，外推会偏，收口必须用实际值
      expect(
        estimateTotalBytes(
          downloadedBytes: 12345678,
          downloadedCount: 100,
          totalCount: 100,
        ),
        12345678,
      );
    });

    test('进度超过总量时也不外推出更小的数', () {
      expect(
        estimateTotalBytes(
          downloadedBytes: 900,
          downloadedCount: 12,
          totalCount: 10,
        ),
        900,
      );
    });

    test('样本不足 5 页时不外推，避免第一张长图带偏', () {
      // 第一页是 2.4MB 的长条图，按它外推 900 页就是 2.1GB
      expect(
        estimateTotalBytes(
          downloadedBytes: 2400 * 1024,
          downloadedCount: 1,
          totalCount: 900,
          recentPageBytes: [2400 * 1024],
        ),
        0,
      );
    });

    test('按最近样本的中位数外推，单张大图不会把结果放大几十倍', () {
      // 一页 2.4MB + 四页 80KB，中位数仍是 80KB
      var samples = [2400 * 1024, 80 * 1024, 82 * 1024, 78 * 1024, 81 * 1024];
      var total = estimateTotalBytes(
        downloadedBytes: 2721 * 1024,
        downloadedCount: 5,
        totalCount: 100,
        recentPageBytes: samples,
      );
      // 剩下 95 页 × 80KB ≈ 7.4MB，总量应该在 10MB 上下，绝不是 GB 级
      expect(total, lessThan(12 * 1024 * 1024));
      expect(total, greaterThan(9 * 1024 * 1024));
    });

    test('中位数取偶数样本的中间两页平均', () {
      var total = estimateTotalBytes(
        downloadedBytes: 500,
        downloadedCount: 5,
        totalCount: 10,
        recentPageBytes: [100, 90, 200, 80, 70, 60],
      );
      // 排序后 60/70/80/90/100/200 → 中位数 (80+90)/2 = 85
      expect(total, 500 + 85 * 5);
    });
  });

  group('下载任务默认状态', () {
    test('新建任务不是用户暂停', () {
      // pumpQueue 靠这个字段区分「排队」和「手动暂停」，默认值必须是 false，
      // 否则重启后恢复出来的任务永远不会自动续传。
      expect(_FakeTask().userPaused, isFalse);
    });
  });

  group('进度快照', () {
    test('只带小字段，能原样盖回去', () {
      var task = _FakeTask()..userPaused = true;
      var json = task.toProgressJson();
      // uid 是任务实例的身份。进度文件按「类型:id」索引，同一本漫画取消后
      // 再下一次会撞上同一个键，只有 uid 能把这两轮分开（见 acceptsProgress）。
      expect(json, {"uid": task.uid, "userPaused": true});
      var restored = _FakeTask();
      restored.applyProgressJson(json);
      expect(restored.userPaused, isTrue);
    });

    test('键按「类型 + id」区分，和列表顺序无关', () {
      var task = _FakeTask();
      expect(task.progressKey, "${ComicType.local.value}:");
    });
  });

  group('恢复落点（以磁盘为准）', () {
    test('什么都没下过：从第一章第一页开始', () {
      var p = computeResumePoint(
        pageCounts: [20, 20],
        existingPages: [<int>[], <int>[]],
      );
      expect(p.chapter, 0);
      expect(p.index, 0);
      expect(p.downloaded, 0);
      expect(p.total, 40);
    });

    test('前几页在磁盘上：跳过它们，别重下', () {
      var p = computeResumePoint(
        pageCounts: [20],
        existingPages: [
          [0, 1, 2, 3],
        ],
      );
      expect(p.index, 4);
      expect(p.downloaded, 4);
    });

    test('中间缺一页：落在那个洞上', () {
      var p = computeResumePoint(
        pageCounts: [20],
        existingPages: [
          [0, 1, 2, 4, 5],
        ],
      );
      expect(p.index, 3);
      expect(p.downloaded, 5);
    });

    test('第一章全下完：跳到第二章的缺页', () {
      var p = computeResumePoint(
        pageCounts: [10, 10],
        existingPages: [
          List.generate(10, (i) => i),
          [0, 1],
        ],
      );
      expect(p.chapter, 1);
      expect(p.index, 2);
      expect(p.downloaded, 12);
    });

    test('全部都在磁盘上：游标推到末尾，交给上层直接入库', () {
      var p = computeResumePoint(
        pageCounts: [3, 2],
        existingPages: [
          [0, 1, 2],
          [0, 1],
        ],
      );
      expect(p.chapter, 2);
      expect(p.downloaded, 5);
      expect(p.total, 5);
    });

    test('页码比列表长（文件残留）不会算进进度', () {
      var p = computeResumePoint(
        pageCounts: [3],
        existingPages: [
          [0, 1, 2, 9, 10],
        ],
      );
      expect(p.downloaded, 3);
      expect(p.chapter, 1);
    });

    test('空章节列表不会崩', () {
      var p = computeResumePoint(pageCounts: [], existingPages: []);
      expect(p.total, 0);
      expect(p.downloaded, 0);
    });
  });
}

class _FakeTask extends DownloadTask {
  @override
  double get progress => 0;

  @override
  bool get isError => false;

  @override
  bool get isPaused => true;

  @override
  int get downloadedBytes => 0;

  @override
  int get totalBytes => 0;

  @override
  int get speed => 0;

  @override
  Future<void> cancel() async {}

  @override
  void pause() {}

  @override
  void resume() {}

  @override
  String get title => '';

  @override
  String? get cover => null;

  @override
  String get message => '';

  @override
  Map<String, dynamic> toJson() => {};

  @override
  LocalComic toLocalComic() => throw UnimplementedError();

  @override
  String get id => '';

  @override
  ComicType get comicType => ComicType.local;
}
