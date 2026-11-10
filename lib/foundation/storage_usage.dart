/// 存储用量统计。
///
/// 之前设置页只有一行「缓存 320 MB / 2048 MB」——用户看到一个总数，
/// 但不知道是谁占的，也不知道除了缓存还有哪些地方在吃空间（本地漫画、
/// 收藏封面、日志）。这里把各处分别量一遍，能清的给清理入口。
library;

import 'dart:io';

import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/local.dart';

/// 存储占用的一个分类。
class StorageUsage {
  const StorageUsage({
    required this.id,
    required this.label,
    required this.bytes,
    required this.path,
    this.clearable = false,
    this.isChild = false,
  });

  /// 稳定标识。清理时按它决定删什么，**不要**用 label（会翻译）。
  final String id;

  /// 翻译键；缓存子目录若是未登记的目录，就直接是目录名。
  final String label;

  final int bytes;

  final String path;

  /// 能不能安全删除。收藏图片、本地漫画、数据库都不行——删了就是丢数据。
  final bool clearable;

  /// 是否为上层分类的子项（UI 上缩进显示）。
  final bool isChild;
}

/// 递归统计目录占用。
///
/// 目录不存在返回 0；单个文件读不到就跳过——统计用量时不该因为某个
/// 权限受限的子项整个失败（Android 上被其他应用占住的目录很常见）。
Future<int> directorySize(Directory dir) async {
  if (!await dir.exists()) {
    return 0;
  }
  var total = 0;
  try {
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {
          // 读不到就跳过这一项
        }
      }
    }
  } catch (_) {
    // 目录不可读（权限/已被删除），返回已统计到的部分
  }
  return total;
}

/// 单个文件的占用，不存在返回 0。
Future<int> fileSize(File file) async {
  try {
    if (!await file.exists()) {
      return 0;
    }
    return await file.length();
  } catch (_) {
    return 0;
  }
}

/// 缓存子目录的展示名。未登记的目录直接显示原名，不做猜测。
const Map<String, String> _cacheChildLabels = {
  'image_favorites': 'Favorite images',
  'temp_data': 'Temporary files',
  'cbz_import': 'Temporary files',
  'cbz_export': 'Temporary files',
  'comics_export': 'Temporary files',
};

/// 日志文件位置。Android 上放在外部存储目录，其他平台在数据目录。
File logFile() {
  final dir = App.isAndroid
      ? Directory(App.externalStoragePath!)
      : Directory(App.dataPath);
  return File('${dir.path}${Platform.pathSeparator}logs.txt');
}

/// 依次量出各分类的占用。
///
/// 顺序按「用户最可能想清掉的」排在前面：缓存、临时文件，然后才是
/// 数据目录和本地漫画（这两个基本不会清，是给你看账的）。
Future<List<StorageUsage>> computeStorageUsage() async {
  final result = <StorageUsage>[];

  final cacheDir = Directory(App.cachePath);
  final cacheTotal = await directorySize(cacheDir);
  result.add(
    StorageUsage(
      id: 'cache',
      label: 'Cache',
      bytes: cacheTotal,
      path: cacheDir.path,
      clearable: true,
    ),
  );

  // 缓存目录按子目录拆开。收藏的图片和漫画原图都在这里，混在一个总数里
  // 用户不敢点「清除」——拆开之后至少知道哪部分是无所谓丢的。
  if (await cacheDir.exists()) {
    final dirs = <Directory>[];
    try {
      await for (final entity in cacheDir.list(followLinks: false)) {
        if (entity is Directory) {
          dirs.add(entity);
        }
      }
    } catch (_) {}
    final sized = <(Directory, int)>[];
    for (final dir in dirs) {
      sized.add((dir, await directorySize(dir)));
    }
    sized.sort((a, b) => b.$2.compareTo(a.$2));
    for (final (dir, size) in sized) {
      final name = dir.uri.pathSegments.where((e) => e.isNotEmpty).last;
      final isFavorites = name == 'image_favorites';
      result.add(
        StorageUsage(
          id: 'cache:$name',
          label: _cacheChildLabels[name] ?? name,
          bytes: size,
          path: dir.path,
          // 收藏图删了就是用户丢数据，不给清理入口。
          clearable: !isFavorites,
          isChild: true,
        ),
      );
    }
  }

  final log = logFile();
  final logBytes = await fileSize(log);

  final dataDir = Directory(App.dataPath);
  var dataBytes = await directorySize(dataDir);
  // 桌面端日志就放在数据目录里，不扣掉的话「应用数据」和「日志」两行会把
  // 同一个文件算两次，总数虚高。
  if (log.path.startsWith(dataDir.path)) {
    dataBytes -= logBytes;
  }
  result.add(
    StorageUsage(
      id: 'data',
      label: 'App data',
      bytes: dataBytes,
      path: dataDir.path,
    ),
  );

  final localDir = LocalManager().directory;
  result.add(
    StorageUsage(
      id: 'local',
      label: 'Local comics',
      bytes: await directorySize(localDir),
      path: localDir.path,
    ),
  );

  result.add(
    StorageUsage(
      id: 'logs',
      label: 'Logs',
      bytes: logBytes,
      path: log.path,
      clearable: true,
    ),
  );

  return result;
}

/// 清掉一个分类。返回清理后的大小。
Future<void> clearStorageUsage(StorageUsage usage) async {
  switch (usage.id) {
    case 'cache':
      await CacheManager().clear();
    case 'logs':
      try {
        await logFile().delete();
      } catch (_) {
        // 文件不存在或正被写入，忽略
      }
    default:
      if (usage.id.startsWith('cache:')) {
        final dir = Directory(usage.path);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
        // 直接删目录会留下指向不存在文件的索引行，扫一遍让 CacheManager
        // 把失效记录清掉，否则「已用大小」会一直按旧值算。
        await CacheManager().checkCache();
      }
  }
}
