/// 下载残留清理。
///
/// 「取消下载」和「删除本地漫画」都是在删文件，但删不干净的情况太常见：
/// 进程在删到一半时被系统收掉、用户点完删除顺手把后台划掉、目录被别的进程
/// 占住…… 这些半截目录不会出现在任何列表里（库里没有、下载队列里也没有），
/// 于是它们只做两件事：占着空间，以及**下一次点下载时被当成「已经下过」**。
///
/// 后者正是「取消之后再下，只下后面的章节」的另一半原因：磁盘扫描以文件为准，
/// 它分不清「上次下好的」和「上次没删掉的」。
///
/// 这里把三类东西找出来，交给存储页显式清理：
/// - 没人认领的漫画目录（库里没有、也没有任务占着）；
/// - 进度文件里没有对应任务的过期条目；
/// - 下载用的临时文件（写到一半的 json、压缩包下载缓存）。
library;

import 'dart:convert';

import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/comic_details_cache.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/foundation/storage_usage.dart';
import 'package:venera/utils/io.dart';

/// 一次扫描的结果。只描述「有什么」，不动任何文件。
class DownloadJunk {
  const DownloadJunk({
    required this.orphanDirs,
    required this.orphanBytes,
    required this.staleProgressKeys,
    required this.tempFiles,
    required this.tempBytes,
  });

  /// 库里没有、下载队列里也没有的漫画目录。
  final List<Directory> orphanDirs;

  final int orphanBytes;

  /// 进度文件里那些已经没有任务的条目（`comicType:id`）。
  final List<String> staleProgressKeys;

  final List<File> tempFiles;

  final int tempBytes;

  int get bytes => orphanBytes + tempBytes;

  int get dirCount => orphanDirs.length;

  int get fileCount => tempFiles.length + staleProgressKeys.length;

  bool get isEmpty => dirCount == 0 && fileCount == 0;

  static const empty = DownloadJunk(
    orphanDirs: [],
    orphanBytes: 0,
    staleProgressKeys: [],
    tempFiles: [],
    tempBytes: 0,
  );
}

/// 扫一遍下载残留。失败的位置直接跳过，不因为一个读不动的目录整体失败。
Future<DownloadJunk> scanDownloadJunk() async {
  var orphanDirs = await _orphanDirectories();
  var orphanBytes = 0;
  for (var dir in orphanDirs) {
    orphanBytes += await directorySize(dir);
  }

  var tempFiles = await findDownloadTempFiles();
  var tempBytes = 0;
  for (var file in tempFiles) {
    tempBytes += await fileSize(file);
  }

  return DownloadJunk(
    orphanDirs: orphanDirs,
    orphanBytes: orphanBytes,
    staleProgressKeys: await findStaleProgressKeys(),
    tempFiles: tempFiles,
    tempBytes: tempBytes,
  );
}

/// 清掉扫描到的所有残留。
///
/// 每次都重新扫一遍：存储页上那份结果可能是几分钟前的，期间用户又删过书。
Future<void> clearDownloadJunk() async {
  var junk = await scanDownloadJunk();
  for (var dir in junk.orphanDirs) {
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (e) {
      Log.error("Download cleanup", "Failed to delete ${dir.path}: $e");
    }
  }
  for (var file in junk.tempFiles) {
    try {
      await file.delete();
    } catch (_) {}
  }
  if (junk.staleProgressKeys.isNotEmpty) {
    // 进度文件是从任务列表整体生成的，重写一次孤儿条目就没了。
    await LocalManager().saveDownloadProgressNow();
  }
}

