import 'package:flutter_test/flutter_test.dart';
import 'package:venera/features/cloud_library/remote_library_engine.dart';

void main() {
  group('网盘漫画库扫描范围收敛到 ManComic', () {
    test('网盘根目录收敛到 /ManComic/', () {
      expect(constrainCloudLibraryDirectories(['/']), ['/ManComic/']);
      expect(constrainCloudLibraryDirectories(['']), ['/ManComic/']);
    });

    test('ManComic 本身及其子目录原样保留', () {
      expect(constrainCloudLibraryDirectories(['/ManComic']), ['/ManComic/']);
      expect(
        constrainCloudLibraryDirectories(['/ManComic/待整理']),
        ['/ManComic/待整理/'],
      );
      expect(
        constrainCloudLibraryDirectories(['/ManComic/漫威漫画/蜘蛛侠篇']),
        ['/ManComic/漫威漫画/蜘蛛侠篇/'],
      );
    });

    test('网盘其它位置被忽略', () {
      expect(
        constrainCloudLibraryDirectories(['/来自：分享']),
        ['/ManComic/'],
      );
      expect(
        constrainCloudLibraryDirectories(['/其它漫画']),
        ['/ManComic/'],
      );
    });

    test('混合配置：只保留 ManComic 内的路径', () {
      expect(
        constrainCloudLibraryDirectories([
          '/',
          '/来自：分享',
          '/ManComic/待整理',
          '/ManComic',
        ]),
        ['/ManComic/', '/ManComic/待整理/'],
      );
    });

    test('祖先路径去重', () {
      expect(
        constrainCloudLibraryDirectories(['/ManComic/', '/']),
        ['/ManComic/'],
      );
    });

    test('全无关时回退到 ManComic 根', () {
      expect(
        constrainCloudLibraryDirectories(['/a', '/b']),
        ['/ManComic/'],
      );
    });
  });
}
