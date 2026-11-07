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
  });

  group('下载任务默认状态', () {
    test('新建任务不是用户暂停', () {
      // pumpQueue 靠这个字段区分「排队」和「手动暂停」，默认值必须是 false，
      // 否则重启后恢复出来的任务永远不会自动续传。
      expect(_FakeTask().userPaused, isFalse);
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
  void cancel() {}

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
