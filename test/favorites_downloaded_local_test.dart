import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/title_sort.dart';

/// 1.4.55 的几处结构调整，都是「回退一次用户就能看见」的，按项目习惯用
/// 源码守卫钉住；能单独测的纯函数（A-Z 排序）走正常单测。
///
/// 背景：
/// - 「失效」分类整体移除（连带「一键清理 / 重新检测」两个按钮和源体检联动）；
/// - 收藏页「本地」分类直接读本地库（1.4.56 起不再靠挪收藏）；
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

  group('「本地」分类是本地库的投影', () {
    test('收藏表里不再留 __downloaded__ 这张镜像表', () {
      var favorites = read('lib/foundation/favorites.dart');
      // 1.4.55 那一版把收藏挪进这张表：既动了用户分类，又漏掉从没收藏过的
      // 下载。1.4.56 改成直接读本地库，表连迁移一起清掉。
      expect(favorites.contains("downloadedFolderName = '__downloaded__'"), isFalse);
      expect(favorites.contains('_downloadedHashedIds'), isFalse);
      expect(favorites.contains('moveDownloadedToLocalFolder'), isFalse);
      expect(favorites.contains('_legacyDownloadedFolderName'), isTrue);
      expect(favorites.contains('_dropLegacyDownloadedFolder();'), isTrue);
      // 1.4.55 是把收藏「挪」进去的、没记来源，直接删表等于连根拔掉；
      // 改名成普通分类留着，用户自己决定去留。
      expect(
        favorites.contains('alter table "\$_legacyDownloadedFolderName" rename to'),
        isTrue,
      );
    });

    test('列表内容来自本地库，不是收藏夹', () {
      var page = read('lib/pages/favorites/local_favorites_page.dart');
      expect(page.contains('comics = localLibraryItems();'), isTrue);
      // 只取展示需要的列：整本章节 JSON 在列表里用不上，解析它会让
      // 每次下载完成后的刷新都卡一下。
      expect(page.contains('getComicSummaries(LocalSortType.timeDesc)'), isTrue);
      expect(page.contains('LocalManager().getComics('), isFalse);
      // 封面直接指向磁盘文件：本地书不该为了封面再发一次网络请求
      expect(page.contains('file://\${comic.coverFile.path}'), isTrue);
      // 下载完一本、删掉一本都要跟着刷新
      expect(page.contains('LocalManager().addListener(updateComics)'), isTrue);
    });

    test('点封面进本地详情页，删除删的是本地文件', () {
      var page = read('lib/pages/favorites/local_favorites_page.dart');
      expect(
        page.contains('LocalComicPage.open(ctx, local, heroID: heroID)'),
        isTrue,
      );
      // 删除要分清两种书：
      // - 下载自网络源：只清磁盘副本（removeFavoriteAndHistory: false），
      //   收藏和阅读历史留着，删完还能重新下；
      // - 手工导入：只在本地存在，连库记录一起删。
      // 以前统一用默认参数，会顺手抹掉下载书的收藏记录，而确认框只写
      // 「删除本地漫画和文件」。
      expect(
        page.contains('batchDeleteComics(downloaded, true, false)'),
        isTrue,
      );
      expect(page.contains('batchDeleteComics(imported)'), isTrue);
      // 已经在磁盘上的书，「下载」「移动到分类」都只会落空
      expect(page.contains("favoriteOption('moveFromDownloaded')"), isFalse);
    });

    test('侧栏数量问本地库，名字叫「本地漫画」', () {
      var sideBar = read('lib/pages/favorites/side_bar.dart');
      expect(sideBar.contains('localLibraryCount()'), isTrue);
      expect(sideBar.contains('LocalManager().length'), isTrue);
      expect(sideBar.contains('"Local comics".tl'), isTrue);
      var local = read('lib/foundation/local.dart');
      // 每帧都要显示，只走 count(*)，不把整库读出来
      expect(local.contains('SELECT count(*) FROM comics'), isTrue);
    });
  });

  group('最近阅读指向本地漫画', () {
    test('阅读器先查本地库，命中就不再向源站要目录', () {
      var loading = read('lib/pages/reader/loading.dart');
      expect(loading.contains('_findLocalComic'), isTrue);
      final localLookup = loading.indexOf('var localComic = _findLocalComic(type);');
      final networkFetch = loading.indexOf('await comicSource.loadComicInfo');
      expect(localLookup, greaterThan(0));
      // 本地优先：顺序反了就等于还是先联网
      expect(localLookup, lessThan(networkFetch));
    });

    test('历史页点封面：本地有这本就进本地详情页', () {
      var history = read('lib/pages/history_page.dart');
      expect(history.contains('_localComicOf'), isTrue);
      expect(history.contains('LocalComicPage.open'), isTrue);
      // 没下过的书才回落到源站详情页
      expect(history.contains('ComicPage('), isTrue);
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
