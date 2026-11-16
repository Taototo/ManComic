/// 底栏的顺序，以及「初始页面」设置项和它的关系。
///
/// 这两件事必须写在一起：设置里存的是「哪一页」的编号，底栏按下标取页面，
/// 两边一旦对不上，表现就是「设置了主页，打开落在推荐页」——不会报错，
/// 只会在真机上发现。抽成一个文件是为了能直接单测这份映射。
library;

/// 底栏第一格：主页。也是返回键在别的页面退到底以后回到的那一页。
const tabHome = 0;

/// 底栏第二格：推荐（发现页）。
const tabExplore = 1;

/// 底栏第三格：收藏。
const tabFavorites = 2;

/// 底栏一共几格。
const tabCount = 3;

/// 设置里 `initialPage` 的编号 → 底栏下标。
///
/// 目前两边是同一套顺序（0 主页、1 推荐、2 收藏），所以映射是恒等的；
/// 越界值（老版本留下的「3 分类页」、或者被同步弄坏的值）一律落到主页，
/// 而不是让 `pageBuilder` 越界。
int initialTabFromSetting(int saved) {
  if (saved < 0 || saved >= tabCount) {
    return tabHome;
  }
  return saved;
}
