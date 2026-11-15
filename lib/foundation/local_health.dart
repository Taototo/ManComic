/// 本地书库体检。
///
/// 三类问题，都是「界面上看着正常、点进去才发现不对」的那种：
///
/// 1. **残留目录**——磁盘上有这本书的文件夹，库里没有对应记录（换源重下、
///    取消到一半、恢复备份后库没了）。它们占着空间，但本地列表里根本不出现。
/// 2. **失效记录**——库里有这一行，目录没了或者一页都没有。点进去是空白，
///    删除还得一本来一本点。
/// 3. **记录和磁盘不符**——记录说下了 8 话，盘上只有 5 话（或者反过来，盘上
///    有 5 话但一话都没标）。前者会让详情页显示「8/5」、整本重下时跳过不该
///    跳的章；后者会让已经下好的图在读的时候临时去网络取。
///
/// 判定和动盘分成两层：判定是纯函数（[buildLocalHealthReport]），动盘只有
/// 「挪进回收站」和「按磁盘重写记录」两种，都不直接 `delete`——回收站是
/// 用户反悔的唯一机会，而清理书库这种事不该有不可逆的操作。
library;

import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';

/// 回收站在本地库根目录下的名字。
///
/// 用点开头的隐藏目录：Android 的媒体扫描器不吃 `.*`，`.nomedia` 之外再加
/// 一层保险；桌面端 `ls` 默认也看不见，不会被误当成一本漫画。
const kLocalTrashDirName = '.trash';

/// 本地库根目录下的一个直接子目录（扫描时量出来的大小和页数）。
class LocalDirSnapshot {
  const LocalDirSnapshot({
    required this.name,
    required this.path,
    required this.bytes,
    required this.pages,
  });

  final String name;

  final String path;

  final int bytes;

  /// 里面能当正文页的文件数。残留目录里也会有几页，报出来才知道值不值得清。
  final int pages;
}

/// 一本漫画在磁盘上的检查结果。
class LocalEntryScan {
  const LocalEntryScan({
    required this.comic,
    required this.baseDir,
    required this.dirExists,
    required this.pages,
    required this.onDiskChapters,
    required this.unknownDirs,
  });

  final LocalComic comic;

  /// 解析后的绝对路径（`directory` 存绝对路径的老记录也能对上）。
  final String baseDir;

  final bool dirExists;

  /// 盘上正文页总数（含记录里没标的目录）。
  final int pages;

  /// 盘上真的有页的章节 id，按章节表顺序。
  final List<String> onDiskChapters;

  /// 对不上任何章节的子目录数——换了章节 id 又没写 `details.json` 的残留。
  /// 只报告，不动手：连它属于哪一话都不知道，删了就是删用户的图。
  final int unknownDirs;
}

/// 失效记录为什么失效。
enum DeadEntryReason {
  /// 记录指向的目录不存在（手工删了、换路径了、SD 卡拔了）。
  directoryMissing,

  /// 目录在，但一张正文页都没有（下载建好目录就被杀、或者图被清掉了）。
  noPages,
}

class DeadEntry {
  const DeadEntry({
    required this.comic,
    required this.baseDir,
    required this.reason,
  });

  final LocalComic comic;
  final String baseDir;
  final DeadEntryReason reason;
}

/// 记录和磁盘对不上的条目。
class StaleEntry {
  const StaleEntry({
    required this.comic,
    required this.recorded,
    required this.onDisk,
  });

  final LocalComic comic;

  /// 记录里说已下载的章。
  final List<String> recorded;

  /// 盘上真有页的章，按章节表顺序。
  final List<String> onDisk;

  List<String> get missingFromDisk =>
      recorded.where((e) => !onDisk.contains(e)).toList();

  List<String> get missingFromRecord =>
      onDisk.where((e) => !recorded.contains(e)).toList();
}

/// 目录在、有图，但一话都对不上章节表。只能报告。
class UnrecognizedEntry {
  const UnrecognizedEntry({required this.comic, required this.dirs});

  final LocalComic comic;

  final int dirs;
}

