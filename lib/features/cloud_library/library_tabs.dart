import 'package:venera/features/cloud_library/remote_library_engine.dart';
import 'package:venera/foundation/appdata.dart';

/// 「发现」页里哪些云漫画库有独立页签。
///
/// 页签的身份是库名（`explore_pages` 里存的就是名字），所以改名时要同步改
/// 这里，见 [renameLibraryTab]。

List<String> libraryTabTitles() =>
    (appdata.settings['explore_pages'] as List? ?? const [])
        .whereType<String>()
        .toList();

/// 让云漫画库在发现页有一个页签。
///
/// 后台自动创建的备份库走的不是设置对话框那条路，之前没人把它写进
/// `explore_pages`，于是库确实建好了、索引也在跑，但发现页没有入口——用户
/// 看到的就是「网盘里的漫画根本找不到」。建库的地方统一调这里补上。
Future<bool> enableLibraryTab(String name) async {
  if (name.isEmpty) return false;
  final pages = libraryTabTitles();
  if (pages.contains(name)) return false;
  pages.add(name);
  appdata.settings['explore_pages'] = pages;
  await appdata.saveData(false);
  return true;
}

/// 关掉某个库的页签（用户主动隐藏时用）。
Future<bool> disableLibraryTab(String name) async {
  final pages = libraryTabTitles();
  if (!pages.contains(name)) return false;
  appdata.settings['explore_pages'] = pages.where((e) => e != name).toList();
  await appdata.saveData(false);
  return true;
}

/// 一次性补齐历史版本漏掉的页签。
///
/// 只跑一次：用过旧版本的用户可能已经有库却没有页签，升级后补上即可；之后
/// 用户自己在漫画源设置里关掉页签，不会再被强行加回来。
Future<void> migrateLibraryTabsOnce() async {
  if (appdata.implicitData[libraryTabsMigratedKey] == true) return;
  appdata.implicitData[libraryTabsMigratedKey] = true;
  await appdata.writeImplicitData();
  final pages = libraryTabTitles();
  var changed = false;
  for (final library in RemoteComicLibraryRegistry.read()) {
    if (library.name.isEmpty || pages.contains(library.name)) continue;
    pages.add(library.name);
    changed = true;
  }
  if (!changed) return;
  appdata.settings['explore_pages'] = pages;
  await appdata.saveData(false);
}

const libraryTabsMigratedKey = 'remoteLibraryTabsMigrated';