/// 路径归一化：比对「这个目录是不是同一个」时用，末尾斜杠和反斜杠不算区别。
String _normalize(String path) {
  var normalized = path.replaceAll('\\', '/');
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

/// 路径最后一段。不用 `uri.pathSegments`：SAF 的 `content://` 目录没有
/// 好用的 uri 段，按两种分隔符切更省事。
String _baseName(String path) {
  var normalized = _normalize(path);
  var index = normalized.lastIndexOf('/');
  return index < 0 ? normalized : normalized.substring(index + 1);
}

/// 已经被「认领」的目录：本地库里登记的 + 下载队列里正在用的。
Set<String> _claimedPaths() {
  var claimed = <String>{};
  for (var comic in LocalManager().getComics(LocalSortType.name)) {
    claimed.add(_normalize(comic.baseDir));
  }
  for (var task in LocalManager().downloadingTasks) {
    var path = task.path;
    if (path != null) {
      claimed.add(_normalize(path));
    }
  }
  return claimed;
}

/// 找出 [root] 下没人认领的漫画目录。
///
/// [claimedPaths] 由调用方给：一般是「本地库里的目录 + 下载队列里的目录」。
/// 拆出来是为了能不碰数据库地测——这段判断错了就是删用户的漫画，必须有用例。
Future<List<Directory>> findOrphanDirs({
  required Directory root,
  required Set<String> claimedPaths,
  required bool claimedIsComplete,
}) async {
  var claimed = claimedPaths.map(_normalize).toSet();
  var result = <Directory>[];
  // 读不到本地库（还没打开、数据库坏了）时不做任何判断：宁可这次清不掉，
  // 也不能把用户的漫画当残留删掉。
  if (!claimedIsComplete) {
    return result;
  }
  try {
    if (!await root.exists()) {
      return result;
    }
    await for (var entity in root.list(followLinks: false)) {
      if (entity is! Directory) {
        continue;
      }
      var name = _baseName(entity.path);
      if (name.isEmpty || name.startsWith('.')) {
        continue;
      }
      if (claimed.contains(_normalize(entity.path))) {
        continue;
      }
      // 只认「像一次下载产物」的目录。用户手工丢进来的东西不动——本地库
      // 本来就是普通文件夹，往里放文件是很自然的事。
      if (!await looksLikeDownloadDirectory(entity)) {
        continue;
      }
      result.add(entity);
    }
  } catch (e) {
    Log.error("Download cleanup", "Failed to list ${root.path}: $e");
  }
  result.sort((a, b) => a.path.compareTo(b.path));
  return result;
}

Future<List<Directory>> _orphanDirectories() async {
  var complete = true;
  var claimed = <String>{};
  try {
    claimed = _claimedPaths();
  } catch (e) {
    Log.error("Download cleanup", "Failed to read local comics: $e");
    complete = false;
  }
  return findOrphanDirs(
    root: LocalManager().directory,
    claimedPaths: claimed,
    claimedIsComplete: complete,
  );
}

/// 目录里有没有下载留下的痕迹。
///
/// 下载一建目录就会写 `details.json` 和 `cover.*`，之后按页码写图。三者有
/// 其一就算「应用自己造的」，可以认作残留；什么都没有（用户建的空文件夹、
/// 放别的东西的文件夹）就不碰。
Future<bool> looksLikeDownloadDirectory(Directory dir) async {
  try {
    var entries = await dir.list(followLinks: false).toList();
    for (var entity in entries) {
      if (entity is File) {
        if (entity.name == ComicDetailsCache.fileName) {
          return true;
        }
        if (isPageFileName(entity.name)) {
          return true;
        }
      } else if (entity is Directory) {
        await for (var sub in entity.list(followLinks: false)) {
          if (sub is File && isPageFileName(sub.name)) {
            return true;
          }
        }
      }
    }
  } catch (_) {}
  return false;
}

/// 下载用的临时文件：写到一半被留下的 json、压缩包下载缓存。
Future<List<File>> findDownloadTempFiles() async {
  var result = <File>[];
  var dataDir = Directory(App.dataPath);
  try {
    if (!await dataDir.exists()) {
      return result;
    }
    await for (var entity in dataDir.list(followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      var name = entity.name;
      var isDownloadTemp = name == 'archive_downloading.zip' ||
          name == '${LocalManager.tasksFileName}.tmp' ||
          name == '${LocalManager.progressFileName}.tmp' ||
          name == '${LocalManager.tasksFileName}.bak';
      if (isDownloadTemp) {
        result.add(entity);
      }
    }
  } catch (e) {
    Log.error("Download cleanup", "Failed to list ${dataDir.path}: $e");
  }
  return result;
}

/// 进度文件里已经没有对应任务的条目。
///
/// 这些条目本身不会被套到新任务上（uid 拦住了），但留着会让进度文件越来越
/// 大，也会让人排查「为什么它记得上次的进度」时多绕一圈。
Future<List<String>> findStaleProgressKeys() async {
  var file = File(FilePath.join(App.dataPath, LocalManager.progressFileName));
  try {
    if (!await file.exists()) {
      return const [];
    }
    var json = jsonDecode(await file.readAsString());
    if (json is! Map) {
      return const [];
    }
    var alive = LocalManager()
        .downloadingTasks
        .map((e) => e.progressKey)
        .toSet();
    return json.keys.map((e) => '$e').where((e) => !alive.contains(e)).toList();
  } catch (e) {
    Log.error("Download cleanup", "Failed to read progress file: $e");
    return const [];
  }
}