class LocalHealthReport {
  const LocalHealthReport({
    required this.orphans,
    required this.deadEntries,
    required this.staleEntries,
    required this.unrecognized,
    required this.trashBytes,
    required this.trashDirs,
    required this.scannedEntries,
    required this.scannedDirs,
    this.skippedInFlight = 0,
    this.cancelled = false,
  });

  static const empty = LocalHealthReport(
    orphans: [],
    deadEntries: [],
    staleEntries: [],
    unrecognized: [],
    trashBytes: 0,
    trashDirs: 0,
    scannedEntries: 0,
    scannedDirs: 0,
  );

  /// 没人认领的目录，按占用从大到小。
  final List<OrphanDir> orphans;

  final List<DeadEntry> deadEntries;

  final List<StaleEntry> staleEntries;

  final List<UnrecognizedEntry> unrecognized;

  /// 回收站现在占多少（上次清理挪进去、还没清空的）。
  final int trashBytes;

  final int trashDirs;

  final int scannedEntries;

  final int scannedDirs;

  /// 正在下载、被跳过的条目数。
  ///
  /// 下载中的目录既不该被当成残留目录挪走，它的记录也不该判失效——那本书
  /// 此刻可能只落了封面，看起来和「空壳」一模一样。
  final int skippedInFlight;

  final bool cancelled;

  int get orphanBytes => orphans.fold<int>(0, (sum, e) => sum + e.bytes);

  int get issueCount =>
      orphans.length + deadEntries.length + staleEntries.length;

  bool get isEmpty => issueCount == 0 && unrecognized.isEmpty;
}

class OrphanDir {
  const OrphanDir({
    required this.name,
    required this.path,
    required this.bytes,
    required this.pages,
  });

  final String name;
  final String path;
  final int bytes;
  final int pages;
}

/// 路径比较用的规范化。
///
/// 只用于「这两个路径是不是同一个目录」，不用于回写磁盘：分隔符统一成 `/`、
/// 去掉尾部分隔符，Windows 上再转小写（`D:\Local` 和 `d:/local` 是一个地方，
/// 但字符串比较不这么认为）。
String normalizeLocalPath(String path) {
  var result = path.replaceAll('\\', '/');
  while (result.length > 1 && result.endsWith('/')) {
    result = result.substring(0, result.length - 1);
  }
  if (Platform.isWindows) {
    result = result.toLowerCase();
  }
  return result;
}

/// 这个目录（或它的下级）有没有被某本漫画/某个任务认领。
///
/// 用前缀而不是相等：`directory` 存成 `书名/第一卷` 这种子路径的老记录，
/// 根目录下那个 `书名` 也是它的，直接按相等比会把它挪进回收站。
bool _isClaimed(String dirPath, Iterable<String> owned) {
  for (final path in owned) {
    if (path == dirPath || path.startsWith('$dirPath/')) {
      return true;
    }
  }
  return false;
}

