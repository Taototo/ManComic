import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 守卫「本地漫画导出」与「打开文件夹」这两个曾经真实出过问题的路径。
///
/// 这些 bug 的共同点：编译能过、界面能点，只有真机上点了才报错——
///
/// - `LocalManager.getImages` 返回的是 `file://` 开头的 URL（阅读器要的是
///   URL），导出却把它直接塞进 `File(...)`，于是 cbz/epub 全报 Cannot open
///   file；pdf 那条更隐蔽，自己 listSync 目录，把 `details.json` 当图片
///   丢进解码器。
/// - 「打开文件夹」用 `launchUrlString('file://...')`，Android 7 以上必抛
///   FileUriExposedException。
///
/// 用静态检查把这两件事钉住：以后谁再改回老写法，测试直接红。
void main() {
  String read(String path) => File(path).readAsStringSync();

  group('导出走真正的文件路径', () {
    const files = [
      'lib/utils/cbz.dart',
      'lib/utils/epub.dart',
      'lib/utils/pdf.dart',
    ];

    for (final path in files) {
      test('$path 不再直接用 getImages', () {
        final source = read(path);
        expect(
          source.contains('getImages('),
          isFalse,
          reason: 'getImages 返回 file:// URL，导出必须用 getImageFiles',
        );
        expect(
          source.contains('getImageFiles('),
          isTrue,
          reason: '导出应当通过 LocalManager.getImageFiles 拿文件列表',
        );
      });
    }
  });

  group('打开文件夹走 FileProvider', () {
    test('Android 分支不再把 file:// 丢给别的应用', () {
      final source = read('lib/pages/local_comics_page.dart');
      expect(source.contains("'openFolder'"), isTrue);
      final start = source.indexOf('if (App.isAndroid) {');
      expect(start, greaterThan(0), reason: 'Android 分支应当先单独处理');
      final end = source.indexOf('return;', start);
      // 注释里会提到这些老写法（那是给后人看的），所以只看真正的代码行。
      final androidBlock = source
          .substring(start, end)
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      expect(
        androidBlock.contains('launchUrlString'),
        isFalse,
        reason: 'Android 7+ 上 file:// URI 会抛 FileUriExposedException',
      );
      expect(androidBlock.contains("'openFolder'"), isTrue);
    });

    test('原生侧用 FileProvider 生成 content:// URI', () {
      final kotlin = read(
        'android/app/src/main/kotlin/com/github/wgh136/venera/MainActivity.kt',
      );
      expect(kotlin.contains('"openFolder"'), isTrue);
      expect(kotlin.contains('DocumentsContract.Document.MIME_TYPE_DIR'), isTrue);
      expect(kotlin.contains('FileProvider.getUriForFile'), isTrue);
    });
  });
}
