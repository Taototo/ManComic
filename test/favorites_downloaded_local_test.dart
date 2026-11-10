import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/title_sort.dart';

/// 1.4.55 的几处结构调整，都是「回退一次用户就能看见」的，按项目习惯用
/// 源码守卫钉住；能单独测的纯函数（A-Z 排序）走正常单测。
///
/// 背景：
/// - 「失效」分类整体移除（连带「一键清理 / 重新检测」两个按钮和源体检联动）；
/// - 新增自动归拢的「已下载」分类：收藏里凡是本地库有的书都挪进去；
/// - 本地列表补一个 A-Z 排序（按拼音首字母，不是 SQLite 的码位序）；
/// - 首页顶栏去掉与标题重复的「文件夹」图标；
/// - 存储管理回到 1.4.51（不再有「下载残留」那一项）。
void main() {
  String read(String path) => File(path).readAsStringSync();

  group('本地列表 A-Z 排序', () {
    test('汉字按拼音首字母排序，而不是码位', () {
      // 数字最前、其次拉丁字母、然后汉字（按拼音首字母）、认不出的排最后。
      final sorted = sortByTitleAZ<String>([
        '乙女',
        '白昼',
        '阿宅',
        'Candy',
        '2B',
      ], (e) => e);
      expect(sorted, ['2B', 'Candy', '阿宅', '白昼', '乙女']);
    });

    test('书名号里的正题参与排序，符号不算首字', () {
      final sorted = sortByTitleAZ<String>([
        '《杂志》',
        'b-title',
        'A-title',
        '1-title',
      ], (e) => e);
      expect(sorted, ['1-title', 'A-title', 'b-title', '《杂志》']);
    });

    test('本地列表把 A-Z 交给同一套拼音排序', () {
      var local = read('lib/foundation/local.dart');
      expect(local.contains('titleAZ("title_az")'), isTrue);
      expect(local.contains('sortByTitleAZ'), isTrue);
      var page = read('lib/pages/local_comics_page.dart');
      expect(page.contains('LocalSortType.titleAZ'), isTrue);
      expect(page.contains('"Name A-Z"'), isTrue);
    });
  });

  group('「已下载」自动分类', () {
    test('内置表不进 folderNames，且有独立的 hash 映射', () {
      var favorites = read('lib/foundation/favorites.dart');
      expect(favorites.contains("downloadedFolderName = '__downloaded__'"), isTrue);
      expect(favorites.contains('_downloadedHashedIds'), isTrue);
      // 「全部」的统计不能把它算进去（和已阅一致）
      expect(favorites.contains('folders.remove(downloadedFolderName)'), isTrue);
    });

    test('归拢只看本地库，不联网探活', () {
      var favorites = read('lib/foundation/favorites.dart');
      expect(favorites.contains('Future<int> moveDownloadedToLocalFolder()'), isTrue);
      expect(favorites.contains('LocalManager().find(item.id, item.type)'), isTrue);
      // 一本漫画只属于一个分类：挪进来要顺手从原分类删掉
      expect(favorites.contains('delete from "\$folder"'), isTrue);
    });

    test('启动跑一遍，下载完成入库再补一遍', () {
      var init = read('lib/init.dart');
      expect(init.contains('moveDownloadedToLocalFolder'), isTrue);
      var local = read('lib/foundation/local.dart');
      expect(local.contains('onComicAdded?.call(comic)'), isTrue);
    });

    test('侧栏有入口、页面有哨兵名和空态', () {
      var sideBar = read('lib/pages/favorites/side_bar.dart');
      expect(sideBar.contains('_localDownloadedFolderLabel'), isTrue);
      expect(sideBar.contains('downloadedCount()'), isTrue);
      var page = read('lib/pages/favorites/local_favorites_page.dart');
      expect(page.contains('const _localDownloadedFolderLabel'), isTrue);
      expect(page.contains('No downloaded comics'), isTrue);
    });
  });

  group('「失效」分类彻底移除', () {
    test('判定与清理入口都不在了', () {
      var favorites = read('lib/foundation/favorites.dart');
      expect(favorites.contains('_isInvalidItem'), isFalse);
      expect(favorites.contains('cleanupInvalid'), isFalse);
      expect(favorites.contains('removeInvalid'), isFalse);
      expect(favorites.contains('SourceHealthService'), isFalse);
      var settings = read('lib/pages/settings/action_settings.dart');
      expect(settings.contains('removeInvalid'), isFalse);
      var page = read('lib/pages/favorites/local_favorites_page.dart');
      expect(page.contains('cleanupInvalid'), isFalse);
      expect(page.contains('recheckInvalid'), isFalse);
    });

    test('老库里的表会被删掉，不会冒充普通分类', () {
      var favorites = read('lib/foundation/favorites.dart');
      expect(favorites.contains('_dropLegacyInvalidFolder'), isTrue);
      expect(favorites.contains('drop table'), isTrue);
      // 删表必须在枚举 folderNames 之前，否则这一轮就把它当分类列出来了
      final drop = favorites.indexOf('_dropLegacyInvalidFolder();');
      final enumerate = favorites.indexOf('var folderNames = _getFolderNamesWithDB();');
      expect(drop, greaterThan(0));
      expect(drop, lessThan(enumerate));
    });
  });

  group('顶栏只留一个分类入口', () {
    test('右上角的「文件夹」图标去掉了，标题仍然可点', () {
      var main = read('lib/pages/main_page.dart');
      // 图标入口没了
      expect(main.contains('icon: Icons.folder_outlined'), isFalse);
      // 标题点击还在（同一件事只留一处）
      expect(main.contains('_favoritesFolders.open?.call()'), isTrue);
    });
  });

  group('存储管理回到 1.4.51', () {
    test('不再统计/清理下载残留', () {
      var usage = read('lib/foundation/storage_usage.dart');
      expect(usage.contains('download_junk'), isFalse);
      expect(usage.contains('download_cleanup'), isFalse);
      var page = read('lib/pages/settings/storage_settings.dart');
      expect(page.contains('Download leftovers'), isFalse);
      expect(File('lib/foundation/download_cleanup.dart').existsSync(), isFalse);
    });
  });
}
