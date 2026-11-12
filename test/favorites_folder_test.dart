import 'package:flutter_test/flutter_test.dart';
import 'package:venera/pages/favorites/favorites_page.dart';

/// 「全部」「已阅」「已下载」的哨兵名（私有常量，测试里按字面量对照）。
const allLabel = '^_^[%local_all%]^_^';
const readLabel = '^_^[%local_read%]^_^';
const downloadedLabel = '^_^[%local_downloaded%]^_^';

void main() {
  bool exists(String folder) => folder == '连载中';

  test('「全部」在页面重建后仍然是「全部」', () {
    final r = resolveFavoriteFolder(
      {'name': allLabel, 'isNetwork': false},
      existsFolder: exists,
    );
    expect(r.$1, allLabel);
    expect(r.$2, isFalse);
  });

  test('「已阅」同样保留', () {
    final r = resolveFavoriteFolder(
      {'name': readLabel, 'isNetwork': false},
      existsFolder: exists,
    );
    expect(r.$1, readLabel);
  });

  test('「已下载」回落到「全部」', () {
    final r = resolveFavoriteFolder(
      {'name': downloadedLabel, 'isNetwork': false},
      existsFolder: exists,
    );
    // 1.4.60 起「本地漫画」不在收藏页里渲染列表，侧栏那一项直接打开
    // 本地库页面。上次停在这里的用户落到「全部」，不会看到空面板。
    expect(r.$1, allLabel);
    expect(r.$2, isFalse);
  });

  test('真实存在的文件夹保留', () {
    final r = resolveFavoriteFolder(
      {'name': '连载中', 'isNetwork': false},
      existsFolder: exists,
    );
    expect(r.$1, '连载中');
  });

  test('文件夹被删掉后回落到未选择', () {
    final r = resolveFavoriteFolder(
      {'name': '已删除的分类', 'isNetwork': false},
      existsFolder: exists,
    );
    expect(r.$1, isNull);
    expect(r.$2, isFalse);
  });

  test('网络收藏夹不按本地目录校验', () {
    final r = resolveFavoriteFolder(
      {'name': 'some-network-key', 'isNetwork': true},
      existsFolder: exists,
    );
    expect(r.$1, 'some-network-key');
    expect(r.$2, isTrue);
  });

  test('没有记录时就是未选择', () {
    final r = resolveFavoriteFolder(null, existsFolder: exists);
    expect(r.$1, isNull);
    expect(r.$2, isFalse);
  });
}