/// 纯函数：把扫描到的素材判成四类。
///
/// 抽出来是为了能在单测里造「记录说 8 话、盘上 5 话」这种现场——这一层出
/// 错的代价是删用户的文件，比 UI 上错一行严重得多。
LocalHealthReport buildLocalHealthReport({
  required List<LocalEntryScan> entries,
  required List<LocalDirSnapshot> rootDirs,
  List<String> reservedPaths = const [],
  int trashBytes = 0,
  int trashDirs = 0,
  int skippedInFlight = 0,
  bool cancelled = false,
}) {
  final owned = <String>[
    for (final entry in entries) normalizeLocalPath(entry.baseDir),
    for (final path in reservedPaths) normalizeLocalPath(path),
  ];

  final orphans = <OrphanDir>[];
  for (final dir in rootDirs) {
    if (dir.name.startsWith('.')) {
      continue;
    }
    final path = normalizeLocalPath(dir.path);
    if (_isClaimed(path, owned)) {
      continue;
    }
    orphans.add(
      OrphanDir(
        name: dir.name,
        path: dir.path,
        bytes: dir.bytes,
        pages: dir.pages,
      ),
    );
  }
  orphans.sort((a, b) => b.bytes.compareTo(a.bytes));

  final dead = <DeadEntry>[];
  final stale = <StaleEntry>[];
  final unrecognized = <UnrecognizedEntry>[];

  for (final entry in entries) {
    if (!entry.dirExists) {
      dead.add(
        DeadEntry(
          comic: entry.comic,
          baseDir: entry.baseDir,
          reason: DeadEntryReason.directoryMissing,
        ),
      );
      continue;
    }
    if (entry.pages <= 0) {
      dead.add(
        DeadEntry(
          comic: entry.comic,
          baseDir: entry.baseDir,
          reason: DeadEntryReason.noPages,
        ),
      );
      continue;
    }
    // 没有章节表的书（手工导入、单话下载）只有一层目录，记录里那个空 id
    // 和磁盘对不上也无从修，只数页就够了。
    if (entry.comic.chapters == null) {
      continue;
    }
    if (entry.onDiskChapters.isEmpty) {
      if (entry.unknownDirs > 0) {
        unrecognized.add(
          UnrecognizedEntry(comic: entry.comic, dirs: entry.unknownDirs),
        );
      }
      continue;
    }
    final recorded = entry.comic.downloadedChapters;
    final same =
        recorded.length == entry.onDiskChapters.length &&
        recorded.every(entry.onDiskChapters.contains);
    if (same) {
      continue;
    }
    stale.add(
      StaleEntry(
        comic: entry.comic,
        recorded: recorded,
        onDisk: entry.onDiskChapters,
      ),
    );
  }

  return LocalHealthReport(
    orphans: orphans,
    deadEntries: dead,
    staleEntries: stale,
    unrecognized: unrecognized,
    trashBytes: trashBytes,
    trashDirs: trashDirs,
    scannedEntries: entries.length,
    scannedDirs: rootDirs.length,
    skippedInFlight: skippedInFlight,
    cancelled: cancelled,
  );
}

typedef HealthScanProgress = void Function(int done, int total);

