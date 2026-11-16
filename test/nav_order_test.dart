import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/nav_order.dart';
import 'package:venera/utils/app_icon.dart';
import 'package:venera/utils/data_sync.dart';

/// 底栏顺序、返回键落点、启动同步这几条规则。
///
/// 全都不靠界面就能判断对错，但错了只在真机上表现为「打开跑到隔壁页」、
/// 「侧滑一下就退出」、「云盘里一天几十份包」——都不报错，所以钉在这里。
void main() {
  String read(String path) => File(path).readAsStringSync();

  group('初始页面映射', () {
    test('0/1/2 就是主页/推荐/收藏，原样当下标', () {
      expect(initialTabFromSetting(0), tabHome);
      expect(initialTabFromSetting(1), tabExplore);
      expect(initialTabFromSetting(2), tabFavorites);
    });

    test('越界值一律落到主页', () {
      // 老版本选项里的「3 分类页」，以及被同步弄坏的值。
      expect(initialTabFromSetting(3), tabHome);
      expect(initialTabFromSetting(99), tabHome);
      expect(initialTabFromSetting(-1), tabHome);
    });

    test('底栏第一格必须是主页', () {
      expect(tabHome, 0);
      expect(tabExplore, 1);
      expect(tabFavorites, 2);
      expect(tabCount, 3);
    });
  });

  group('退到最底层时的返回', () {
    test('在别的页面上先回主页', () {
      expect(
        rootBackAction(currentPage: tabExplore, homeIndex: tabHome),
        RootBackAction.goHome,
      );
      expect(
        rootBackAction(currentPage: tabFavorites, homeIndex: tabHome),
        RootBackAction.goHome,
      );
    });

    test('已经在主页才走退出提示', () {
      expect(
        rootBackAction(currentPage: tabHome, homeIndex: tabHome),
        RootBackAction.exit,
      );
    });
  });

  group('启动同步', () {
    test('刚被云端覆盖过，不再把同一份传回去', () {
      expect(
        shouldUploadAfterLaunch(importedRemote: true, pending: true),
        isFalse,
      );
    });

    test('云端没更新、本地有改动，才补一次上传', () {
      expect(
        shouldUploadAfterLaunch(importedRemote: false, pending: true),
        isTrue,
      );
    });

    test('没有改动就什么都不传', () {
      expect(
        shouldUploadAfterLaunch(importedRemote: false, pending: false),
        isFalse,
      );
      expect(
        shouldUploadAfterLaunch(importedRemote: true, pending: false),
        isFalse,
      );
    });
  });

  group('源码守卫', () {
    test('底栏顺序是 主页 / 推荐 / 收藏', () {
      final src = read('lib/pages/main_page.dart');
      final home = src.indexOf("label: 'Home'.tl");
      final explore = src.indexOf("label: 'Explore'.tl");
      final favorites = src.indexOf("label: 'Favorites'.tl");
      expect(home, greaterThan(0));
      expect(explore, greaterThan(home));
      expect(favorites, greaterThan(explore));
    });

    test('主页被显式声明为「回主页」的目标', () {
      final src = read('lib/pages/main_page.dart');
      expect(src.contains('homeIndex: tabHome'), isTrue);
    });

    test('数据改动只记账，不再当场整包上传', () {
      final appdata = read('lib/foundation/appdata.dart');
      final saveData = appdata.substring(
        appdata.indexOf('Future<void> saveData('),
        appdata.indexOf('void addSearchHistory'),
      );
      expect(
        saveData.contains('uploadData'),
        isFalse,
        reason: 'saveData 被调用几十次，直接上传等于一天推几十份整包',
      );
      expect(saveData.contains('onDataChanged'), isTrue);
    });

    test('初始页面只剩 主页 / 推荐 / 收藏 三项', () {
      final src = read('lib/pages/settings/interface_settings.dart');
      final start = src.indexOf('settingKey: "initialPage"');
      final block = src.substring(start, src.indexOf(').toSliver()', start));
      expect(block.contains("'0'"), isTrue);
      expect(block.contains("'1'"), isTrue);
      expect(block.contains("'2'"), isTrue);
      expect(block.contains("'3'"), isFalse, reason: '分类页已经并进推荐页');
    });

    test('推荐页的悬浮刷新按钮走同一套玻璃', () {
      final src = read('lib/pages/explore_page.dart');
      final start = src.indexOf('Widget buildFAB()');
      final block = src.substring(start, src.indexOf('Tab buildTab(', start));
      expect(block.contains('LiquidGlassPanel'), isTrue);
      expect(
        block.contains('FloatingActionButton'),
        isFalse,
        reason: '实色药丸插在玻璃顶栏和底栏中间，一眼就是两种材质',
      );
      // 搜索/测试用的那个 key 别丢。
      expect(block.contains('Key("FAB")'), isTrue);
    });

    test('下载窗的左键叫「收起」，不是「后台下载」', () {
      final src = read('lib/pages/settings/about.dart');
      expect(src.contains('"Collapse".tl'), isTrue);
      expect(
        src.contains('"Download in background".tl'),
        isFalse,
        reason: '这个按钮只是把卡片收成悬浮条，下载一直在跑，叫「后台」会让人以为在切换什么',
      );
    });
  });

  group('应用图标选项', () {
    test('经典和霓虹已经下架', () {
      final keys = appIconOptions.map((e) => e.key).toList();
      expect(keys.contains('classic'), isFalse);
      expect(keys.contains('neon'), isFalse);
      expect(keys, containsAll(<String>['default', 'cat', 'logo']));
    });

    test('剩下的每个 key 在原生端都还有 alias', () {
      final kotlin = read(
        'android/app/src/main/kotlin/com/github/wgh136/venera/MainActivity.kt',
      );
      for (final option in appIconOptions) {
        expect(
          kotlin.contains('"${option.key}" to "'),
          isTrue,
          reason: '${option.key} 在 iconAliases 里找不到，切过去会退回默认图标',
        );
      }
    });

    test('下架的 alias 组件仍然留在原生映射里', () {
      // 删组件会让装过这两个图标的用户桌面上直接没有图标。
      final kotlin = read(
        'android/app/src/main/kotlin/com/github/wgh136/venera/MainActivity.kt',
      );
      expect(kotlin.contains('"classic" to "Icon2"'), isTrue);
      expect(kotlin.contains('"neon" to "Icon4"'), isTrue);
    });
  });
}
