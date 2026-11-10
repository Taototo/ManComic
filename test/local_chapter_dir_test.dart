import 'package:flutter_test/flutter_test.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/io.dart';

/// 「取消后重新下载的漫画打不开」那次事故的回归测试。
///
/// 目录名只有一份来源：**章节 id**。下载写目录、阅读找目录、取消后按磁盘
/// 对账，三处必须用同一个 key。当时对账那一处拿了标题（`entry.value`）去
/// 拼目录，跟另外两处永远对不上。
void main() {
  group('getChapterDirectoryName', () {
    test('章节 id 是 URL 时按斜杠转义，不能把层级带出去', () {
      // 这个源的章节 id 就是页面路径，实际遇到过的形状。
      expect(
        LocalManager.getChapterDirectoryName('/comics-reading/34795.html'),
        '_comics-reading_34795.html',
      );
    });

    test('中文和常见符号原样保留', () {
      expect(
        LocalManager.getChapterDirectoryName('第64话-豪承的孤注一掷'),
        '第64话-豪承的孤注一掷',
      );
      expect(
        LocalManager.getChapterDirectoryName('chapter 12 (end)'),
        'chapter 12 (end)',
      );
    });

    test('路径分隔符和 Windows 非法字符都换成下划线', () {
      expect(
        LocalManager.getChapterDirectoryName(r'a/b\c:d*e?f"g<h>i|j'),
        'a_b_c_d_e_f_g_h_i_j',
      );
    });

    test('同一个 id 反复转义结果稳定', () {
      var id = '/comics-reading/34795.html';
      var first = LocalManager.getChapterDirectoryName(id);
      expect(LocalManager.getChapterDirectoryName(id), first);
    });
  });

  // 防回退：`allChapters` 是「id → 标题」，目录名只能用 key。
  // 用 value 拼目录时功能测试全绿（扫不到就当没下过），但取消一次就把一本书
  // 的已下载记录清空，或者反过来记着一堆打不开的章节。
  test('按磁盘对账时用章节 id 拼目录，不用标题', () {
    var source = File('lib/foundation/local.dart').readAsStringSync();
    expect(
      source.contains('getChapterDirectoryName(entry.value)'),
      isFalse,
      reason: 'entry.value 是章节标题，目录是按 id 建的',
    );
  });

  group('resolveChapterDirectory', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('chapter_dir');
    });

    tearDown(() {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('id 目录存在就用它', () {
      Directory(FilePath.join(root.path, 'ch1')).createSync();
      var dir = LocalManager.resolveChapterDirectory(
        root.path,
        'ch1',
        '第一话',
      );
      expect(dir.path, FilePath.join(root.path, 'ch1'));
    });

    test('id 换了、磁盘上还是老 id 或标题时也能找回来', () {
      // 源站把「第 64 话」的 id 从数字换成了页面路径，磁盘目录没改名。
      Directory(FilePath.join(root.path, '第64话-豪承的孤注一掷')).createSync();
      var dir = LocalManager.resolveChapterDirectory(
        root.path,
        '/comics-reading/34795.html',
        '第64话-豪承的孤注一掷',
      );
      expect(
        dir.path,
        FilePath.join(root.path, '第64话-豪承的孤注一掷'),
      );
    });

    test('两条都不存在时返回 id 那份，交给调用方判空', () {
      var dir = LocalManager.resolveChapterDirectory(
        root.path,
        '/comics-reading/34795.html',
        '第64话',
      );
      expect(
        dir.path,
        FilePath.join(root.path, '_comics-reading_34795.html'),
      );
      expect(dir.existsSync(), isFalse);
    });
  });
}