/// 扫整个书库 + 处理结果。
class LocalLibraryHealth {
  /// 走一遍全库。
  ///
  /// 只读磁盘和本地库，**不联网**：这里判的是「记录和磁盘对不对得上」，
  /// 一话一个请求去问源站是「缺失章节检测」的活，不要在体检里顺手做掉。
  static Future<LocalHealthReport> scan({
    HealthScanProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    final manager = LocalManager();
    final cancelled = isCancelled ?? () => false;

    final comics = manager.getComics(LocalSortType.timeDesc);
    final entries = <LocalEntryScan>[];
    final reserved = <String>[];
    var skipped = 0;
    for (var i = 0; i < comics.length; i++) {
      if (cancelled()) {
        return LocalHealthReport(
          orphans: const [],
          deadEntries: const [],
          staleEntries: const [],
          unrecognized: const [],
          trashBytes: await trashSize(),
          trashDirs: await _trashDirCount(),
          scannedEntries: entries.length,
          scannedDirs: 0,
          skippedInFlight: skipped,
          cancelled: true,
        );
      }
      final comic = comics[i];
      final task = manager.findTask(comic.id, comic.comicType);
      if (task != null) {
        // 正在下的书：目录可能才建好、一页没落，判定必然误报。
        skipped++;
        if (task.path != null) {
          reserved.add(task.path!);
        }
      } else {
        entries.add(await scanEntry(comic));
      }
      onProgress?.call(i + 1, comics.length);
    }
    // 队列里还没有记录的书（第一次下载、还没 `add` 进库），目录也不能算残留。
    for (final task in manager.downloadingTasks) {
      final path = task.path;
      if (path != null) {
        reserved.add(path);
      }
    }

    // 「有人认领的目录」要在扫根目录之前算好：一个几十 GB 的库，把每本书的
    // 目录都递归量一遍（几万次 stat）才能凑出体检报告，用户会以为卡死了。
    // 只量没人认领的那些就够了，其余反正不展示。
    final dirs = await snapshotRoot(
      manager.path,
      skipPaths: [for (final e in entries) e.baseDir, ...reserved],
      isCancelled: cancelled,
    );

    return buildLocalHealthReport(
      entries: entries,
      rootDirs: dirs,
      reservedPaths: reserved,
      trashBytes: await trashSize(),
      trashDirs: await _trashDirCount(),
      skippedInFlight: skipped,
    );
  }

  /// 量本地库根目录下的直接子目录。
  ///
  /// [skipPaths] 里的目录（以及它们上级的那个根子目录）直接跳过，不量大小：
  /// 它们已经属于某本书或某个下载任务，体检根本不会用到这个数字。
  static Future<List<LocalDirSnapshot>> snapshotRoot(
    String rootPath, {
    Iterable<String> skipPaths = const [],
    bool Function()? isCancelled,
  }) async {
    final root = Directory(rootPath);
    if (!await root.exists()) {
      return const [];
    }
    final skip = [for (final path in skipPaths) normalizeLocalPath(path)];
    final result = <LocalDirSnapshot>[];
    try {
      await for (final entity in root.list(followLinks: false)) {
        if (isCancelled?.call() ?? false) {
          break;
        }
        if (entity is! Directory) {
          continue;
        }
        final name = entity.uri.pathSegments.isEmpty
            ? entity.path
            : entity.uri.pathSegments.where((e) => e.isNotEmpty).last;
        if (name.startsWith('.') ||
            _isClaimed(normalizeLocalPath(entity.path), skip)) {
          continue;
        }
        final measured = await _measure(entity, recursive: true);
        result.add(
          LocalDirSnapshot(
            name: name,
            path: entity.path,
            bytes: measured.bytes,
            pages: measured.pages,
          ),
        );
      }
    } catch (e, s) {
      Log.error("LocalHealth", "Failed to list $rootPath: $e", s);
    }
    return result;
  }

  /// 检查一本漫画。
  static Future<LocalEntryScan> scanEntry(LocalComic comic) async {
    final baseDir = comic.baseDir;
    final dir = Directory(baseDir);
    if (!await dir.exists()) {
      return LocalEntryScan(
        comic: comic,
        baseDir: baseDir,
        dirExists: false,
        pages: 0,
        onDiskChapters: const [],
        unknownDirs: 0,
      );
    }
    final chapters = comic.chapters;
    if (chapters == null) {
      final measured = await _measure(dir, recursive: false);
      return LocalEntryScan(
        comic: comic,
        baseDir: baseDir,
        dirExists: true,
        pages: measured.pages,
        onDiskChapters: const [],
        unknownDirs: 0,
      );
    }

    // 一次列出所有章节目录，再拿章节表去对。按记录里的每一话去 `existsSync`
    // 是几百次系统调用；而换过 id 的老目录、手工塞进去的目录只有列一遍才看得见。
    final pageCounts = <String, int>{};
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! Directory) {
          continue;
        }
        pageCounts[entity.name] = (await _measure(
          entity,
          recursive: false,
        )).pages;
      }
    } catch (e, s) {
      Log.error("LocalHealth", "Failed to list $baseDir: $e", s);
    }

    final claimedDirs = <String>{};
    final onDisk = <String>[];
    for (final id in chapters.ids) {
      final title = chapters.allChapters[id];
      final byId = LocalManager.getChapterDirectoryName(id);
      final byTitle = title == null
          ? null
          : LocalManager.getChapterDirectoryName(title);
      final name = pageCounts.containsKey(byId)
          ? byId
          : (byTitle != null && pageCounts.containsKey(byTitle)
                ? byTitle
                : null);
      if (name == null) {
        continue;
      }
      claimedDirs.add(name);
      if ((pageCounts[name] ?? 0) > 0) {
        onDisk.add(id);
      }
    }

    final unknown = pageCounts.keys
        .where((e) => !claimedDirs.contains(e))
        .length;

    // 老版本/手工导入有把图直接放在书目录根上的，这部分也得算进总页数，
    // 否则「有图但一话都对不上」会被判成空壳记录直接删掉。
    final rootPages = (await _measure(dir, recursive: false)).pages;

    return LocalEntryScan(
      comic: comic,
      baseDir: baseDir,
      dirExists: true,
      pages: pageCounts.values.fold<int>(0, (sum, e) => sum + e) + rootPages,
      onDiskChapters: onDisk,
      unknownDirs: unknown,
    );
  }

  /// 把残留目录挪进回收站。
  ///
  /// 不用 `delete`：书库清理一旦不可逆，用户点错一次就是几十 GB 没了。同一个
  /// 分区内 `rename` 是瞬时的，比复制删除快一个数量级。
  static Future<({List<String> moved, List<String> failed})> quarantine(
    List<OrphanDir> dirs,
  ) async {
    final moved = <String>[];
    final failed = <String>[];
    if (dirs.isEmpty) {
      return (moved: moved, failed: failed);
    }
    final stamp = _timestamp();
    final trash = Directory(
      FilePath.join(LocalManager().path, kLocalTrashDirName, stamp),
    );
    try {
      await trash.create(recursive: true);
    } catch (e, s) {
      Log.error("LocalHealth", "Failed to create trash folder: $e", s);
      return (moved: moved, failed: dirs.map((e) => e.name).toList());
    }
    for (final dir in dirs) {
      final target = FilePath.join(trash.path, dir.name);
      try {
        final source = Directory(dir.path);
        if (!await source.exists()) {
          // 扫描到这步之间用户自己删了，不算失败。
          moved.add(dir.name);
          continue;
        }
        await source.rename(target);
        moved.add(dir.name);
      } catch (e, s) {
        Log.error("LocalHealth", "Failed to quarantine ${dir.path}: $e", s);
        failed.add(dir.name);
      }
    }
    return (moved: moved, failed: failed);
  }

  /// 回收站占多少。
  static Future<int> trashSize() async {
    return (await _measure(Directory(_trashPath()), recursive: true)).bytes;
  }

  static Future<int> _trashDirCount() async {
    final trash = Directory(_trashPath());
    if (!await trash.exists()) {
      return 0;
    }
    try {
      var count = 0;
      await for (final entity in trash.list(followLinks: false)) {
        if (entity is Directory) {
          count++;
        }
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  /// 清空回收站（真正不可逆的那一步，UI 上必须二次确认）。
  static Future<void> emptyTrash() async {
    final trash = Directory(_trashPath());
    if (await trash.exists()) {
      await trash.delete(recursive: true);
    }
  }

  /// 移出若干失效记录。只删记录，不碰文件——判失效的前提就是「没有可用
  /// 的文件」，真有几张图留着，下一次体检会把它当残留目录报出来。
  static void removeDeadEntries(List<DeadEntry> entries) {
    for (final entry in entries) {
      LocalManager().deleteComic(entry.comic, false);
    }
  }

  /// 按磁盘上的真实情况重写「已下载章节」。
  static void repairStaleEntries(List<StaleEntry> entries) {
    for (final entry in entries) {
      LocalManager().setDownloadedChapters(entry.comic, entry.onDisk);
    }
  }

  static String _trashPath() =>
      FilePath.join(LocalManager().path, kLocalTrashDirName);

  static String _timestamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return "${now.year}${two(now.month)}${two(now.day)}-"
        "${two(now.hour)}${two(now.minute)}${two(now.second)}";
  }

  /// 量一个目录：字节数 + 正文页数。
  ///
  /// 读不到的文件跳过——体检不该因为一张没权限的图整个失败。
  static Future<({int bytes, int pages})> _measure(
    Directory dir, {
    required bool recursive,
  }) async {
    var bytes = 0;
    var pages = 0;
    try {
      await for (final entity in dir.list(
        recursive: recursive,
        followLinks: false,
      )) {
        if (entity is! File) {
          continue;
        }
        if (LocalManager.isComicPageName(entity.name)) {
          try {
            if (entity.lengthSync() > 0) {
              pages++;
            }
          } catch (_) {
            // 读不到大小就当没有这一页，但空间照算
          }
        }
        try {
          bytes += await entity.length();
        } catch (_) {
          // 读不到就跳过
        }
      }
    } catch (e, s) {
      Log.error("LocalHealth", "Failed to measure ${dir.path}: $e", s);
    }
    return (bytes: bytes, pages: pages);
  }
}
