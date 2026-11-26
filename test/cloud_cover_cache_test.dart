import 'package:flutter_test/flutter_test.dart';
import 'package:venera/features/cloud_library/remote_archive_comic.dart';
import 'package:venera/features/cloud_library/remote_comic_work.dart';

/// 封面缓存键必须稳定：库重新扫描、PDF 检查完第一页之后，
/// `archive.version` 会变，但同一本书的封面磁盘缓存不该跟着失效。
void main() {
  RemoteArchiveComic pdf(String readId) => RemoteArchiveComic(
    path: '/漫画/蜘蛛侠 001.pdf',
    size: 1024,
    eTag: 'etag-001',
    pdfPageCount: 20,
    pdfReadId: readId,
    coverEntry: 'pdf:1',
  );

  group('网盘封面缓存键', () {
    test('单本封面 key 不随 PDF 读取身份变化', () {
      final before = pdf('first-read');
      final after = pdf('second-read');

      expect(before.version, isNot(after.version));
      expect(before.imageKey(), isNot(after.imageKey()));
      expect(before.coverImageKey(), after.coverImageKey());
    });

    test('作品封面 key 不随卷的检查状态变化', () {
      RemoteComicWork work(RemoteArchiveComic archive) => RemoteComicWork(
        directory: '/漫画/蜘蛛侠',
        title: '蜘蛛侠',
        volumes: [
          RemoteComicVolume(
            archive: archive,
            title: '001',
          ),
        ],
      );

      final before = work(pdf('first-read'));
      final after = work(pdf('second-read'));
      final volumeBefore = before.volumes.single;
      final volumeAfter = after.volumes.single;

      expect(before.id, after.id);
      expect(before.imageKey(volumeBefore), after.imageKey(volumeAfter));
      // 阅读页仍要带版本，避免读到旧缓存里的错页。
      expect(
        before.imageKey(volumeBefore, 'pdf:2'),
        isNot(after.imageKey(volumeAfter, 'pdf:2')),
      );
    });

    test('封面 key 能被引擎解析回来', () {
      final key = pdf('first-read').coverImageKey();
      final parsed = RemoteArchiveComic.parseImageKey(key);
      expect(parsed, isNotNull);
      expect(parsed!.path, '/漫画/蜘蛛侠 001.pdf');
      expect(parsed.entry, isNull);
    });
  });
}
